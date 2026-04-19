const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The zunit module — this is what consumers import
    const zunit_mod = b.addModule("zunit", .{
        .root_source_file = b.path("src/zunit.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Internal tests for zunit itself
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zunit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run zunit's own tests");
    test_step.dependOn(&run_lib_tests.step);

    // -------------------------------------------------------------------------
    // Example: basic
    // Run with:  zig build example
    //            zig build example -- --output-file results.xml
    // -------------------------------------------------------------------------
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("zunit", zunit_mod);

    const example_tests = b.addTest(.{
        .root_module = example_mod,
        .test_runner = .{
            .path = b.path("examples/basic/test_runner.zig"),
            .mode = .simple,
        },
    });

    const run_example = b.addRunArtifact(example_tests);
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("example", "Run the basic example tests");
    example_step.dependOn(&run_example.step);

    // -------------------------------------------------------------------------
    // Example: suite (demonstrates multi-binary testSuite helper)
    // Run with:  zig build example-suite
    // Produces: zig-out/example-suite-results.xml (merged JUnit from 2 binaries)
    //
    // This uses the testSuite() helper defined below. In a real consumer project,
    // this would be:
    //   const zunit_build = @import("zunit");
    //   const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });
    //   const suite = zunit_build.testSuite(b, zunit_dep, .{ ... });
    // -------------------------------------------------------------------------
    const suite_runner_src =
        \\const std = @import("std");
        \\const zunit = @import("zunit");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const alloc = init.arena.allocator();
        \\    try zunit.run(init.io, .{
        \\        .output_file = try zunit.outputFileArg(alloc, init.minimal.args),
        \\        .output_dir = try zunit.outputDirArg(alloc, init.minimal.args),
        \\        .run_id = try zunit.runIdArg(alloc, init.minimal.args),
        \\        .consolidate_artifacts = try zunit.consolidateArtifactsArg(init.minimal.args),
        \\    });
        \\}
    ;
    const suite_wf = b.addWriteFiles();
    const suite_runner_path = suite_wf.add("zunit_test_runner.zig", suite_runner_src);

    // Clean stale fragments before each run
    const suite_clean = b.addSystemCommand(&.{ "sh", "-c", "rm -rf zig-out/example-suite-fragments || true" });

    const suite_output_file = "zig-out/example-suite-results.xml";
    const suite_output_dir = "zig-out/example-suite-fragments";
    const suite_run_id = suiteRunId(b);

    const suite_files = [_][]const u8{
        "examples/basic/src/math.zig",
        "examples/basic/src/strings.zig",
    };

    const example_suite_step = b.step("example-suite", "Run multi-binary suite example (produces merged XML)");

    for (suite_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("zunit", zunit_mod);

        const t = b.addTest(.{
            .root_module = mod,
            .test_runner = .{
                .path = suite_runner_path,
                .mode = .simple,
            },
        });

        const run_t = b.addRunArtifact(t);
        run_t.addArgs(&.{
            b.fmt("--output-file={s}", .{suite_output_file}),
            b.fmt("--output-dir={s}", .{suite_output_dir}),
            b.fmt("--run-id={s}", .{suite_run_id}),
            "--consolidate-artifacts=true",
        });
        if (b.args) |args| run_t.addArgs(args);
        run_t.step.dependOn(&suite_clean.step);
        example_suite_step.dependOn(&run_t.step);
    }
}

/// Derive a stable run ID for this build invocation using wall-clock seconds.
fn suiteRunId(b: *std.Build) []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const secs: u64 = @intCast(ts.sec);
    return b.fmt("run-{x}", .{secs});
}

// =============================================================================
// testSuite build helper — available to consumers via @import("zunit")
//
// Consumers add this to their build.zig:
//
//   const zunit_build = @import("zunit");
//   const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });
//   const suite = zunit_build.testSuite(b, zunit_dep, .{
//       .target = target,
//       .optimize = optimize,
//   });
//   suite.addFile("tests/foo_test.zig");
//   suite.addFile("tests/bar_test.zig");
//   const test_step = b.step("test", "Run all tests");
//   test_step.dependOn(suite.step());
// =============================================================================

pub const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub const TestSuiteOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Final merged JUnit XML output path, relative to the build root.
    output_file: []const u8 = "test-results.xml",
    /// Intermediate directory for per-binary fragments, relative to build root.
    output_dir: []const u8 = "zig-out/test-fragments",
    /// Shared imports applied to every test binary.
    imports: []const Import = &.{},
    /// When true, remove `output_dir` before running tests (prevents stale fragments).
    clean: bool = true,
    /// Forward `b.args` (from `-- …`) to each test binary so users can still pass flags.
    forward_args: bool = true,
};

pub const TestSuite = struct {
    b: *std.Build,
    opts: TestSuiteOptions,
    zunit_mod: *std.Build.Module,
    run_id: []const u8,
    runner_path: std.Build.LazyPath,
    cleanup_step: ?*std.Build.Step.Run,
    run_steps: std.ArrayList(*std.Build.Step.Run),

    pub fn addFile(self: *TestSuite, path: []const u8) void {
        const b = self.b;

        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = self.opts.target,
            .optimize = self.opts.optimize,
        });
        mod.addImport("zunit", self.zunit_mod);
        for (self.opts.imports) |imp| {
            mod.addImport(imp.name, imp.module);
        }

        const t = b.addTest(.{
            .root_module = mod,
            .test_runner = .{
                .path = self.runner_path,
                .mode = .simple,
            },
        });

        const run_t = b.addRunArtifact(t);

        run_t.addArgs(&.{
            b.fmt("--output-file={s}", .{self.opts.output_file}),
            b.fmt("--output-dir={s}", .{self.opts.output_dir}),
            b.fmt("--run-id={s}", .{self.run_id}),
            "--consolidate-artifacts=true",
        });

        if (self.opts.forward_args) {
            if (b.args) |args| run_t.addArgs(args);
        }

        if (self.cleanup_step) |cs| {
            run_t.step.dependOn(&cs.step);
        }

        self.run_steps.append(run_t) catch @panic("OOM");
    }

    pub fn addFiles(self: *TestSuite, paths: []const []const u8) void {
        for (paths) |p| self.addFile(p);
    }

    pub fn step(self: *TestSuite) *std.Build.Step {
        const b = self.b;
        const s = b.allocator.create(std.Build.Step) catch @panic("OOM");
        s.* = .init(.{
            .id = .custom,
            .name = "zunit-test-suite",
            .owner = b,
        });
        for (self.run_steps.items) |r| {
            s.dependOn(&r.step);
        }
        return s;
    }
};

/// Build helper that wires up a multi-binary test suite with fragment
/// consolidation. Each call to `addFile` registers one test binary; all
/// binaries write JUnit fragments to a shared directory and the last writer
/// merges them into `opts.output_file`.
pub fn testSuite(
    b: *std.Build,
    zunit_dep: *std.Build.Dependency,
    opts: TestSuiteOptions,
) *TestSuite {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const secs: u64 = @intCast(ts.sec);
    const run_id = b.fmt("run-{x}", .{secs});

    const runner_src =
        \\const std = @import("std");
        \\const zunit = @import("zunit");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const alloc = init.arena.allocator();
        \\    try zunit.run(init.io, .{
        \\        .output_file = try zunit.outputFileArg(alloc, init.minimal.args),
        \\        .output_dir = try zunit.outputDirArg(alloc, init.minimal.args),
        \\        .run_id = try zunit.runIdArg(alloc, init.minimal.args),
        \\        .consolidate_artifacts = try zunit.consolidateArtifactsArg(init.minimal.args),
        \\    });
        \\}
    ;
    const wf = b.addWriteFiles();
    const runner_path = wf.add("zunit_test_runner.zig", runner_src);

    const cleanup: ?*std.Build.Step.Run = if (opts.clean)
        b.addSystemCommand(&.{ "sh", "-c", b.fmt("rm -rf '{s}' || true", .{opts.output_dir}) })
    else
        null;

    const suite = b.allocator.create(TestSuite) catch @panic("OOM");
    suite.* = .{
        .b = b,
        .opts = opts,
        .zunit_mod = zunit_dep.module("zunit"),
        .run_id = run_id,
        .runner_path = runner_path,
        .cleanup_step = cleanup,
        .run_steps = std.ArrayList(*std.Build.Step.Run).init(b.allocator),
    };
    return suite;
}
