"""Optimized Zig IR extraction and source diagnostic reports."""

load("@rules_zig//zig:defs.bzl", "zig_binary", "zig_configure_binary")

_Sources = provider(fields = ["files"])

def _sources_aspect_impl(_target, ctx):
    direct = []
    transitive = []
    for name in ["srcs", "main"]:
        direct.extend(getattr(ctx.rule.files, name, []))
    for name in ["deps", "actual"]:
        deps = getattr(ctx.rule.attr, name, [])
        if type(deps) != "list":
            deps = [deps]
        transitive.extend([dep[_Sources].files for dep in deps if _Sources in dep])
    return [_Sources(files = depset(direct, transitive = transitive))]

_sources_aspect = aspect(
    implementation = _sources_aspect_impl,
    attr_aspects = ["deps", "actual"],
)

def _sources_impl(ctx):
    return [DefaultInfo(files = ctx.attr.target[_Sources].files)]

_source_files = rule(
    implementation = _sources_impl,
    attrs = {"target": attr.label(aspects = [_sources_aspect])},
)

def zig_ir_inspection(name, srcs, main, deps):
    """Build the same Zig program with LLVM optimization and debug locations."""
    zig_binary(
        name = name + "_bin",
        srcs = srcs,
        main = main,
        deps = deps,
        emit_llvm_ir = True,
        zigopts = ["-OReleaseSafe", "-fllvm", "-fno-strip"],
        tags = ["manual"],
        visibility = ["//tools/llvm_inline_annotations:__pkg__"],
    )
    zig_configure_binary(
        name = name,
        actual = ":" + name + "_bin",
        mode = "release_safe",
        tags = ["manual"],
        visibility = ["//tools/llvm_inline_annotations:__pkg__"],
    )
    native.filegroup(
        name = name + "_llvm_ir",
        srcs = [":" + name],
        output_group = "llvm_ir",
        tags = ["manual"],
        visibility = ["//tools/llvm_inline_annotations:__pkg__"],
    )
    _source_files(
        name = name + "_srcs",
        target = ":" + name,
        tags = ["manual"],
        visibility = ["//tools/llvm_inline_annotations:__pkg__"],
    )

def _annotations_impl(ctx):
    report = ctx.actions.declare_file(ctx.label.name + ".json")
    manifest = ctx.actions.declare_file(ctx.label.name + ".sources.json")
    sources = [f for f in ctx.files.srcs if f.is_source and f.extension == "zig" and not f.short_path.startswith("../")]
    if not sources:
        fail("No workspace Zig sources supplied")
    if not ctx.files.ir:
        fail("No LLVM IR supplied; enable emit_llvm_ir on the Zig target")
    ctx.actions.write(manifest, json.encode({f.short_path: f.path for f in sources}))
    args = ctx.actions.args()
    args.add("analyze")
    args.add("--manifest", manifest)
    args.add("--output", report)
    args.add_all(ctx.files.ir, before_each = "--ir")
    ctx.actions.run(
        executable = ctx.executable._analyzer,
        arguments = [args],
        inputs = depset(ctx.files.ir + sources + [manifest]),
        outputs = [report],
        mnemonic = "LlvmInlineAnnotations",
        progress_message = "Inspecting optimized LLVM IR for %{label}",
    )
    return [DefaultInfo(files = depset([report]))]

llvm_inline_annotations = rule(
    implementation = _annotations_impl,
    attrs = {
        "ir": attr.label_list(allow_files = [".ll"], mandatory = True),
        "srcs": attr.label_list(allow_files = [".zig"], mandatory = True),
        "_analyzer": attr.label(default = ":analyzer", executable = True, cfg = "exec"),
    },
    doc = "Produce a deterministic diagnostic report from optimized LLVM IR and its source inputs.",
)
