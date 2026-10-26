const std = @import("std");

pub const Source = struct {
    /// Workspace-relative name used in debug locations and report keys.
    name: []const u8,
    path: std.Build.LazyPath,
};
pub const AnalysisOptions = struct {
    sources: []const Source,
    output_name: []const u8 = "analysis.json",
};

/// Emit optimized LLVM IR for `exe`, then return a cached JSON analysis file.
/// Pass this package's builder (dependency.builder for a dependency) as `b`.
/// The analyzer always runs on the build host, including for cross-compiled exes.
/// This opts the executable and its imported modules into LLVM, ReleaseSafe
/// (when Debug), and debug information. Configure before scheduling the build.
/// Sources are explicit so reports exclude external/generated code by default.
pub fn addAnalysis(b: *std.Build, exe: *std.Build.Step.Compile, options: AnalysisOptions) std.Build.LazyPath {
    std.debug.assert(exe.kind == .exe);
    std.debug.assert(options.sources.len > 0);
    exe.use_llvm = true;
    for (exe.root_module.getGraph().modules) |mod| {
        if (mod.optimize == null or mod.optimize == .debug) mod.optimize = .safe;
        mod.strip = false;
    }
    const tool = analyzer(b, b.graph.host, .safe);
    const run = b.addRunArtifact(tool);
    run.addArgs(&.{ "analyze", "--ir" });
    run.addFileArg(exe.getEmittedLlvmIr());
    // Pass each source as a name/path pair, keeping LazyPath dependencies and
    // cache invalidation attached to the run step without configure-time I/O.
    for (options.sources) |source| {
        run.addArgs(&.{ "--source", source.name });
        run.addFileArg(source.path);
    }
    run.addArg("--output");
    return run.addOutputFileArg(options.output_name);
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
    const example = b.addExecutable(.{
        .name = "analysis-example",
        .root_module = b.createModule(.{ .root_source_file = b.path("test/example.zig"), .target = target, .optimize = .debug }),
    });
    const report = addAnalysis(b, example, .{ .sources = &.{.{ .name = "test/example.zig", .path = b.path("test/example.zig") }} });
    const install_report = b.addInstallFile(report, "analysis.json");
    b.step("example-report", "Generate an example report using addAnalysis").dependOn(&install_report.step);
    const parity = b.addSystemCommand(&.{"python3"});
    parity.addFileArg(b.path("zig_integration_test.py"));
    parity.addArtifactArg(analyzer(b, b.graph.host, .safe));
    parity.addFileInput(b.path("analyzer.py"));
    parity.addFileInput(b.path("analyzer_test.py"));
    b.step("test-integration", "Compare the Zig CLI with the Python reference (requires Python 3)").dependOn(&parity.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("analyzer.zig"), .target = b.graph.host, .optimize = optimize }) });
    b.step("test", "Run analyzer tests").dependOn(&b.addRunArtifact(tests).step);
}
