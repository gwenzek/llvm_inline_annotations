# LLVM inline annotations

The Zig 0.17.0 analyzer summarizes **one optimized LLVM IR file**. Analysis reads
only that `.ll` file: no source manifests, source reads, hashes, line-count checks,
or dependency-file output.

```sh
zig build
zig build run -- analyze --ir program.ll --output analysis.json
zig build test
zig build example-report
zig build self-report
```

Version-2 reports keep the LLVM IR path once, in the top-level `ir` field.
Diagnostics group surviving calls and memory operations by debug source path,
source line, operation kind, and callee. Each occurrence has an `instances` entry
with a one-based `ir_line` and `ir_column` pointing to the start of the instruction
in that file. Multiline instructions point to their first line. Columns are byte
offsets, so a tab counts as one byte. No instruction text is copied into JSON.

```json
{
  "version": 2,
  "ir": "/build/program.ll",
  "diagnostics": [{
    "path": "src/main.zig",
    "line": 42,
    "kind": "memcpy",
    "bytes": 256,
    "instance_count": 1,
    "instances": [{
      "ir_line": 120,
      "ir_column": 3,
      "source_column": 9,
      "function": "main.work",
      "bytes": 256
    }]
  }],
  "unmapped": {
    "calls_without_debug_location": 0,
    "calls_with_unresolved_debug_location": 0
  }
}
```

Memory operations retain their maximum constant size; any dynamic size makes the
merged `bytes` null. Instances preserve individual sizes. Calls also retain every
IR occurrence. Operations without usable debug metadata remain in the report
with an empty source path and/or line zero and contribute to the `unmapped`
counts. Source locations are lexical debug locations, not the outer `inlinedAt`
call site. Non-memory LLVM intrinsics, inline assembly, and generated
`debug.FullPanic(...)` calls remain excluded.

Debug paths come from the `DIFile` filename and directory without normalization
or filtering. Missing, external, and generated sources remain in the report.
Keep the `.ll` file alongside the report if you need to inspect the referenced
instructions; moving it requires updating the top-level `ir` path.

## Zig build integration

Add this package as a dependency named `llvm_inline_annotations`, then:

```zig
const annotations = @import("llvm_inline_annotations");

// Inside build(b), after defining exe:
const dep = b.dependency("llvm_inline_annotations", .{});
const report = annotations.addAnalysis(dep.builder, exe);
b.step("analyze", "Summarize optimized LLVM IR")
    .dependOn(&b.addInstallFile(report, "analysis.json").step);
```

The helper returns a `std.Build.LazyPath` for `analysis.json`. Its only analysis
input is `exe.getEmittedLlvmIr()`. There are no analysis options.

The helper enables LLVM and debug information and upgrades Debug or unspecified
module optimization to ReleaseSafe. Other release modes are preserved. Shared
modules inherit these settings. The analyzer runs on the host for cross builds.

`zig build test` runs native Zig tests for parsing, aggregation, IR references,
Unicode, and preserving debug paths without reading source files.

The retained `apply` command supports legacy version-1 reports with source hashes;
it does not accept the new version-2 summaries.
