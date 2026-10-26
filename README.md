# LLVM inline annotations

Analyze the optimized LLVM IR produced by LLVM,
and annotate your code with annotations.

Following annotations are emitted:
- *memcpy*: memcpy emitted by Zig, but not removed by LLVM optimization passes
- *memset*: memset emitted by Zig, but not removed by LLVM optimization passes
- *not inlined*: function call that aren't inlined

Apply annotations directly from optimized LLVM IR:

```sh
llvm-inline-annotations apply --ir input.ll
```

The analysis report stays in memory. Alternatively, use `--report analysis.json`
to apply a saved report. Specify exactly one of `--ir` or `--report`.
Add `--clean` to remove existing annotations from the files referenced by the analysis.

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
module optimization to ReleaseSafe. Other release modes are preserved. 
Shared modules inherit these settings. The analyzer runs on the host for cross builds.
