const std = @import("std");

/// Emit optimized LLVM IR for `exe`, then return a cached JSON analysis file.
/// Pass this package's builder (dependency.builder for a dependency) as `b`.
/// The analyzer always runs on the build host, including for cross-compiled exes.
/// This opts the executable and its imported modules into LLVM, ReleaseSafe
/// (when Debug), and debug information. Configure before scheduling the build.
/// Only the emitted LLVM IR is an input to analysis.
pub fn addAnalysis(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    std.debug.assert(exe.kind == .exe);
    exe.use_llvm = true;
    for (exe.root_module.getGraph().modules) |mod| {
        if (mod.optimize == null or mod.optimize == .debug) mod.optimize = .safe;
        mod.strip = false;
    }
    const tool = analyzer(b, b.graph.host, .safe);
    const run = b.addRunArtifact(tool);
    run.addArgs(&.{ "analyze", "--ir" });
    run.addFileArg2(exe.getEmittedLlvmIr(), .{ .make_absolute = true });
    run.addArg("--output");
    return run.addOutputFileArg("analysis.json");
}
/// Analyze `exe`, then annotate files inside `workspace` in place.
/// Pass null to use the executable's build root. Attach the returned run step
/// to an explicit build step; it always runs because it modifies source files.
/// The run step accepts additional CLI flags such as --check or --remove.
pub fn addAnnotations(b: *std.Build, report: std.Build.LazyPath, workspace: ?std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addRunArtifact(analyzer(b, b.graph.host, .safe));
    run.addArgs(&.{ "apply", "--report" });
    run.addFileArg(report);
    if (workspace) |wk| {
        run.addArg("--workspace");
        run.addDirectoryArg2(wk, .{ .make_absolute = true });
    }
    run.has_side_effects = true;
    return run;
}

fn analyzer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "llvm-inline-annotations",
        .root_module = b.createModule(.{ .root_source_file = b.path("analyzer.zig"), .target = target, .optimize = optimize }),
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = analyzer(b, target, optimize);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the analyzer CLI").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("analyzer.zig"), .target = b.graph.host, .optimize = optimize }) });
    b.step("test", "Run analyzer tests").dependOn(&b.addRunArtifact(tests).step);

    {
        const report = addAnalysis(b, exe);
        const install_report = b.addInstallFile(report, "analysis.json");
        b.step("self-report", "Generates self report").dependOn(&install_report.step);

        const annotate = addAnnotations(b, report, exe.step.owner.path("."));
        b.step("self-annotate", "Annotate our codebase").dependOn(&annotate.step);
    }

    {
        const example = b.addExecutable(.{
            .name = "analysis-example",
            .root_module = b.createModule(.{ .root_source_file = b.path("test/example.zig"), .target = target, .optimize = .debug }),
        });
        const report = addAnalysis(b, example);
        const install_report = b.addInstallFile(report, "analysis.json");
        b.step("example-report", "Generates an example report").dependOn(&install_report.step);
    }
}
