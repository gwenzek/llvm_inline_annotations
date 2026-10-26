const usage =
    \\Usage: llvm-inline-annotations analyze --ir FILE --output FILE
    \\       llvm-inline-annotations apply (--report FILE | --ir FILE) --workspace DIR [--clean]
    \\
;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var stdout_file: std.Io.File = .stdout();
    var stdout = stdout_file.writer(io, &.{}); // llvm-ir: memset (16 bytes)

    if (args.len < 2) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try stdout.interface.writeAll(usage);
        return;
    }
    const analyzing = std.mem.eql(u8, args[1], "analyze");
    if (!analyzing and !std.mem.eql(u8, args[1], "apply")) return error.InvalidArguments;

    var ir: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var report_path: ?[]const u8 = null;
    var workspace: []const u8 = ".";
    var clean = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.interface.writeAll(usage);
            return;
        }
        if (!analyzing and std.mem.eql(u8, arg, "--clean")) {
            clean = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return error.InvalidArguments;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--ir")) {
            if (ir != null) return error.InvalidArguments;
            ir = value;
        } else if (analyzing and std.mem.eql(u8, arg, "--output")) {
            output = value;
        } else if (!analyzing and std.mem.eql(u8, arg, "--report")) {
            report_path = value;
        } else if (!analyzing and std.mem.eql(u8, arg, "--workspace")) {
            workspace = value;
        } else return error.InvalidArguments;
    }
    if (analyzing) {
        const ir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ir orelse return error.InvalidArguments, a);
        if (output == null) return error.InvalidArguments;
        const input = try std.Io.Dir.cwd().openFile(io, ir_path, .{});
        defer input.close(io);
        var input_buffer: [4096]u8 = undefined; // llvm-ir: memset (4096 bytes)
        var reader = input.reader(io, &input_buffer); // llvm-ir: memcpy (40 bytes)
        const report = try analyze(a, &reader.interface, ir_path); // llvm-ir: not inlined: "analyzer.analyze"
        const file = try std.Io.Dir.cwd().createFile(io, output.?, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined; // llvm-ir: memset (4096 bytes)
        var writer = file.writer(io, &buffer);
        try json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        try stdout.interface.print("Found {d} diagnostics\n", .{report.object.get("diagnostics").?.array.items.len});
    } else {
        if ((report_path == null) == (ir == null)) return error.InvalidArguments;
        const report = if (ir) |path| report: {
            const ir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a); // llvm-ir: not inlined: "Io.Dir.realPathFileAlloc"
            const input = try std.Io.Dir.cwd().openFile(io, ir_path, .{});
            defer input.close(io);
            var buffer: [4096]u8 = undefined; // llvm-ir: memset (4096 bytes)
            var reader = input.reader(io, &buffer); // llvm-ir: memcpy (40 bytes)
            break :report try analyze(a, &reader.interface, ir_path); // llvm-ir: memcpy (56 bytes); not inlined: "analyzer.analyze"
        } else report: {
            const file = try std.Io.Dir.cwd().openFile(io, report_path.?, .{});
            defer file.close(io);
            var buffer: [4096]u8 = undefined; // llvm-ir: memset (4096 bytes)
            var reader = file.reader(io, &buffer); // llvm-ir: memcpy (40 bytes)
            var tokens = json.Reader.init(a, &reader.interface);
            defer tokens.deinit(); // llvm-ir: not inlined: "json.Scanner.Reader.deinit"
            break :report try json.parseFromTokenSourceLeaky(json.Value, a, &tokens, .{ // llvm-ir: memcpy (56 bytes); not inlined: "json.static.parseFromTokenSourceLeaky__func_45"
                .max_value_len = std.math.maxInt(usize),
            });
        };
        const result = try apply(a, io, report, workspace, clean); // llvm-ir: not inlined: "analyzer.apply"
        try stdout.interface.print("Updated {d} files; skipped {d} locations\n", .{ result.count, result.skipped.len });
        for (result.skipped) |location| std.debug.print("Report-only diagnostic: {s}\n", .{location});
    }
}

/// Summarize LLVM IR from a reader, skipping lines that exceed its buffer.
/// Source paths are debug metadata only:
/// no source files are opened, checked, or hashed.
pub fn analyze(a: Allocator, reader: *std.Io.Reader, ir_path: []const u8) !json.Value {
    var analysis: Analysis = .{ .a = a, .diagnostics = .init(a) }; // llvm-ir: memcpy (max 40 bytes); memset (16 bytes)
    var debug: DebugInfo = .{ .a = a, .nodes = .init(a), .cache = .init(a) }; // llvm-ir: memcpy (max 40 bytes)
    // Debug metadata usually follows instructions, so resolve calls after EOF.
    const Call = struct { text: []const u8, line: usize, column: usize, function: ?[]const u8 };
    var calls: std.ArrayList(Call) = .empty; // llvm-ir: memcpy (32 bytes)
    var number: usize = 0;
    var function: ?[]const u8 = null;
    var pending: ?[]const u8 = null;
    var pending_function: ?[]const u8 = null;
    var pending_line: usize = 0;
    var pending_column: usize = 0;
    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Do not parse a truncated instruction or join its tail to another call.
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) { // llvm-ir: not inlined: "Io.Reader.discardDelimiterInclusive"
                    error.EndOfStream => {},
                    else => return discard_err,
                };
                number += 1;
                pending = null;
                continue;
            },
            else => return err,
        } orelse break;
        number += 1;
        try debug.addLine(line);
        const stripped = std.mem.trim(u8, line, whitespace);
        if (std.mem.startsWith(u8, stripped, "define ")) {
            function = if (callee(stripped)) |sym|
                try unquote(a, sym.text[1..]) // llvm-ir: not inlined: "analyzer.unquote"
            else
                null;
        }
        if (callBody(stripped) != null) { // llvm-ir: not inlined: "analyzer.callBody"
            if (pending) |p| try calls.append(a, .{ .text = p, .line = pending_line, .column = pending_column, .function = pending_function }); // llvm-ir: not inlined: "array_list.Aligned(analyzer.analyze.Call,null).append"
            pending = try a.dupe(u8, stripped);
            pending_line = number;
            pending_column = line.len - std.mem.trimStart(u8, line, whitespace).len + 1;
            pending_function = function;
        } else if (pending != null and ((stripped.len > 0 and std.mem.startsWith(u8, line, "    ")) or std.mem.startsWith(u8, stripped, "to label ") or std.mem.startsWith(u8, stripped, "unwind label "))) {
            pending = try std.fmt.allocPrint(a, "{s} {s}", .{ pending.?, stripped });
        } else {
            if (pending) |p| try calls.append(a, .{ .text = p, .line = pending_line, .column = pending_column, .function = pending_function }); // llvm-ir: not inlined: "array_list.Aligned(analyzer.analyze.Call,null).append"
            pending = null;
        }
        if (pending) |p| if (std.mem.indexOf(u8, p, "!dbg !") != null) { // llvm-ir: not inlined: "mem.find__func_25"
            try calls.append(a, .{ .text = p, .line = pending_line, .column = pending_column, .function = pending_function }); // llvm-ir: not inlined: "array_list.Aligned(analyzer.analyze.Call,null).append"
            pending = null;
        };
    }
    if (pending) |p| try calls.append(a, .{ .text = p, .line = pending_line, .column = pending_column, .function = pending_function }); // llvm-ir: not inlined: "array_list.Aligned(analyzer.analyze.Call,null).append"
    if (debug.units == 0) return error.ExpectedOptimizedDICompileUnit; // llvm-ir: memcpy (64 bytes)
    for (calls.items) |call| try analysis.record(&debug, call.text, call.line, call.column, call.function);
    var report: json.Value = .{ .object = .{} }; // llvm-ir: memset (40 bytes)
    try report.object.put(a, "version", .{ .integer = 2 });
    try report.object.put(a, "ir", .{ .string = ir_path });

    var diagnostics: json.Value = .{ .array = .init(a) };
    var it = analysis.diagnostics.valueIterator();
    while (it.next()) |value| try diagnostics.array.append(value.*); // llvm-ir: memcpy (56 bytes)
    std.mem.sort(json.Value, diagnostics.array.items, {}, diagnosticLess);
    try report.object.put(a, "diagnostics", diagnostics);
    var unmapped: json.Value = .{ .object = .{} }; // llvm-ir: memset (40 bytes)
    try unmapped.object.put(a, "calls_without_debug_location", .{ .integer = @intCast(analysis.no_debug) });
    try unmapped.object.put(a, "calls_with_unresolved_debug_location", .{ .integer = @intCast(analysis.unresolved_debug) });
    try report.object.put(a, "unmapped", unmapped);
    return report; // llvm-ir: memcpy (56 bytes)
}

const marker = " // llvm-ir: ";
const whitespace = " \t\r\n";

pub fn splitFields(a: Allocator, text: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty; // llvm-ir: memcpy (32 bytes)
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
                try result.append(a, std.mem.trim(u8, text[start..i], whitespace)); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
                start = i + 1;
            },
            else => {},
        }
    }
    try result.append(a, std.mem.trim(u8, text[start..], whitespace)); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
    return result.toOwnedSlice(a); // llvm-ir: memcpy (24 bytes); not inlined: "array_list.Aligned([]const u8,null).toOwnedSlice"
}

fn unquote(a: Allocator, raw: []const u8) ![]const u8 {
    const text = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
    var result: std.ArrayList(u8) = .empty; // llvm-ir: memcpy (max 32 bytes)
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
    return result.toOwnedSlice(a); // llvm-ir: memcpy (24 bytes); not inlined: "array_list.Aligned(u8,null).toOwnedSlice"
}

fn ending(line: []const u8) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (std.mem.endsWith(u8, line, "\r\n")) return "\r\n";
    }
    return if (std.mem.endsWith(u8, line, "\n")) "\n" else "";
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
            if (std.mem.indexOf(u8, line[i -| 1..], marker)) |off| // llvm-ir: not inlined: "mem.find__func_25"
                return line[0 .. (i -| 1) + off];
            return line;
        }
    }
    return line;
}

pub fn cleanSource(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty; // llvm-ir: memcpy (32 bytes)
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        const clean = stripAnnotation(line);
        try out.appendSlice(a, clean);
        if (clean.len != line.len) try out.appendSlice(a, ending(line));
    }
    return out.toOwnedSlice(a); // llvm-ir: memcpy (24 bytes); not inlined: "array_list.Aligned(u8,null).toOwnedSlice"
}

const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    fn next(self: *Lines) ?[]const u8 {
        if (self.pos == self.text.len) return null;
        const start = self.pos;
        self.pos = if (std.mem.indexOfScalarPos(u8, self.text, start, '\n')) |n| n + 1 else self.text.len; // llvm-ir: not inlined: "mem.findScalarPos__func_161"
        return self.text[start..self.pos];
    }
};
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
    units: usize = 0,
    fn addLine(self: *DebugInfo, raw: []const u8) !void {
        const trimmed = std.mem.trim(u8, raw, whitespace);
        if (!std.mem.startsWith(u8, trimmed, "!")) return;
        const line = try self.a.dupe(u8, trimmed);
        const sep = std.mem.indexOf(u8, line, " = ") orelse return;
        _ = std.fmt.parseInt(usize, line[1..sep], 10) catch return; // llvm-ir: not inlined: "fmt.parseInt__func_26"
        var body = line[sep + 3 ..];
        if (std.mem.startsWith(u8, body, "distinct ")) body = body[9..];
        if (!std.mem.startsWith(u8, body, "!") or !std.mem.endsWith(u8, body, ")")) return;
        const open = std.mem.indexOfScalar(u8, body, '(') orelse return;
        var node = Node{ .kind = body[1..open], .fields = .init(self.a) }; // llvm-ir: memcpy (max 40 bytes)
        for (try splitFields(self.a, body[open + 1 .. body.len - 1])) |field| { // llvm-ir: not inlined: "analyzer.splitFields"
            if (std.mem.indexOf(u8, field, ": ")) |colon| try node.fields.put(field[0..colon], field[colon + 2 ..]);
        }
        if (std.mem.eql(u8, node.kind, "DICompileUnit")) {
            self.units += 1;
            if (!std.mem.eql(u8, node.fields.get("isOptimized") orelse "", "true")) return error.ExpectedOptimizedDICompileUnit; // llvm-ir: not inlined: "hash_map.HashMap([]const u8,[]const u8,hash_map.StringContext,80).get"
        }
        try self.nodes.put(line[0..sep], node); // llvm-ir: not inlined: "hash_map.HashMap([]const u8,analyzer.Node,hash_map.StringContext,80).put"
    }
    fn sourceFile(self: *DebugInfo, ref: []const u8, depth: usize) !?[]const u8 {
        if (self.cache.get(ref)) |cached| return cached; // llvm-ir: memcpy (16 bytes)
        if (depth > self.nodes.count()) return null; // llvm-ir: memset (24 bytes)
        const node = self.nodes.get(ref) orelse return null; // llvm-ir: memcpy (max 16 bytes); memset (24 bytes)
        var result: ?[]const u8 = null;
        if (std.mem.eql(u8, node.kind, "DIFile")) {
            const filename = try unquote(self.a, node.fields.get("filename") orelse ""); // llvm-ir: memcpy (max 16 bytes); not inlined: "analyzer.unquote"
            const directory = try unquote(self.a, node.fields.get("directory") orelse ""); // llvm-ir: memcpy (max 16 bytes); not inlined: "analyzer.unquote"
            if (filename.len != 0) {
                const path = if (std.fs.path.isAbsolutePosix(filename) or directory.len == 0)
                    filename
                else
                    try std.fmt.allocPrint(self.a, "{s}/{s}", .{ std.mem.trimEnd(u8, directory, "/"), filename }); // llvm-ir: memcpy (16 bytes); not inlined: "fmt.allocPrint__func_37"; not inlined: "mem.trimEnd__func_36"
                result = path;
            }
        } else {
            result = try self.sourceFile( // llvm-ir: not inlined: "analyzer.DebugInfo.sourceFile"
                node.fields.get("file") orelse node.fields.get("scope") orelse "", // llvm-ir: memcpy (max 16 bytes)
                depth + 1,
            );
        }
        try self.cache.put(ref, result);
        return result;
    }
};

const Symbol = struct { text: []const u8, end: usize };

fn symbolAt(s: []const u8, start: usize) ?Symbol {
    if (start >= s.len or (s[start] != '@' and s[start] != '%')) return null; // llvm-ir: memset (32 bytes)
    var i = start + 1;
    if (i < s.len and s[i] == '"') {
        i += 1;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\') {
                i += 1;
            } else if (s[i] == '"') {
                return .{ .text = s[start .. i + 1], .end = i + 1 };
            }
        }
        return null; // llvm-ir: memset (32 bytes)
    }
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or std.mem.indexOfScalar(u8, "-$._", s[i]) != null)) : (i += 1) {}
    return if (i > start + 1) .{ .text = s[start..i], .end = i } else null; // llvm-ir: memset (32 bytes)
}

fn callee(s: []const u8) ?Symbol {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (symbolAt(s, i)) |sym| { // llvm-ir: not inlined: "analyzer.symbolAt"
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
    if (symbolAt(s, 0)) |sym| { // llvm-ir: not inlined: "analyzer.symbolAt"
        s = std.mem.trim(u8, s[sym.end..], whitespace);
        if (!std.mem.startsWith(u8, s, "=")) return null;
        s = std.mem.trim(u8, s[1..], whitespace);
    }
    inline for (.{ "tail", "musttail", "notail" }) |prefix| {
        if (consumeWord(s, prefix)) |rest| s = rest; // llvm-ir: not inlined: "analyzer.consumeWord"
    }
    inline for (.{ "call", "invoke", "callbr" }) |prefix| {
        if (consumeWord(s, prefix)) |rest| return rest; // llvm-ir: not inlined: "analyzer.consumeWord"
    }
    return null;
}

pub fn operation(a: Allocator, instruction: []const u8) !?json.Value {
    const body = callBody(instruction) orelse return null; // llvm-ir: not inlined: "analyzer.callBody"
    var words = std.mem.tokenizeAny(u8, body, whitespace);
    while (words.next()) |word| { // llvm-ir: not inlined: "mem.TokenIterator(u8,.any).next"
        if (!std.mem.eql(u8, word, "asm")) continue;
        while (words.next()) |modifier| { // llvm-ir: not inlined: "mem.TokenIterator(u8,.any).next"
            if (std.mem.startsWith(u8, modifier, "\"")) return null;
            if (!std.mem.eql(u8, modifier, "sideeffect") and
                !std.mem.eql(u8, modifier, "alignstack") and
                !std.mem.eql(u8, modifier, "inteldialect") and
                !std.mem.eql(u8, modifier, "unwind"))
                break;
        }
    }
    var op = json.Value{ .object = .{} }; // llvm-ir: memcpy (56 bytes)
    const target = callee(body) orelse {
        try op.object.put(a, "kind", .{ .string = "call" });
        try op.object.put(a, "callee", .{ .string = "<indirect expression>" });
        return op;
    };
    const name = try unquote(a, target.text[1..]); // llvm-ir: not inlined: "analyzer.unquote"
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
                const args = try splitFields(a, arguments[0..end]); // llvm-ir: not inlined: "analyzer.splitFields"
                var size: json.Value = .null;
                if (args.len > 2) {
                    var tokens = std.mem.tokenizeAny(u8, args[2], whitespace);
                    const ty = tokens.next() orelse ""; // llvm-ir: not inlined: "mem.TokenIterator(u8,.any).next"
                    var last: []const u8 = "";
                    var attributes_ok = true;
                    while (tokens.next()) |token| { // llvm-ir: not inlined: "mem.TokenIterator(u8,.any).next"
                        if (last.len > 0) for (last) |c| {
                            if (!std.ascii.isAlphanumeric(c) and c != '_') attributes_ok = false;
                        };
                        last = token;
                    }
                    if (ty.len > 1 and ty[0] == 'i' and attributes_ok) {
                        if (std.fmt.parseInt(u16, ty[1..], 10)) |_| { // llvm-ir: not inlined: "fmt.parseInt__func_34"
                            if (std.fmt.parseInt(i64, last, 10)) |n| { // llvm-ir: not inlined: "fmt.parseInt__func_35"
                                if (n >= 0 and last.len > 0 and std.ascii.isDigit(last[0]))
                                    size = .{ .integer = n };
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

fn diagnosticLess(_: void, lhs: json.Value, rhs: json.Value) bool { // llvm-ir: memcpy (max 16 bytes)
    const path_order = std.mem.order(u8, lhs.object.get("path").?.string, rhs.object.get("path").?.string); // llvm-ir: memcpy (max 16 bytes)
    if (path_order != .eq) return path_order == .lt;
    const l = lhs.object.get("line").?.integer; // llvm-ir: memcpy (16 bytes)
    const r = rhs.object.get("line").?.integer; // llvm-ir: memcpy (16 bytes)
    if (l != r) return l < r;
    const kind_order = std.mem.order(
        u8,
        if (lhs.object.get("kind")) |kind| kind.string else "", // llvm-ir: memcpy (16 bytes)
        if (rhs.object.get("kind")) |kind| kind.string else "", // llvm-ir: memcpy (16 bytes)
    );
    if (kind_order != .eq) return kind_order == .lt;
    return std.mem.lessThan(
        u8,
        if (lhs.object.get("callee")) |callee_name| callee_name.string else "", // llvm-ir: memcpy (16 bytes)
        if (rhs.object.get("callee")) |callee_name| callee_name.string else "", // llvm-ir: memcpy (16 bytes)
    );
}

const Analysis = struct {
    a: Allocator,
    diagnostics: std.StringHashMap(json.Value),
    no_debug: usize = 0,
    unresolved_debug: usize = 0,

    fn record(self: *Analysis, debug: *DebugInfo, instruction: []const u8, ir_line: usize, ir_column: usize, function: ?[]const u8) !void {
        var op = (try operation(self.a, instruction)) orelse return; // llvm-ir: memcpy (56 bytes)
        var source: []const u8 = "";
        var line: usize = 0;
        var column: usize = 0;
        if (std.mem.indexOf(u8, instruction, "!dbg !")) |dbg_start| { // llvm-ir: not inlined: "mem.find__func_25"
            const start = dbg_start + 5;
            var end = start + 1;
            while (end < instruction.len and std.ascii.isDigit(instruction[end])) : (end += 1) {}
            if (debug.nodes.get(instruction[start..end])) |node| { // llvm-ir: memcpy (16 bytes)
                if (std.mem.eql(u8, node.kind, "DILocation")) {
                    source = try debug.sourceFile(node.fields.get("scope") orelse "", 0) orelse ""; // llvm-ir: memcpy (16 bytes); not inlined: "analyzer.DebugInfo.sourceFile"
                    line = std.fmt.parseInt(usize, node.fields.get("line") orelse "0", 10) catch 0; // llvm-ir: memcpy (16 bytes); not inlined: "fmt.parseInt__func_26"
                    column = std.fmt.parseInt(usize, node.fields.get("column") orelse "0", 10) catch 0; // llvm-ir: memcpy (16 bytes); not inlined: "fmt.parseInt__func_26"
                }
            }
            if (source.len == 0 or line == 0) self.unresolved_debug += 1;
        } else {
            self.no_debug += 1;
        }
        try op.object.put(self.a, "path", .{ .string = source });
        try op.object.put(self.a, "line", .{ .integer = @intCast(line) });
        const key = try json.Stringify.valueAlloc(self.a, .{
            source, line, op.object.get("kind").?.string, // llvm-ir: memcpy (16 bytes)
            if (op.object.get("callee")) |name| name.string else "", // llvm-ir: memcpy (16 bytes)
        }, .{});
        const previous = self.diagnostics.get(key); // llvm-ir: memcpy (16 bytes)
        var instances = if (previous) |p| p.object.get("instances").? else json.Value{ .array = std.array_list.Managed(json.Value).init(self.a) }; // llvm-ir: memcpy (max 56 bytes)
        var instance: json.Value = .{ .object = .{} }; // llvm-ir: memset (40 bytes)
        try instance.object.put(self.a, "ir_line", .{ .integer = @intCast(ir_line) });
        try instance.object.put(self.a, "ir_column", .{ .integer = @intCast(ir_column) });
        try instance.object.put(self.a, "function", if (function) |f| .{ .string = f } else .null);
        try instance.object.put(self.a, "source_column", .{ .integer = @intCast(column) });
        if (op.object.get("bytes")) |size| try instance.object.put(self.a, "bytes", size); // llvm-ir: memcpy (max 56 bytes)
        try instances.array.append(instance);
        try op.object.put(self.a, "instances", instances);
        try op.object.put(self.a, "instance_count", .{ .integer = @intCast(instances.array.items.len) });
        if (op.object.get("bytes")) |size| { // llvm-ir: memcpy (16 bytes)
            if (previous) |p| { // llvm-ir: memcpy (16 bytes)
                const old = p.object.get("bytes").?;
                try op.object.put(self.a, "bytes", if (old == .null or size == .null) .null else .{ .integer = @max(old.integer, size.integer) });
            }
        }
        try self.diagnostics.put(key, op);
    }
};

pub fn description(a: Allocator, diagnostic: json.Value) ![]const u8 {
    const kind = diagnostic.object.get("kind").?.string; // llvm-ir: memcpy (16 bytes)
    if (std.mem.eql(u8, kind, "call")) return std.fmt.allocPrint(a, "not inlined: {s}", .{try json.Stringify.valueAlloc(a, diagnostic.object.get("callee").?.string, .{})}); // llvm-ir: memcpy (16 bytes)
    const size = diagnostic.object.get("bytes").?; // llvm-ir: memcpy (16 bytes)
    if (size == .null) return std.fmt.allocPrint(a, "{s} (dynamic size)", .{kind});
    return std.fmt.allocPrint(a, "{s} ({s}{d} bytes)", .{
        kind,
        if ((diagnostic.object.get("instance_count") orelse json.Value{ .integer = 0 }).integer > 1) "max " else "", // llvm-ir: memcpy (16 bytes)
        size.integer,
    });
}

pub const ApplyResult = struct { count: usize, skipped: []const []const u8 };

pub fn apply(a: Allocator, io: std.Io, report: json.Value, workspace: []const u8, clean: bool) !ApplyResult { // llvm-ir: memcpy (16 bytes)
    if (report != .object) return error.InvalidReport; // llvm-ir: memcpy (32 bytes)
    const version = report.object.get("version") orelse return error.UnsupportedReportVersion; // llvm-ir: memcpy (max 32 bytes)
    if (version != .integer or version.integer != 2) return error.UnsupportedReportVersion; // llvm-ir: memcpy (32 bytes)
    var sources: json.Value = .{ .object = .{} }; // llvm-ir: memset (40 bytes)
    var diagnostics = report.object.get("diagnostics") orelse return error.InvalidReport; // llvm-ir: memcpy (max 32 bytes)
    if (diagnostics != .array) return error.InvalidReport; // llvm-ir: memcpy (32 bytes)
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, workspace, a);
    const root_prefix = if (std.mem.endsWith(u8, root, "/")) root else try std.fmt.allocPrint(a, "{s}/", .{root}); // llvm-ir: not inlined: "fmt.allocPrint__func_46"
    var skipped: std.ArrayList([]const u8) = .empty; // llvm-ir: memcpy (32 bytes)
    var mapped: json.Value = .{ .array = .init(a) };
    for (diagnostics.array.items) |diagnostic| { // llvm-ir: memcpy (16 bytes)
        if (diagnostic != .object) return error.InvalidReport; // llvm-ir: memcpy (32 bytes)
        const source = diagnostic.object.get("path") orelse return error.InvalidReport; // llvm-ir: memcpy (max 32 bytes)
        const line = diagnostic.object.get("line") orelse return error.InvalidReport; // llvm-ir: memcpy (max 32 bytes)
        if (source != .string or line != .integer) return error.InvalidReport; // llvm-ir: memcpy (32 bytes)
        if (source.string.len == 0) continue;
        const candidate = try std.fs.path.resolve(a, &.{ root, source.string });
        // Ignore external debug files, even if their suffix matches a local file.
        if (!std.mem.startsWith(u8, candidate, root_prefix)) continue;
        const path = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, a) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try skipped.append(a, source.string); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
                continue;
            },
            else => return err,
        };
        if (!std.mem.startsWith(u8, path, root_prefix)) continue;
        const relative = path[root_prefix.len..];
        if (!std.mem.endsWith(u8, relative, ".zig")) continue;
        var parts = std.mem.tokenizeAny(u8, relative, "/\\");
        var generated = false;
        while (parts.next()) |part| { // llvm-ir: not inlined: "mem.TokenIterator(u8,.any).next"
            if (std.mem.eql(u8, part, ".zig-cache") or std.mem.eql(u8, part, "zig-out") or
                std.mem.eql(u8, part, ".git")) generated = true;
        }
        if (generated) continue;
        try sources.object.put(a, relative, .null);
        var entry: json.Value = .{ .object = .{} }; // llvm-ir: memset (40 bytes)
        for (
            diagnostic.object.keys(), // llvm-ir: memcpy (16 bytes); not inlined: "array_hash_map.Custom([]const u8,json.dynamic.Value,array_hash_map.StringContext,true).keys"
            diagnostic.object.values(), // llvm-ir: memcpy (max 56 bytes); not inlined: "array_hash_map.Custom([]const u8,json.dynamic.Value,array_hash_map.StringContext,true).values"
        ) |key, value| {
            try entry.object.put(a, key, value);
        }
        try entry.object.put(a, "path", .{ .string = relative });
        try mapped.array.append(entry); // llvm-ir: not inlined: "array_list.AlignedManaged(json.dynamic.Value,null).append"
    }
    diagnostics = mapped;
    const Change = struct { path: []const u8, text: []const u8 };
    var changes: std.ArrayList(Change) = .empty; // llvm-ir: memcpy (max 32 bytes)
    for (sources.object.keys()) |source| { // llvm-ir: not inlined: "array_hash_map.Custom([]const u8,json.dynamic.Value,array_hash_map.StringContext,true).keys"
        if (!validSource(source)) return error.SourceEscapesWorkspace; // llvm-ir: memcpy (32 bytes); not inlined: "analyzer.validSource"
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(a, &.{ root, source }), a); // llvm-ir: not inlined: "Io.Dir.realPathFileAlloc"
        if (!std.mem.startsWith(u8, path, root_prefix)) return error.SourceEscapesWorkspace; // llvm-ir: memcpy (32 bytes)
        const original = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited); // llvm-ir: not inlined: "Io.Dir.readFileAlloc"
        const cleaned = try cleanSource(a, original); // llvm-ir: not inlined: "analyzer.cleanSource"
        if (!clean) {
            var source_lines = Lines{ .text = cleaned };
            var count: usize = 0;
            while (source_lines.next() != null) count += 1;
            for (diagnostics.array.items) |diagnostic| { // llvm-ir: memcpy (16 bytes)
                if (!std.mem.eql(u8, diagnostic.object.get("path").?.string, source)) continue; // llvm-ir: memcpy (16 bytes)
                const line = diagnostic.object.get("line").?.integer; // llvm-ir: memcpy (16 bytes)
                if (line <= 0 or line > count) try skipped.append(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ source, line })); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
            }
        }
        var lines = Lines{ .text = cleaned };
        var number: usize = 0;
        var updated: std.ArrayList(u8) = .empty; // llvm-ir: memcpy (32 bytes)
        while (lines.next()) |line| {
            number += 1;
            var messages: std.ArrayList([]const u8) = .empty; // llvm-ir: memcpy (32 bytes)
            if (!clean) for (diagnostics.array.items) |diagnostic| { // llvm-ir: memcpy (max 16 bytes)
                if (!std.mem.eql(u8, diagnostic.object.get("path").?.string, source) or diagnostic.object.get("line").?.integer != number) continue; // llvm-ir: memcpy (max 16 bytes)
                if (std.mem.eql(u8, diagnostic.object.get("kind").?.string, "call")) { // llvm-ir: memcpy (16 bytes)
                    // Don't mark Zig panic as inlining failures, because those are never inlined and shouldn't either
                    if (std.mem.startsWith(u8, diagnostic.object.get("callee").?.string, "debug.FullPanic(") or // llvm-ir: memcpy (16 bytes)
                        std.mem.eql(u8, diagnostic.object.get("callee").?.string, "debug.defaultPanic")) // llvm-ir: memcpy (16 bytes)
                        continue;
                }
                try messages.append(a, try description(a, diagnostic)); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
            };
            if (messages.items.len == 0 or std.mem.startsWith(u8, std.mem.trim(u8, line, whitespace), "\\\\")) {
                if (messages.items.len > 0) try skipped.append(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ source, number })); // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).append"
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
        if (!std.mem.eql(u8, original, updated.items)) {
            try changes.append(a, .{ .path = path, .text = try updated.toOwnedSlice(a) }); // llvm-ir: not inlined: "array_list.Aligned(analyzer.apply.Change,null).append"; not inlined: "array_list.Aligned(u8,null).toOwnedSlice"
        }
    }
    // Validate every file before changing any of them.
    for (changes.items) |change| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = change.path, .data = change.text }); // llvm-ir: not inlined: "Io.Dir.writeFile"
    }
    return .{ .count = changes.items.len, .skipped = try skipped.toOwnedSlice(a) }; // llvm-ir: not inlined: "array_list.Aligned([]const u8,null).toOwnedSlice"
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
    const eol = if (builtin.os.tag == .windows) "\r\n" else "\n";
    try std.testing.expectEqualStrings("work(); // original" ++ eol, try cleanSource(a, "work(); // original // llvm-ir: foo" ++ eol));
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
    var reader = std.Io.Reader.fixed(@embedFile("test/report.ll"));
    const report = try analyze(a, &reader, path);
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
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectError(error.ExpectedOptimizedDICompileUnit, analyze(a, &empty, "input.ll"));
    var unoptimized = std.Io.Reader.fixed("!0 = !DICompileUnit(isOptimized: false)");
    try std.testing.expectError(error.ExpectedOptimizedDICompileUnit, analyze(a, &unoptimized, "input.ll"));
}

test "version-2 annotations map workspace paths and support repeat and clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const eol = if (builtin.os.tag == .windows) "\r\n" else "\n";
    const original = "fn f() void {" ++ eol ++ "    work(); // original" ++ eol ++ "    \\\\string data" ++ eol ++ "}" ++ eol;
    try tmp.dir.writeFile(io, .{ .sub_path = "source.zig", .data = original });
    const path = try tmp.dir.realPathFileAlloc(io, "source.zig", a);
    const root = std.fs.path.dirname(path).?;
    var report = (try json.parseFromSlice(json.Value, a,
        \\{"version":2,"diagnostics":[
        \\ {"path":"source.zig","line":2,"kind":"call","callee":"foo"},
        \\ {"path":"source.zig","line":2,"kind":"memcpy","bytes":8,"instance_count":1},
        \\ {"path":"source.zig","line":3,"kind":"call","callee":"string_call"},
        \\ {"path":"source.zig","line":900,"kind":"call","callee":"invalid"},
        \\ {"path":"../outside.zig","line":1,"kind":"call","callee":"external"}
        \\]}
    , .{ .allocate = .alloc_always })).value;
    // Absolute and relative debug paths must refer to the same workspace file.
    try report.object.getPtr("diagnostics").?.array.items[1].object.put(a, "path", .{ .string = path });
    const result = try apply(a, io, report, root, false);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(usize, 2), result.skipped.len);
    const annotated = try tmp.dir.readFileAlloc(io, "source.zig", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "// original // llvm-ir: memcpy (8 bytes); not inlined: \"foo\"" ++ eol) != null);
    try std.testing.expectEqual(@as(usize, 0), (try apply(a, io, report, root, false)).count);
    try std.testing.expectEqual(@as(usize, 1), (try apply(a, io, report, root, true)).count);
    try std.testing.expectEqualStrings(original, try tmp.dir.readFileAlloc(io, "source.zig", a, .unlimited));
}

test "streaming IR skips oversized lines and preserves locations across refills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const padding: [1024]u8 = @splat('x');
    const oversized = "  call void @ignored(" ++ padding ++ "), !dbg !3";
    const input = oversized ++ "\n" ++ @embedFile("test/report.ll") ++ oversized;
    try tmp.dir.writeFile(io, .{ .sub_path = "input.ll", .data = input });
    const file = try tmp.dir.openFile(io, "input.ll", .{});
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const report = try analyze(a, &reader.interface, "input.ll");
    const diagnostics = report.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.object.get("kind").?.string, "memcpy")) {
            const instances = diagnostic.object.get("instances").?.array.items;
            try std.testing.expectEqual(@as(i64, 3), instances[0].object.get("ir_line").?.integer);
            try std.testing.expectEqual(@as(i64, 4), instances[1].object.get("ir_line").?.integer);
        }
    }
    const unmapped = report.object.get("unmapped").?.object;
    try std.testing.expectEqual(@as(i64, 1), unmapped.get("calls_without_debug_location").?.integer);
    try std.testing.expectEqual(@as(i64, 1), unmapped.get("calls_with_unresolved_debug_location").?.integer);
}
