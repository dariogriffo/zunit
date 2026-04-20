const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The zunit module — this is what consumers import
    const zunit_mod = b.addModule("zunit", .{
        .root_source_file = b.path("src/zunit.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Internal tests for zunit itself — dogfooded by running under zunit's
    // own runner (src/test_runner.zig) so `zig build test` shows verbose
    // PASS/FAIL output. Reuses zunit_mod as the test root so runner.zig and
    // merge.zig (pulled in transitively) aren't duplicated across modules,
    // and self-imports "zunit" so the runner's @import("zunit") resolves.
    zunit_mod.addImport("zunit", zunit_mod);

    const lib_tests = b.addTest(.{
        .root_module = zunit_mod,
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    if (b.args) |args| run_lib_tests.addArgs(args);
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
    // Produces: zig-out/example-suite/test-results.xml (merged JUnit from 2 binaries)
    //
    // `output_file` defaults to "test-results.xml" when consolidating and a
    // relative `output_file` is resolved under `output_dir`, so the merged XML
    // lands at `zig-out/example-suite/test-results.xml` without any explicit
    // path. This is the intended idiomatic usage.
    //
    // Dogfoods the testSuite helper via `testSuiteFromModule` (module-based
    // variant). In a real consumer project you'd use `testSuite` instead:
    //
    //   const zunit_build = @import("zunit");
    //   const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });
    //   const suite = zunit_build.testSuite(b, zunit_dep, .{ ... });
    // -------------------------------------------------------------------------
    const example_suite = testSuiteFromModule(b, zunit_mod, .{
        .target = target,
        .optimize = optimize,
        .output_dir = "zig-out/example-suite",
    });
    example_suite.addFile("examples/basic/src/math.zig");
    example_suite.addFile("examples/basic/src/strings.zig");

    const example_suite_step = b.step("example-suite", "Run multi-binary suite example (produces merged XML)");
    example_suite_step.dependOn(example_suite.step());
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
    /// Final merged JUnit XML output path. If relative, it is resolved under
    /// `output_dir` at runtime (so the default `"test-results.xml"` lands at
    /// `<output_dir>/test-results.xml`). Pass an absolute path to write
    /// elsewhere.
    output_file: []const u8 = "test-results.xml",
    /// Intermediate directory for per-binary fragments, relative to build
    /// root. Fragments live in `<output_dir>/<run_id>/*.xml` and the merged
    /// XML lands at `<output_dir>/<output_file>` (when `output_file` is
    /// relative).
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
    cleanup_step: ?*std.Build.Step,
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
            run_t.step.dependOn(cs);
        }

        self.run_steps.append(self.b.allocator, run_t) catch @panic("OOM");
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
    return testSuiteFromModule(b, zunit_dep.module("zunit"), opts);
}

/// Like `testSuite`, but takes the zunit module directly. Useful for zunit's
/// own build.zig (which dogfoods the helper without depending on itself) and
/// for any consumer that already has a `*std.Build.Module` in hand.
pub fn testSuiteFromModule(
    b: *std.Build,
    zunit_mod: *std.Build.Module,
    opts: TestSuiteOptions,
) *TestSuite {
    const run_id = b.fmt("run-{x}", .{b.graph.random_seed});

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

    const cleanup: ?*std.Build.Step = if (opts.clean) blk: {
        const run = if (builtin.os.tag == .windows)
            b.addSystemCommand(&.{ "cmd", "/c", b.fmt("if exist \"{s}\" rmdir /s /q \"{s}\"", .{ opts.output_dir, opts.output_dir }) })
        else
            b.addSystemCommand(&.{ "rm", "-rf", opts.output_dir });
        break :blk &run.step;
    } else null;

    const suite = b.allocator.create(TestSuite) catch @panic("OOM");
    suite.* = .{
        .b = b,
        .opts = opts,
        .zunit_mod = zunit_mod,
        .run_id = run_id,
        .runner_path = runner_path,
        .cleanup_step = cleanup,
        .run_steps = .empty,
    };
    return suite;
}
