"""Map surviving optimized LLVM calls to Zig source lines using DWARF metadata."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re


MARKER = " // llvm-ir: "
SYMBOL = r'[@%](?:"(?:[^"\\]|\\.)*"|[-a-zA-Z$._0-9]+)'
CALLEE = re.compile(r"(" + SYMBOL + r")\s*\(")
CALL = re.compile(r"^(?:" + SYMBOL + r"\s*=\s*)?(?:(?:tail|musttail|notail)\s+)?(?:call|invoke|callbr)\s+")
METADATA = re.compile(r"^!(\d+) = (?:distinct )?!(\w+)\((.*)\)$")


def ignored_call(name):
    return name.startswith("debug.FullPanic(")


def split_fields(text):
    """Split LLVM lists without splitting quoted strings or nested types/attributes."""
    result, start, depth, quoted, escaped = [], 0, 0, False, False
    for i, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "([{<":
            depth += 1
        elif char in ")]}>":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(text[start:i].strip())
            start = i + 1
    result.append(text[start:].strip())
    return result


def unquote(text):
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    return re.sub(r"\\([0-9A-Fa-f]{2})", lambda m: chr(int(m[1], 16)), text)


def clean_source(text):
    # Only remove our suffix in a Zig comment, never a marker in a string literal.
    return "".join(strip_annotation(line) for line in text.splitlines(keepends=True))


def comment_start(line):
    quoted, escaped, quote = False, False, ""
    if line.lstrip().startswith("\\\\"):
        return None
    for i, char in enumerate(line):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quoted = False
        elif char in "\"'":
            quoted, quote = True, char
        elif line[i:i + 2] == "//":
            return i
    return None


def strip_annotation(line):
    start = comment_start(line)
    marker = line.find(MARKER, max(0, start - 1)) if start is not None else -1
    if start is not None and marker >= 0 and marker + 1 >= start:
        return line[:marker] + ("\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else "")
    return line


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


class DebugInfo:
    def __init__(self, lines, sources):
        self.nodes = {}
        self.sources = sources
        for line in lines:
            match = METADATA.match(line.strip())
            if match:
                fields = {}
                for field in split_fields(match[3]):
                    key, sep, value = field.partition(": ")
                    if sep:
                        fields[key] = value
                self.nodes["!" + match[1]] = (match[2], fields)
        units = [fields for kind, fields in self.nodes.values() if kind == "DICompileUnit"]
        if not units or any(unit.get("isOptimized") != "true" for unit in units):
            raise ValueError("IR must contain optimized DICompileUnit debug metadata; use ReleaseSafe/ReleaseFast and -fno-strip")
        self.file_cache = {}

    def source_file(self, ref, seen=None):
        if ref in self.file_cache:
            return self.file_cache[ref]
        seen = set() if seen is None else seen
        if ref in seen:
            return None
        seen.add(ref)
        kind, fields = self.nodes.get(ref, (None, {}))
        if kind == "DIFile":
            filename = unquote(fields.get("filename", ""))
            directory = unquote(fields.get("directory", ""))
            path = os.path.normpath(os.path.join(directory, filename)).replace(os.sep, "/")
            # Match complete repository-relative paths, not basenames. Reject
            # external repositories even if they contain e.g. zml/tensor.zig.
            matches = [] if "/external/" in "/" + path else [
                source for source in self.sources
                if path == source or path.endswith("/" + source)
            ]
            result = max(matches, key=len) if matches else None
        else:
            result = self.source_file(fields.get("file", fields.get("scope")), seen)
        self.file_cache[ref] = result
        return result

    def location(self, ref):
        kind, fields = self.nodes.get(ref, (None, {}))
        if kind != "DILocation":
            return None
        path = self.source_file(fields.get("scope"))
        line = int(fields.get("line", "0"))
        # Use the operation's lexical origin, not its inlinedAt call site.
        return (path, line) if path and line > 0 else None


def instructions(lines, with_context=False):
    """LLVM prints instructions on one line, except e.g. invoke destinations."""
    pending = None
    function, context = None, None
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("define "):
            target = CALLEE.search(stripped)
            function = unquote(target[1][1:]) if target else None
        if CALL.match(stripped):
            if pending:
                yield (pending, context) if with_context else pending
            pending = stripped
            context = {"ir_line": number, "function": function}
        elif pending and stripped and line.startswith("    "):
            pending += " " + stripped
        elif pending and stripped.startswith(("to label ", "unwind label ")):
            pending += " " + stripped
        else:
            if pending:
                yield (pending, context) if with_context else pending
            pending = None
        if pending and "!dbg !" in pending:
            yield (pending, context) if with_context else pending
            pending = None
    if pending:
        yield (pending, context) if with_context else pending


def operation(instruction):
    match = CALL.match(instruction)
    if not match:
        return None
    body = instruction[match.end():]
    if re.search(r"\basm\s+(?:sideeffect\s+|alignstack\s+|inteldialect\s+|unwind\s+)*\"", body):
        return None
    target = CALLEE.search(body)
    if not target:
        return {"kind": "call", "callee": "<indirect expression>"}
    symbol = target[1]
    name = unquote(symbol[1:])
    memory = re.match(r"(?:llvm\.)?(memcpy|memmove|memset)(?:\.|$)", name) if symbol[0] == "@" else None
    if memory:
        # All three intrinsics and libc routines take their size as argument 3.
        arguments = body[target.end():]
        # Find the closing parenthesis, respecting parameter attributes such as
        # dereferenceable(64), constant expressions, and aggregate arguments.
        depth, quoted, escaped = 1, False, False
        end = len(arguments)
        for i, char in enumerate(arguments):
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        args = split_fields(arguments[:end])
        size = re.search(r"\bi\d+\s+(?:\w+\s+)*?(\d+)\s*$", args[2]) if len(args) > 2 else None
        return {"kind": memory[1], "bytes": int(size[1]) if size else None}
    if symbol[0] == "@" and (name.startswith("llvm.") or ignored_call(name)):
        return None
    return {"kind": "call", "callee": name if symbol[0] == "@" else "<indirect>"}


def analyze(ir_paths, manifest):
    sources = {}
    for source, path in sorted(manifest.items()):
        if source.startswith("../") or PurePosixPath(source).is_absolute() or ".." in PurePosixPath(source).parts:
            raise ValueError("source must be workspace-relative: " + source)
        with open(path, newline="") as stream:
            sources[source] = clean_source(stream.read())
    diagnostics = {}
    line_counts = {path: len(text.splitlines()) for path, text in sources.items()}
    counts = {"calls_without_debug_location": 0, "calls_outside_sources": 0}
    invalid_locations = {}
    for path in ir_paths:
        with open(path) as stream:
            lines = stream.readlines()
        debug = DebugInfo(lines, sources)
        for instruction, context in instructions(lines, with_context=True):
            op = operation(instruction)
            if op is None:
                continue
            ref = re.search(r"!dbg (!\d+)", instruction)
            if not ref:
                counts["calls_without_debug_location"] += 1
                continue
            location = debug.location(ref[1])
            if not location:
                counts["calls_outside_sources"] += 1
                continue
            source, line = location
            if line > line_counts[source]:
                # Zig can emit synthesized generic functions whose scopeLine
                # belongs to another file. Do not guess a source line for them.
                invalid_locations[(source, line)] = {"path": source, "line": line}
                continue
            key = (source, line, op["kind"], op.get("callee", ""))
            if "bytes" in op:
                # Count surviving IR instructions, including multiple operations
                # within a function, not runtime executions or distinct types.
                instances = diagnostics.get(key, {}).get("instances", [])
                instances.append({
                    **context,
                    "ir": str(path),
                    "column": int(debug.nodes[ref[1]][1].get("column", "0")),
                    "instruction": instruction,
                    "bytes": op["bytes"],
                })
                op["instances"] = instances
                op["instance_count"] = len(instances)
            if key in diagnostics and "bytes" in op:
                previous = diagnostics[key]["bytes"]
                op["bytes"] = None if previous is None or op["bytes"] is None else max(previous, op["bytes"])
            diagnostics[key] = {"path": source, "line": line, **op}
    return {
        "version": 1,
        "sources": {path: digest(text) for path, text in sources.items()},
        "diagnostics": [diagnostics[key] for key in sorted(diagnostics)],
        "unmapped": counts,
        "invalid_debug_locations": [invalid_locations[key] for key in sorted(invalid_locations)],
    }


def description(diagnostic):
    if diagnostic["kind"] == "call":
        # JSON escaping keeps unusual LLVM names on a single source line.
        return "not inlined: " + json.dumps(diagnostic["callee"], ensure_ascii=True)
    size = diagnostic["bytes"]
    # Old reports cannot establish that more than one instance was recorded.
    prefix = "max " if diagnostic.get("instance_count", 1) > 1 else ""
    return diagnostic["kind"] + (" (dynamic size)" if size is None else f" ({prefix}{size} bytes)")


def apply(report, workspace, prefixes, remove=False, check=False):
    if report.get("version") != 1:
        raise ValueError("unsupported report version")
    root = Path(workspace).resolve()
    by_path = {}
    for diagnostic in report["diagnostics"]:
        # Also filter older reports so applying one cannot restore panic noise.
        if diagnostic["kind"] == "call" and ignored_call(diagnostic["callee"]):
            continue
        by_path.setdefault(diagnostic["path"], {}).setdefault(diagnostic["line"], []).append(description(diagnostic))
    changes, skipped = [], []
    for source, expected in report["sources"].items():
        if not any(source.startswith(prefix.rstrip("/") + "/") for prefix in prefixes):
            continue
        path = (root / source).resolve()
        if not path.is_relative_to(root):
            raise ValueError("source escapes workspace: " + source)
        with path.open(newline="") as stream:
            original = stream.read()
        clean = clean_source(original)
        if not remove and digest(clean) != expected:
            raise ValueError("source changed since IR was built; rebuild report: " + source)
        lines = clean.splitlines(keepends=True)
        if not remove:
            for number, messages in by_path.get(source, {}).items():
                line = lines[number - 1]
                # A trailing // inside a Zig multiline string is string data.
                if line.lstrip().startswith("\\\\"):
                    skipped.append(f"{source}:{number}")
                    continue
                ending = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
                content = line[:-len(ending)] if ending else line
                lines[number - 1] = content + MARKER + "; ".join(sorted(set(messages))) + ending
        updated = "".join(lines)
        if original != updated:
            changes.append((path, updated))
    # Validate every file before writing any; stale IR must not partially apply.
    if not check:
        for path, updated in changes:
            with path.open("w", newline="") as stream:
                stream.write(updated)
    return len(changes), skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    analyze_parser = commands.add_parser("analyze")
    analyze_parser.add_argument("--ir", action="append", required=True)
    analyze_parser.add_argument("--manifest", required=True)
    analyze_parser.add_argument("--output", required=True)
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("--report", required=True)
    apply_parser.add_argument("--workspace", default=os.environ.get("BUILD_WORKSPACE_DIRECTORY"))
    apply_parser.add_argument("--prefix", action="append", help="workspace directory to annotate; default: zml")
    apply_parser.add_argument("--remove", action="store_true")
    apply_parser.add_argument("--check", action="store_true", help="report number of files that would change without writing")
    args = parser.parse_args()
    try:
        if args.command == "analyze":
            report = analyze(args.ir, json.loads(Path(args.manifest).read_text()))
            Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            print(f"Found {len(report['diagnostics'])} source diagnostics; unmapped: {report['unmapped']}")
        else:
            if not args.workspace:
                parser.error("--workspace is required outside bazel run")
            count, skipped = apply(json.loads(Path(args.report).read_text()), args.workspace, args.prefix or ["zml"], args.remove, args.check)
            print(f"{'Would update' if args.check else 'Updated'} {count} files; skipped {len(skipped)} multiline string locations")
            for location in skipped:
                print("Report-only diagnostic: " + location)
    except (ValueError, OSError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
