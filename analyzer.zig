const usage =
    \\Usage: llvm-inline-annotations analyze --ir FILE --output FILE
    \\       llvm-inline-annotations apply --report FILE --workspace DIR [--prefix DIR ...] [--remove] [--check]
    \\
;

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    const analyzing = std.mem.eql(u8, args[1], "analyze");
    if (!analyzing and !std.mem.eql(u8, args[1], "apply")) return error.InvalidArguments;

    var ir: ?[]const u8 = null;
    var prefixes: std.ArrayList([]const u8) = .empty;
    var output: ?[]const u8 = null;
    var report_path: ?[]const u8 = null;
    var workspace: ?[]const u8 = init.environ_map.get("BUILD_WORKSPACE_DIRECTORY");
    var remove = false;
    var check = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (!analyzing and std.mem.eql(u8, arg, "--remove")) {
            remove = true;
            continue;
        }
        if (!analyzing and std.mem.eql(u8, arg, "--check")) {
            check = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return error.InvalidArguments;
        const value = args[i];
        if (analyzing and std.mem.eql(u8, arg, "--ir")) {
            if (ir != null) return error.InvalidArguments;
            ir = value;
        } else if (analyzing and std.mem.eql(u8, arg, "--output")) {
            output = value;
        } else if (!analyzing and std.mem.eql(u8, arg, "--report")) {
            report_path = value;
        } else if (!analyzing and std.mem.eql(u8, arg, "--workspace")) {
            workspace = value;
        } else if (!analyzing and std.mem.eql(u8, arg, "--prefix")) {
            try prefixes.append(a, value);
        } else return error.InvalidArguments;
    }
    if (analyzing) {
        const ir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ir orelse return error.InvalidArguments, a);
        if (output == null) return error.InvalidArguments;
        const report = try analyze(a, io, ir_path);
        const file = try std.Io.Dir.cwd().createFile(io, output.?, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        std.debug.print("Found {d} diagnostics\n", .{report.object.get("diagnostics").?.array.items.len});
    } else {
        if (report_path == null or workspace == null) return error.InvalidArguments;
        if (prefixes.items.len == 0) try prefixes.append(a, "zml");
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, report_path.?, a, .unlimited);
        const report = try json.parseFromSlice(json.Value, a, contents, .{ .allocate = .alloc_always });
        const result = try apply(a, io, report.value, workspace.?, prefixes.items, remove, check);
        std.debug.print("{s} {d} files; skipped {d} multiline string locations\n", .{ if (check) "Would update" else "Updated", result.count, result.skipped.len });
        for (result.skipped) |location| std.debug.print("Report-only diagnostic: {s}\n", .{location});
    }
}

const marker = " // llvm-ir: ";
const whitespace = " \t\r\n";

pub fn splitFields(a: Allocator, text: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var depth: i32 = 0;
    var quoted = false;
    var escaped = false;
    for (text, 0..) |c, i| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                quoted = false;
            }
        } else switch (c) {
            '"' => quoted = true,
            '(', '[', '{', '<' => depth += 1,
            ')', ']', '}', '>' => depth -= 1,
            ',' => if (depth == 0) {
                try result.append(a, std.mem.trim(u8, text[start..i], whitespace));
                start = i + 1;
            },
            else => {},
        }
    }
    try result.append(a, std.mem.trim(u8, text[start..], whitespace));
    return result.toOwnedSlice(a);
}
fn unquote(a: Allocator, raw: []const u8) ![]const u8 {
    const text = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16)) |byte| {
                try result.append(a, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try result.append(a, text[i]);
    }
    return result.toOwnedSlice(a);
}
fn ending(line: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, line, "\r\n")) "\r\n" else if (std.mem.endsWith(u8, line, "\n")) "\n" else "";
}
fn stripAnnotation(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, std.mem.trim(u8, line, whitespace), "\\\\")) return line;
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (std.mem.startsWith(u8, line[i..], "//")) {
            if (std.mem.indexOf(u8, line[i -| 1..], marker)) |off| return line[0 .. (i -| 1) + off];
            return line;
        }
    }
    return line;
}
pub fn cleanSource(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        const clean = stripAnnotation(line);
        try out.appendSlice(a, clean);
        if (clean.len != line.len) try out.appendSlice(a, ending(line));
    }
    return out.toOwnedSlice(a);
}
const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    fn next(self: *Lines) ?[]const u8 {
        if (self.pos == self.text.len) return null;
        const start = self.pos;
        self.pos = if (std.mem.indexOfScalarPos(u8, self.text, start, '\n')) |n| n + 1 else self.text.len;
        return self.text[start..self.pos];
    }
};
fn digest(a: Allocator, text: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn validSource(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return path.len > 0;
}
const Node = struct { kind: []const u8, fields: std.StringHashMap([]const u8) };
const DebugInfo = struct {
    a: Allocator,
    nodes: std.StringHashMap(Node),
    cache: std.StringHashMap(?[]const u8),
    fn init(a: Allocator, text: []const u8) !DebugInfo {
        var self = DebugInfo{ .a = a, .nodes = .init(a), .cache = .init(a) };
        var lines = Lines{ .text = text };
        var units: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, whitespace);
            if (!std.mem.startsWith(u8, line, "!")) continue;
            const sep = std.mem.indexOf(u8, line, " = ") orelse continue;
            _ = std.fmt.parseInt(usize, line[1..sep], 10) catch continue;
            var body = line[sep + 3 ..];
            if (std.mem.startsWith(u8, body, "distinct ")) body = body[9..];
            if (!std.mem.startsWith(u8, body, "!") or !std.mem.endsWith(u8, body, ")")) continue;
            const open = std.mem.indexOfScalar(u8, body, '(') orelse continue;
            var node = Node{ .kind = body[1..open], .fields = .init(a) };
            for (try splitFields(a, body[open + 1 .. body.len - 1])) |field| {
                if (std.mem.indexOf(u8, field, ": ")) |colon| try node.fields.put(field[0..colon], field[colon + 2 ..]);
            }
            if (std.mem.eql(u8, node.kind, "DICompileUnit")) {
                units += 1;
                if (!std.mem.eql(u8, node.fields.get("isOptimized") orelse "", "true")) return error.ExpectedOptimizedDICompileUnit;
            }
            try self.nodes.put(line[0..sep], node);
        }
        if (units == 0) return error.ExpectedOptimizedDICompileUnit;
        return self;
    }
    fn sourceFile(self: *DebugInfo, ref: []const u8, depth: usize) !?[]const u8 {
        if (self.cache.get(ref)) |cached| return cached;
        if (depth > self.nodes.count()) return null;
        const node = self.nodes.get(ref) orelse return null;
        var result: ?[]const u8 = null;
        if (std.mem.eql(u8, node.kind, "DIFile")) {
            const filename = try unquote(self.a, node.fields.get("filename") orelse "");
            const directory = try unquote(self.a, node.fields.get("directory") orelse "");
            if (filename.len != 0) {
                const path = if (std.fs.path.isAbsolutePosix(filename) or directory.len == 0) filename else try std.fmt.allocPrint(self.a, "{s}/{s}", .{ std.mem.trimEnd(u8, directory, "/"), filename });
                result = path;
            }
        } else {
            result = try self.sourceFile(node.fields.get("file") orelse node.fields.get("scope") orelse "", depth + 1);
        }
        try self.cache.put(ref, result);
        return result;
    }
};
const Symbol = struct { text: []const u8, end: usize };
fn symbolAt(s: []const u8, start: usize) ?Symbol {
    if (start >= s.len or (s[start] != '@' and s[start] != '%')) return null;
    var i = start + 1;
    if (i < s.len and s[i] == '"') {
        i += 1;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\') {
                i += 1;
            } else if (s[i] == '"') return .{ .text = s[start .. i + 1], .end = i + 1 };
        }
        return null;
    }
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or std.mem.indexOfScalar(u8, "-$._", s[i]) != null)) : (i += 1) {}
    return if (i > start + 1) .{ .text = s[start..i], .end = i } else null;
}
fn callee(s: []const u8) ?Symbol {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (symbolAt(s, i)) |sym| {
            var end = sym.end;
            while (end < s.len and std.ascii.isWhitespace(s[end])) : (end += 1) {}
            if (end < s.len and s[end] == '(') return .{ .text = sym.text, .end = end + 1 };
            i = sym.end - 1;
        }
    }
    return null;
}
fn consumeWord(s: []const u8, word: []const u8) ?[]const u8 {
    if (s.len > word.len and std.mem.startsWith(u8, s, word) and std.ascii.isWhitespace(s[word.len])) return std.mem.trim(u8, s[word.len..], whitespace);
    return null;
}
fn callBody(instruction: []const u8) ?[]const u8 {
    var s = instruction;
    if (symbolAt(s, 0)) |sym| {
        s = std.mem.trim(u8, s[sym.end..], whitespace);
        if (!std.mem.startsWith(u8, s, "=")) return null;
        s = std.mem.trim(u8, s[1..], whitespace);
    }
    inline for (.{ "tail", "musttail", "notail" }) |prefix| {
        if (consumeWord(s, prefix)) |rest| s = rest;
    }
    inline for (.{ "call", "invoke", "callbr" }) |prefix| {
        if (consumeWord(s, prefix)) |rest| return rest;
    }
    return null;
}
pub fn operation(a: Allocator, instruction: []const u8) !?json.Value {
    const body = callBody(instruction) orelse return null;
    var words = std.mem.tokenizeAny(u8, body, whitespace);
    while (words.next()) |word| {
        if (!std.mem.eql(u8, word, "asm")) continue;
        while (words.next()) |modifier| {
            if (std.mem.startsWith(u8, modifier, "\"")) return null;
            if (!std.mem.eql(u8, modifier, "sideeffect") and !std.mem.eql(u8, modifier, "alignstack") and !std.mem.eql(u8, modifier, "inteldialect") and !std.mem.eql(u8, modifier, "unwind")) break;
        }
    }
    var op = json.Value{ .object = .{} };
    const target = callee(body) orelse {
        try op.object.put(a, "kind", .{ .string = "call" });
        try op.object.put(a, "callee", .{ .string = "<indirect expression>" });
        return op;
    };
    const name = try unquote(a, target.text[1..]);
    if (target.text[0] == '@') {
        const base = if (std.mem.startsWith(u8, name, "llvm.")) name[5..] else name;
        inline for (.{ "memcpy", "memmove", "memset" }) |kind| {
            if (std.mem.eql(u8, base, kind) or std.mem.startsWith(u8, base, kind ++ ".")) {
                const arguments = body[target.end..];
                var depth: usize = 1;
                var quoted = false;
                var escaped = false;
                var end = arguments.len;
                for (arguments, 0..) |c, i| {
                    if (quoted) {
                        if (escaped) {
                            escaped = false;
                        } else if (c == '\\') {
                            escaped = true;
                        } else if (c == '"') {
                            quoted = false;
                        }
                    } else if (c == '"') {
                        quoted = true;
                    } else if (c == '(') {
                        depth += 1;
                    } else if (c == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            end = i;
                            break;
                        }
                    }
                }
                const args = try splitFields(a, arguments[0..end]);
                var size: json.Value = .null;
                if (args.len > 2) {
                    var tokens = std.mem.tokenizeAny(u8, args[2], whitespace);
                    const ty = tokens.next() orelse "";
                    var last: []const u8 = "";
                    var attributes_ok = true;
                    while (tokens.next()) |token| {
                        if (last.len > 0) for (last) |c| {
                            if (!std.ascii.isAlphanumeric(c) and c != '_') attributes_ok = false;
                        };
                        last = token;
                    }
                    if (ty.len > 1 and ty[0] == 'i' and attributes_ok) {
                        if (std.fmt.parseInt(u16, ty[1..], 10)) |_| {
                            if (std.fmt.parseInt(i64, last, 10)) |n| {
                                if (n >= 0 and last.len > 0 and std.ascii.isDigit(last[0])) size = .{ .integer = n };
                            } else |_| {}
                        } else |_| {}
                    }
                }
                try op.object.put(a, "kind", .{ .string = kind });
                try op.object.put(a, "bytes", size);
                return op;
            }
        }
        if (std.mem.startsWith(u8, name, "llvm.") or std.mem.startsWith(u8, name, "debug.FullPanic(")) return null;
    }
    try op.object.put(a, "kind", .{ .string = "call" });
    try op.object.put(a, "callee", .{ .string = if (target.text[0] == '@') name else "<indirect>" });
    return op;
}
fn diagnosticLess(_: void, lhs: json.Value, rhs: json.Value) bool {
    const path_order = std.mem.order(u8, lhs.object.get("path").?.string, rhs.object.get("path").?.string);
    if (path_order != .eq) return path_order == .lt;
    const l = lhs.object.get("line").?.integer;
    const r = rhs.object.get("line").?.integer;
    if (l != r) return l < r;
    const kind_order = std.mem.order(u8, if (lhs.object.get("kind")) |kind| kind.string else "", if (rhs.object.get("kind")) |kind| kind.string else "");
    if (kind_order != .eq) return kind_order == .lt;
    return std.mem.lessThan(u8, if (lhs.object.get("callee")) |callee_name| callee_name.string else "", if (rhs.object.get("callee")) |callee_name| callee_name.string else "");
}
const Analysis = struct {
    a: Allocator,
    diagnostics: std.StringHashMap(json.Value),
    no_debug: usize = 0,
    unresolved_debug: usize = 0,

    fn record(self: *Analysis, debug: *DebugInfo, instruction: []const u8, ir_line: usize, ir_column: usize, function: ?[]const u8) !void {
        var op = (try operation(self.a, instruction)) orelse return;
        var source: []const u8 = "";
        var line: usize = 0;
        var column: usize = 0;
        if (std.mem.indexOf(u8, instruction, "!dbg !")) |dbg_start| {
            const start = dbg_start + 5;
            var end = start + 1;
            while (end < instruction.len and std.ascii.isDigit(instruction[end])) : (end += 1) {}
            if (debug.nodes.get(instruction[start..end])) |node| {
                if (std.mem.eql(u8, node.kind, "DILocation")) {
                    source = try debug.sourceFile(node.fields.get("scope") orelse "", 0) orelse "";
                    line = std.fmt.parseInt(usize, node.fields.get("line") orelse "0", 10) catch 0;
                    column = std.fmt.parseInt(usize, node.fields.get("column") orelse "0", 10) catch 0;
                }
            }
            if (source.len == 0 or line == 0) self.unresolved_debug += 1;
        } else {
            self.no_debug += 1;
        }
        try op.object.put(self.a, "path", .{ .string = source });
        try op.object.put(self.a, "line", .{ .integer = @intCast(line) });
        const key = try json.Stringify.valueAlloc(self.a, .{
            source,                                                  line, op.object.get("kind").?.string,
            if (op.object.get("callee")) |name| name.string else "",
        }, .{});
        const previous = self.diagnostics.get(key);
        var instances = if (previous) |p| p.object.get("instances").? else json.Value{ .array = std.array_list.Managed(json.Value).init(self.a) };
        var instance: json.Value = .{ .object = .{} };
        try instance.object.put(self.a, "ir_line", .{ .integer = @intCast(ir_line) });
        try instance.object.put(self.a, "ir_column", .{ .integer = @intCast(ir_column) });
        try instance.object.put(self.a, "function", if (function) |f| .{ .string = f } else .null);
        try instance.object.put(self.a, "source_column", .{ .integer = @intCast(column) });
        if (op.object.get("bytes")) |size| try instance.object.put(self.a, "bytes", size);
        try instances.array.append(instance);
        try op.object.put(self.a, "instances", instances);
        try op.object.put(self.a, "instance_count", .{ .integer = @intCast(instances.array.items.len) });
        if (op.object.get("bytes")) |size| {
            if (previous) |p| {
                const old = p.object.get("bytes").?;
                try op.object.put(self.a, "bytes", if (old == .null or size == .null) .null else .{ .integer = @max(old.integer, size.integer) });
            }
        }
        try self.diagnostics.put(key, op);
    }
};

/// Summarize a single LLVM IR file. Source paths are debug metadata only:
/// no source files are opened, checked, or hashed.
pub fn analyze(a: Allocator, io: std.Io, ir_path: []const u8) !json.Value {
    var analysis = Analysis{ .a = a, .diagnostics = .init(a) };
    const text = try std.Io.Dir.cwd().readFileAlloc(io, ir_path, a, .unlimited);
    var debug = try DebugInfo.init(a, text);
    var lines = Lines{ .text = text };
    var number: usize = 0;
    var function: ?[]const u8 = null;
    var pending: ?[]const u8 = null;
    var pending_function: ?[]const u8 = null;
    var pending_line: usize = 0;
    var pending_column: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const stripped = std.mem.trim(u8, line, whitespace);
        if (std.mem.startsWith(u8, stripped, "define ")) function = if (callee(stripped)) |sym| try unquote(a, sym.text[1..]) else null;
        if (callBody(stripped) != null) {
            if (pending) |p| try analysis.record(&debug, p, pending_line, pending_column, pending_function);
            pending = stripped;
            pending_line = number;
            pending_column = line.len - std.mem.trimStart(u8, line, whitespace).len + 1;
            pending_function = function;
        } else if (pending != null and ((stripped.len > 0 and std.mem.startsWith(u8, line, "    ")) or std.mem.startsWith(u8, stripped, "to label ") or std.mem.startsWith(u8, stripped, "unwind label "))) {
            pending = try std.fmt.allocPrint(a, "{s} {s}", .{ pending.?, stripped });
        } else {
            if (pending) |p| try analysis.record(&debug, p, pending_line, pending_column, pending_function);
            pending = null;
        }
        if (pending) |p| if (std.mem.indexOf(u8, p, "!dbg !") != null) {
            try analysis.record(&debug, p, pending_line, pending_column, pending_function);
            pending = null;
        };
    }
    if (pending) |p| try analysis.record(&debug, p, pending_line, pending_column, pending_function);
    var report: json.Value = .{ .object = .{} };
    try report.object.put(a, "version", .{ .integer = 2 });
    try report.object.put(a, "ir", .{ .string = ir_path });
    var diagnostics = json.Value{ .array = std.array_list.Managed(json.Value).init(a) };
    var it = analysis.diagnostics.valueIterator();
    while (it.next()) |value| try diagnostics.array.append(value.*);
    std.mem.sort(json.Value, diagnostics.array.items, {}, diagnosticLess);
    try report.object.put(a, "diagnostics", diagnostics);
    var unmapped: json.Value = .{ .object = .{} };
    try unmapped.object.put(a, "calls_without_debug_location", .{ .integer = @intCast(analysis.no_debug) });
    try unmapped.object.put(a, "calls_with_unresolved_debug_location", .{ .integer = @intCast(analysis.unresolved_debug) });
    try report.object.put(a, "unmapped", unmapped);
    return report;
}
pub fn description(a: Allocator, diagnostic: json.Value) ![]const u8 {
    const kind = diagnostic.object.get("kind").?.string;
    if (std.mem.eql(u8, kind, "call")) return std.fmt.allocPrint(a, "not inlined: {s}", .{try json.Stringify.valueAlloc(a, diagnostic.object.get("callee").?.string, .{})});
    const size = diagnostic.object.get("bytes").?;
    if (size == .null) return std.fmt.allocPrint(a, "{s} (dynamic size)", .{kind});
    return std.fmt.allocPrint(a, "{s} ({s}{d} bytes)", .{ kind, if ((diagnostic.object.get("instance_count") orelse json.Value{ .integer = 0 }).integer > 1) "max " else "", size.integer });
}
pub const ApplyResult = struct { count: usize, skipped: []const []const u8 };
pub fn apply(a: Allocator, io: std.Io, report: json.Value, workspace: []const u8, prefixes: []const []const u8, remove: bool, check: bool) !ApplyResult {
    if (report != .object) return error.InvalidReport;
    const version = report.object.get("version") orelse return error.UnsupportedReportVersion;
    if (version != .integer or version.integer != 1) return error.UnsupportedReportVersion;
    const sources = report.object.get("sources") orelse return error.InvalidReport;
    const diagnostics = report.object.get("diagnostics") orelse return error.InvalidReport;
    if (sources != .object or diagnostics != .array) return error.InvalidReport;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, workspace, a);
    const root_prefix = if (std.mem.endsWith(u8, root, "/")) root else try std.fmt.allocPrint(a, "{s}/", .{root});
    const Change = struct { path: []const u8, text: []const u8 };
    var changes: std.ArrayList(Change) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (sources.object.keys(), sources.object.values()) |source, expected| {
        var selected = false;
        for (prefixes) |prefix| {
            const p = std.mem.trimEnd(u8, prefix, "/");
            if (std.mem.startsWith(u8, source, p) and source.len > p.len and source[p.len] == '/') selected = true;
        }
        if (!selected) continue;
        if (!validSource(source)) return error.SourceEscapesWorkspace;
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(a, &.{ root, source }), a);
        if (!std.mem.startsWith(u8, path, root_prefix)) return error.SourceEscapesWorkspace;
        const original = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        const clean = try cleanSource(a, original);
        if (!remove and !std.mem.eql(u8, try digest(a, clean), expected.string)) return error.SourceChangedRebuildReport;
        var lines = Lines{ .text = clean };
        var number: usize = 0;
        var updated: std.ArrayList(u8) = .empty;
        while (lines.next()) |line| {
            number += 1;
            var messages: std.ArrayList([]const u8) = .empty;
            if (!remove) for (diagnostics.array.items) |diagnostic| {
                if (!std.mem.eql(u8, diagnostic.object.get("path").?.string, source) or diagnostic.object.get("line").?.integer != number) continue;
                if (std.mem.eql(u8, diagnostic.object.get("kind").?.string, "call") and std.mem.startsWith(u8, diagnostic.object.get("callee").?.string, "debug.FullPanic(")) continue;
                try messages.append(a, try description(a, diagnostic));
            };
            if (messages.items.len == 0 or std.mem.startsWith(u8, std.mem.trim(u8, line, whitespace), "\\\\")) {
                if (messages.items.len > 0) try skipped.append(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ source, number }));
                try updated.appendSlice(a, line);
                continue;
            }
            const eol = ending(line);
            try updated.appendSlice(a, line[0 .. line.len - eol.len]);
            try updated.appendSlice(a, marker);
            std.mem.sort([]const u8, messages.items, {}, struct {
                fn less(_: void, l: []const u8, r: []const u8) bool {
                    return std.mem.lessThan(u8, l, r);
                }
            }.less);
            var previous: ?[]const u8 = null;
            for (messages.items) |message| {
                if (previous) |p| {
                    if (std.mem.eql(u8, p, message)) continue;
                    try updated.appendSlice(a, "; ");
                }
                try updated.appendSlice(a, message);
                previous = message;
            }
            try updated.appendSlice(a, eol);
        }
        if (!std.mem.eql(u8, original, updated.items)) try changes.append(a, .{ .path = path, .text = try updated.toOwnedSlice(a) });
    }
    // Validate every selected file before changing any of them.
    if (!check) for (changes.items) |change| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = change.path, .data = change.text });
    return .{ .count = changes.items.len, .skipped = try skipped.toOwnedSlice(a) };
}

test "operation parsing handles attributes, indirect calls, and exclusions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = .{
        .{ "call void @llvm.memcpy.p0.p0.i64(ptr align 8 dereferenceable(64) %a, ptr %b, i64 64, i1 false), !dbg !4", "memcpy", @as(?i64, 64) },
        .{ "%r = call ptr @memmove(ptr %a, ptr %b, i64 128), !dbg !4", "memmove", @as(?i64, 128) },
        .{ "call void @memset(ptr %a, i8 0, i64 %n), !dbg !4", "memset", @as(?i64, null) },
    };
    inline for (cases) |case| {
        const op = (try operation(a, case[0])).?;
        try std.testing.expectEqualStrings(case[1], op.object.get("kind").?.string);
        if (case[2]) |n| try std.testing.expectEqual(n, op.object.get("bytes").?.integer) else try std.testing.expect(op.object.get("bytes").? == .null);
    }
    const indirect = (try operation(a, "call void %memcpy(), !dbg !4")).?;
    try std.testing.expectEqualStrings("<indirect>", indirect.object.get("callee").?.string);
    for ([_][]const u8{
        "call void asm sideeffect \"nop\", \"\"(), !dbg !4",
        "call void @llvm.lifetime.end.p0(ptr %a)",
        "call void @\"debug.FullPanic(...).outOfBounds\"()",
        "%r = add i64 1, 2",
    }) |instruction| try std.testing.expect(try operation(a, instruction) == null);
}

test "annotation cleaning preserves literals and line endings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const literal = "const s = \" // llvm-ir: example\";\n";
    try std.testing.expectEqualStrings(literal, try cleanSource(a, literal));
    try std.testing.expectEqualStrings("work(); // original\r\n", try cleanSource(a, "work(); // original // llvm-ir: foo\r\n"));
    const multiline = "    \\\\text // llvm-ir: string data\n";
    try std.testing.expectEqualStrings(multiline, try cleanSource(a, multiline));
}

test "IR-only summary preserves debug paths and references every instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.ll", .data = @embedFile("test/report.ll") });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "input.ll", a);
    const report = try analyze(a, std.testing.io, path);
    try std.testing.expectEqual(@as(i64, 2), report.object.get("version").?.integer);
    try std.testing.expectEqualStrings(path, report.object.get("ir").?.string);
    try std.testing.expect(!report.object.contains("sources"));
    try std.testing.expect(!report.object.contains("invalid_debug_locations"));
    const diagnostics = report.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    var instances: usize = 0;
    for (diagnostics) |diagnostic| {
        const source = diagnostic.object.get("path").?.string;
        if (source.len != 0) try std.testing.expectEqualStrings("/nonexistent/workspace/src/../missing.zig", source);
        for (diagnostic.object.get("instances").?.array.items) |instance| {
            instances += 1;
            try std.testing.expect(!instance.object.contains("instruction"));
            try std.testing.expect(!instance.object.contains("ir"));
            try std.testing.expectEqual(@as(i64, 3), instance.object.get("ir_column").?.integer);
            try std.testing.expect(instance.object.get("ir_line").?.integer >= 2);
        }
        const kind = diagnostic.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "memcpy")) {
            try std.testing.expectEqual(@as(i64, 256), diagnostic.object.get("bytes").?.integer);
            try std.testing.expectEqual(@as(i64, 1904), diagnostic.object.get("line").?.integer);
            const copies = diagnostic.object.get("instances").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), copies.len);
            try std.testing.expectEqual(@as(i64, 2), copies[0].object.get("ir_line").?.integer);
            try std.testing.expectEqual(@as(i64, 7), copies[0].object.get("source_column").?.integer);
            try std.testing.expectEqual(@as(i64, 8), copies[0].object.get("bytes").?.integer);
        } else if (std.mem.eql(u8, kind, "memset")) {
            try std.testing.expect(diagnostic.object.get("bytes").? == .null);
        } else if (std.mem.eql(u8, diagnostic.object.get("callee").?.string, "foo")) {
            try std.testing.expectEqual(@as(i64, 2), diagnostic.object.get("instance_count").?.integer);
        } else if (std.mem.eql(u8, diagnostic.object.get("callee").?.string, "other")) {
            try std.testing.expectEqual(@as(i64, 8), diagnostic.object.get("instances").?.array.items[0].object.get("ir_line").?.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, 9), instances);
    const unmapped = report.object.get("unmapped").?.object;
    try std.testing.expectEqual(@as(i64, 1), unmapped.get("calls_without_debug_location").?.integer);
    try std.testing.expectEqual(@as(i64, 1), unmapped.get("calls_with_unresolved_debug_location").?.integer);
}

test "JSON serialization preserves Unicode and escapes quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = (try operation(a, "call void @\"caf\\C3\\A9\\22\"()")).?;
    try std.testing.expectEqualStrings("café\"", op.object.get("callee").?.string);
    try std.testing.expectEqualStrings("not inlined: \"café\\\"\"", try description(a, op));
}

test "unoptimized or stripped metadata is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.ExpectedOptimizedDICompileUnit, DebugInfo.init(a, ""));
    try std.testing.expectError(error.ExpectedOptimizedDICompileUnit, DebugInfo.init(a, "!0 = !DICompileUnit(isOptimized: false)"));
}
