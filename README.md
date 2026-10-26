# LLVM inline annotations

The native analyzer is written for **Zig 0.17.0**. It generates the same version-1
JSON reports and supports the same `analyze` and `apply` commands as `analyzer.py`.
Python is retained as a compatibility reference and for the existing Bazel rules;
the Zig executable has no Python dependency.

```sh
zig build
zig build run -- analyze --ir program.ll --manifest sources.json --output report.json
zig build run -- apply --report report.json --workspace "$PWD" --prefix src --check
zig build test test-integration
zig build example-report  # writes zig-out/analysis.json
```

`test-integration` requires Python 3 and compares the reports against the Python
implementation, then tests annotation, removal, stale-source rejection, and path
containment through the Zig CLI. `test` runs native Zig unit tests.

A manifest maps workspace-relative names to readable source paths, for example
`{"src/main.zig": "/checkout/src/main.zig"}`. Alternatively, pass repeated
`--source src/main.zig /checkout/src/main.zig` pairs. Multiple `--ir` inputs merge
into one report. Source paths passed this way may be generated build outputs.

## Zig build integration

Add this package as a dependency named `llvm_inline_annotations` in your
`build.zig.zon`. After creating your executable in `build.zig`:

```zig
const annotations = @import("llvm_inline_annotations");

// Inside build(b), after defining exe:
const dep = b.dependency("llvm_inline_annotations", .{});
const report = annotations.addAnalysis(dep.builder, exe, .{
    .sources = &.{
        .{ .name = "src/main.zig", .path = b.path("src/main.zig") },
        .{ .name = "src/model.zig", .path = b.path("src/model.zig") },
    },
    .output_name = "program-analysis.json", // optional; default: analysis.json
});
const install_report = b.addInstallFile(report, "program-analysis.json");
b.step("analyze", "Analyze the executable's optimized LLVM IR")
    .dependOn(&install_report.step);
```

`addAnalysis(b, exe, options)` returns a `std.Build.LazyPath` that can be installed
or passed to another build step. Pass the **dependency's builder** as its first
argument so it can locate `analyzer.zig`. When calling from this package itself,
pass `b`. Source names must be workspace-relative; supply every source you want
included in the report. Calls outside that set are counted as unmapped.

The helper enables LLVM and debug information on the supplied executable and its
module graph, upgrading Debug or unspecified optimization to ReleaseSafe. Other
release modes are preserved. These settings also affect any other artifacts that
share those modules. Call it after configuring imports. The analyzer runs on the
host even if `exe` targets another platform; the executable itself is never run.
Source files and emitted LLVM IR are build inputs, so changes invalidate the
cached report. Report generation does not annotate source files; use `apply`
explicitly for that.

## Existing Bazel workflow

Inspect the optimized Zig IR for `//examples/llm:llm` and annotate ZML:

```sh
bazel build --config=release --strip=never //tools/llvm_inline_annotations:llm_report
bazel run --config=release --strip=never //tools/llvm_inline_annotations:annotate_llm
```

The inspection target uses the same main, sources, and dependencies as the LLM
example. It forces LLVM, ReleaseSafe (including dependency modules), and debug
information. Platform flags still apply. The IR is Zig's optimized output before
machine-code lowering; a remaining memory intrinsic may still become inline
loads/stores during lowering. A surviving call proves it was not fully inlined
at this IR stage, but does not explain why. External and indirect calls are
included; non-memory LLVM intrinsics and inline assembly are excluded.
Compiler-generated `debug.FullPanic(...).*` calls are also excluded from
non-inlining diagnostics. Explicit `debug.panic` and other calls remain visible.

`llm_report.json` in the target's Bazel output directory contains diagnostics and
source hashes. `bazel build` never edits the checkout. `bazel run` applies trailing
`// llvm-ir: ...` comments to original files under `zml/` by default:

```zig
    const copy = value; // llvm-ir: memcpy (max 256 bytes)
    work(); // llvm-ir: not inlined: "work"
```

Comments preserve line numbers and existing comments. Reapplying replaces old
annotations; stale diagnostics disappear. Source hashes ignore these annotations
but reject other edits since compilation, before modifying any file. The marker
` // llvm-ir: ` is reserved for this tool. Multiline string content cannot safely
take trailing comments, so those locations remain in the report and are printed
as skipped. Generated and external sources are not annotated.

For generic specializations and inlined copies, diagnostics are merged by original
file and line. A surviving operation in **any** instance is retained. Memory
operations retain the maximum constant byte count; any dynamic size takes
precedence. The `max` prefix appears only when more than one IR instruction was
recorded for that file, line, and operation kind (even if their sizes agree).
A single instruction is shown as, for example, `memcpy (168 bytes)`.
Each memory diagnostic records `instance_count` and an `instances` list with
the unmerged sizes, full LLVM instructions (including operands and memset fill
values), enclosing functions, IR filenames/line numbers, and debug columns.
These counts describe static IR occurrences, not runtime executions or distinct
generic specializations. Distinct surviving callees are unioned. These are per-operation
maxima, not sums, execution counts, or runtime costs. Inlined debug locations map
to the operation's lexical source, not the outer `inlinedAt` call site. Missing
debug locations, line zero, and locations outside the source set are counted in
the report. Zig sometimes emits synthesized functions with debug lines beyond
the end of their declared source file; these are listed under
`invalid_debug_locations` rather than guessing a line to annotate. Absence of a
diagnostic is not proof of complete optimization.

Locations are exactly those supplied by Zig. Aggregate initializers can assign
one debug location to several field operations. For example, a copy into
`buffer._shape` and a zero-fill of `buffer._shards` can both point to the `var
buffer` declaration. The report's instructions and their surrounding IR can
disambiguate pointer offsets; the annotator does not guess field-specific source
lines from the initializer syntax.

Preview changes, choose source directories, or remove annotations:

```sh
bazel run --config=release --strip=never //tools/llvm_inline_annotations:annotate_llm -- --check
bazel run --config=release --strip=never //tools/llvm_inline_annotations:annotate_llm -- --prefix zml --prefix stdx --prefix examples/llm
bazel run --config=release --strip=never //tools/llvm_inline_annotations:annotate_llm -- --remove
```

To use an existing report without rebuilding, including for removal:

```sh
python3 tools/llvm_inline_annotations/analyzer.py apply \
  --report bazel-bin/tools/llvm_inline_annotations/llm_report.json \
  --workspace "$PWD" --remove
```

For another Zig program, use `zig_ir_inspection` next to its `zig_binary`, then
feed its `<name>_llvm_ir` and `<name>_srcs` targets to the
`llvm_inline_annotations` rule. Adjust their visibility for a different consumer
package. The analyzer also accepts multiple `--ir` inputs and a JSON source
manifest mapping workspace-relative filenames to readable paths. It rejects
stripped or unoptimized IR.

Run tests with `bazel test //tools/llvm_inline_annotations:test`.
