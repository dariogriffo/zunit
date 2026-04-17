/// runner.zig - Core zunit test runner logic.
const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("hooks.zig");

/// What to do when a lifecycle hook returns an error.
pub const OnHookFailure = enum {
    /// Abort the entire test suite immediately.
    abort,
    /// Skip all remaining tests in the same file (per-file hooks) or all tests (global hooks).
    skip_remaining,
    /// Log the error and continue running tests.
    @"continue",
};

/// Output verbosity level.
pub const OutputStyle = enum {
    /// Only print a final summary with pass/fail/skip counts.
    minimal,
    /// Print each test name and its result.
    verbose,
    /// Print each test name, result, and elapsed time.
    verbose_timing,
};

/// Configuration passed to `zunit.run(...)`.
pub const Config = struct {
    /// What to do when a global hook fails.
    on_global_hook_failure: OnHookFailure = .abort,

    /// What to do when a per-file hook fails.
    on_file_hook_failure: OnHookFailure = .skip_remaining,

    /// Output verbosity.
    output: OutputStyle = .verbose,

    /// Optional programmatic global hooks (run in addition to / override naming convention).
    /// These run before any naming-convention global hooks.
    before_all: ?*const fn () anyerror!void = null,
    after_all: ?*const fn () anyerror!void = null,
    before_each: ?*const fn () anyerror!void = null,
    after_each: ?*const fn () anyerror!void = null,

    /// If set, write test results to this file after the suite completes.
    /// When the path ends with ".xml" a JUnit-compatible XML report is generated;
    /// otherwise the output mirrors the console format.
    output_file: ?[]const u8 = null,
};

const TestResult = enum { pass, fail, skip };

const RunStats = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    fn total(self: RunStats) u32 {
        return self.passed + self.failed + self.skipped;
    }
};

/// One recorded test outcome — collected for file output.
const TestRecord = struct {
    full_name: []const u8,
    result: TestResult,
    elapsed_ns: u64,
    /// The Zig error name when the test failed (e.g. "TestExpectedEqual"). Empty otherwise.
    error_name: []const u8 = "",
};

/// Run the full test suite with the given config.
/// Call this from your test_runner.zig's `pub fn main()`.
pub fn run(config: Config) !void {
    const all_tests = builtin.test_functions;
    var stats = RunStats{};
    const gpa = std.heap.page_allocator;

    var records: std.ArrayList(TestRecord) = .empty;
    defer records.deinit(gpa);

    // -------------------------------------------------------------------------
    // 1. Run global beforeAll hooks (config-provided first, then named)
    // -------------------------------------------------------------------------
    if (config.before_all) |f| {
        f() catch |err| {
            printHookError("global beforeAll (config)", err);
            if (config.on_global_hook_failure == .abort) {
                printSummary(stats, config.output);
                std.process.exit(1);
            }
        };
    }

    const global_before_all_result = runNamedHooks(all_tests, .global_before_all);
    if (global_before_all_result) |_| {} else |err| {
        printHookError("zunit:beforeAll", err);
        if (config.on_global_hook_failure == .abort) {
            printSummary(stats, config.output);
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------------------
    // 2. Gather unique file paths so we can scope per-file hooks
    // -------------------------------------------------------------------------
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(gpa);

    for (all_tests) |t| {
        if (hooks.isHook(t.name)) continue;
        const fp = hooks.extractFilePath(t.name);
        if (fp.len == 0) continue;
        var found = false;
        for (file_paths.items) |existing| {
            if (std.mem.eql(u8, existing, fp)) {
                found = true;
                break;
            }
        }
        if (!found) try file_paths.append(gpa, fp);
    }

    // -------------------------------------------------------------------------
    // 3. Run tests file by file
    // -------------------------------------------------------------------------
    for (file_paths.items) |file_path| {
        var file_skip = false;

        // Per-file beforeAll
        const fb_result = runNamedHooksForFile(all_tests, .file_before_all, file_path);
        if (fb_result) |_| {} else |err| {
            printHookError("beforeAll", err);
            switch (config.on_file_hook_failure) {
                .abort => {
                    printSummary(stats, config.output);
                    std.process.exit(1);
                },
                .skip_remaining => {
                    file_skip = true;
                },
                .@"continue" => {},
            }
        }

        // Run each test in this file
        for (all_tests) |t| {
            if (hooks.isHook(t.name)) continue;
            const fp = hooks.extractFilePath(t.name);
            if (!std.mem.eql(u8, fp, file_path)) continue;

            if (file_skip) {
                stats.skipped += 1;
                try records.append(gpa, .{ .full_name = t.name, .result = .skip, .elapsed_ns = 0 });
                if (config.output != .minimal) {
                    printResult(t.name, .skip, 0, config.output);
                }
                continue;
            }

            // global beforeEach (config)
            if (config.before_each) |f| {
                f() catch |err| {
                    printHookError("global beforeEach (config)", err);
                    if (config.on_global_hook_failure == .abort) {
                        printSummary(stats, config.output);
                        std.process.exit(1);
                    }
                };
            }
            // global beforeEach (named)
            _ = runNamedHooks(all_tests, .global_before_each) catch |err| {
                printHookError("zunit:beforeEach", err);
            };
            // per-file beforeEach
            _ = runNamedHooksForFile(all_tests, .file_before_each, file_path) catch |err| {
                printHookError("beforeEach", err);
            };

            // Run the actual test
            std.testing.allocator_instance = .{};
            var timer: ?std.time.Timer = std.time.Timer.start() catch null;
            const result = t.func();
            const elapsed: u64 = if (timer) |*tmr| tmr.read() else 0;
            const leaked = std.testing.allocator_instance.deinit() == .leak;

            if (result) |_| {
                if (leaked) {
                    stats.failed += 1;
                    try records.append(gpa, .{ .full_name = t.name, .result = .fail, .elapsed_ns = elapsed, .error_name = "MemoryLeak" });
                    if (config.output != .minimal) {
                        std.debug.print("  LEAK  {s}\n", .{hooks.extractTestName(t.name)});
                    }
                } else {
                    stats.passed += 1;
                    try records.append(gpa, .{ .full_name = t.name, .result = .pass, .elapsed_ns = elapsed });
                    if (config.output != .minimal) {
                        printResult(t.name, .pass, elapsed, config.output);
                    }
                }
            } else |err| {
                stats.failed += 1;
                try records.append(gpa, .{ .full_name = t.name, .result = .fail, .elapsed_ns = elapsed, .error_name = @errorName(err) });
                if (config.output != .minimal) {
                    printResult(t.name, .fail, elapsed, config.output);
                }
            }

            // per-file afterEach
            _ = runNamedHooksForFile(all_tests, .file_after_each, file_path) catch |err| {
                printHookError("afterEach", err);
            };
            // global afterEach (named)
            _ = runNamedHooks(all_tests, .global_after_each) catch |err| {
                printHookError("zunit:afterEach", err);
            };
            // global afterEach (config)
            if (config.after_each) |f| {
                f() catch |err| {
                    printHookError("global afterEach (config)", err);
                };
            }
        }

        // Per-file afterAll
        _ = runNamedHooksForFile(all_tests, .file_after_all, file_path) catch |err| {
            printHookError("afterAll", err);
            switch (config.on_file_hook_failure) {
                .abort => {
                    printSummary(stats, config.output);
                    std.process.exit(1);
                },
                else => {},
            }
        };
    }

    // Handle any tests with no file path (e.g. anonymous tests or root-level)
    for (all_tests) |t| {
        if (hooks.isHook(t.name)) continue;
        const fp = hooks.extractFilePath(t.name);
        if (fp.len != 0) continue;

        std.testing.allocator_instance = .{};
        const start: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp())));
        const result = t.func();
        const elapsed: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp()))) - start;
        const leaked = std.testing.allocator_instance.deinit() == .leak;

        if (result) |_| {
            if (leaked) {
                stats.failed += 1;
                try records.append(gpa, .{ .full_name = t.name, .result = .fail, .elapsed_ns = elapsed, .error_name = "MemoryLeak" });
            } else {
                stats.passed += 1;
                try records.append(gpa, .{ .full_name = t.name, .result = .pass, .elapsed_ns = elapsed });
                if (config.output != .minimal) {
                    printResult(t.name, .pass, elapsed, config.output);
                }
            }
        } else |err| {
            stats.failed += 1;
            try records.append(gpa, .{ .full_name = t.name, .result = .fail, .elapsed_ns = elapsed, .error_name = @errorName(err) });
            if (config.output != .minimal) {
                printResult(t.name, .fail, elapsed, config.output);
            }
        }
    }

    // -------------------------------------------------------------------------
    // 4. Run global afterAll hooks
    // -------------------------------------------------------------------------
    _ = runNamedHooks(all_tests, .global_after_all) catch |err| {
        printHookError("zunit:afterAll", err);
    };
    if (config.after_all) |f| {
        f() catch |err| {
            printHookError("global afterAll (config)", err);
        };
    }

    // -------------------------------------------------------------------------
    // 5. Print summary and write output file
    // -------------------------------------------------------------------------
    printSummary(stats, config.output);

    if (config.output_file) |path| {
        writeOutputFile(path, records.items, stats, config.output) catch |err| {
            std.debug.print("  WARNING: failed to write output file '{s}': {}\n", .{ path, err });
        };
    }

    if (stats.failed > 0) {
        std.process.exit(1);
    }
}

// -----------------------------------------------------------------------------
// CLI helpers
// -----------------------------------------------------------------------------

/// Returns the value of `--output-file <path>` (or `--output-file=<path>`) from
/// the given argv, or null if the flag is absent.
///
/// In Zig 0.16, command-line arguments travel through `std.process.Init`
/// (or the smaller `std.process.Init.Minimal`) passed to `main` — they are
/// no longer accessible via a global like `std.process.argsAlloc`. Pass the
/// `args` field straight through.
///
/// Typical usage in test_runner.zig:
///
///   pub fn main(init: std.process.Init.Minimal) !void {
///       try zunit.run(.{
///           .output_file = try zunit.outputFileArg(std.heap.page_allocator, init.args),
///       });
///   }
///
/// Then run with:  zig build test -- --output-file results.xml
pub fn outputFileArg(
    allocator: std.mem.Allocator,
    args: std.process.Args,
) !?[]const u8 {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();

    _ = it.next(); // skip argv[0]
    while (it.next()) |arg| {
        // --output-file=path
        if (std.mem.startsWith(u8, arg, "--output-file=")) {
            return try allocator.dupe(u8, arg["--output-file=".len..]);
        }
        // --output-file path
        if (std.mem.eql(u8, arg, "--output-file")) {
            if (it.next()) |val| {
                return try allocator.dupe(u8, val);
            }
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------------

fn runNamedHooks(
    all_tests: []const std.builtin.TestFn,
    kind: hooks.HookKind,
) anyerror!void {
    for (all_tests) |t| {
        if (hooks.classify(t.name) == kind) {
            try t.func();
        }
    }
}

fn runNamedHooksForFile(
    all_tests: []const std.builtin.TestFn,
    kind: hooks.HookKind,
    file_path: []const u8,
) anyerror!void {
    for (all_tests) |t| {
        if (hooks.classify(t.name) != kind) continue;
        if (!std.mem.eql(u8, hooks.extractFilePath(t.name), file_path)) continue;
        try t.func();
    }
}

fn printResult(full_name: []const u8, result: TestResult, elapsed_ns: u64, style: OutputStyle) void {
    const name = hooks.extractTestName(full_name);
    var buf: [32]u8 = undefined;
    switch (result) {
        .pass => switch (style) {
            .verbose_timing => std.debug.print("  PASS  {s}  {s}\n", .{ name, fmtNs(elapsed_ns, &buf) }),
            else => std.debug.print("  PASS  {s}\n", .{name}),
        },
        .fail => switch (style) {
            .verbose_timing => std.debug.print("  FAIL  {s}  {s}\n", .{ name, fmtNs(elapsed_ns, &buf) }),
            else => std.debug.print("  FAIL  {s}\n", .{name}),
        },
        .skip => std.debug.print("  SKIP  {s}\n", .{name}),
    }
}

fn printHookError(hook_name: []const u8, err: anyerror) void {
    std.debug.print("  HOOK ERROR [{s}]: {}\n", .{ hook_name, err });
}

fn printSummary(stats: RunStats, style: OutputStyle) void {
    _ = style;
    std.debug.print("\n  {d} passed  {d} failed  {d} skipped\n", .{
        stats.passed, stats.failed, stats.skipped,
    });
}

// -----------------------------------------------------------------------------
// File output
// -----------------------------------------------------------------------------

fn writeOutputFile(
    path: []const u8,
    records: []const TestRecord,
    stats: RunStats,
    style: OutputStyle,
) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var w = file.writerStreaming(&buf);
    defer w.end() catch {};

    if (std.mem.endsWith(u8, path, ".xml")) {
        try writeJUnitXml(&w.interface, records, stats);
    } else {
        try writePlainText(&w.interface, records, stats, style);
    }
}

fn writePlainText(
    w: *std.Io.Writer,
    records: []const TestRecord,
    stats: RunStats,
    style: OutputStyle,
) !void {
    for (records) |rec| {
        const name = hooks.extractTestName(rec.full_name);
        switch (rec.result) {
            .pass => switch (style) {
                .verbose_timing => {
                    var buf: [32]u8 = undefined;
                    try w.print("  PASS  {s}  {s}\n", .{ name, fmtNs(rec.elapsed_ns, &buf) });
                },
                .verbose => try w.print("  PASS  {s}\n", .{name}),
                .minimal => {},
            },
            .fail => switch (style) {
                .verbose_timing => {
                    var buf: [32]u8 = undefined;
                    try w.print("  FAIL  {s}  {s}\n", .{ name, fmtNs(rec.elapsed_ns, &buf) });
                },
                .verbose => try w.print("  FAIL  {s}\n", .{name}),
                .minimal => {},
            },
            .skip => switch (style) {
                .minimal => {},
                else => try w.print("  SKIP  {s}\n", .{name}),
            },
        }
    }
    try w.print("\n  {d} passed  {d} failed  {d} skipped\n", .{
        stats.passed, stats.failed, stats.skipped,
    });
}

fn writeJUnitXml(w: *std.Io.Writer, records: []const TestRecord, stats: RunStats) !void {
    var total_ns: u64 = 0;
    for (records) |rec| total_ns += rec.elapsed_ns;

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print(
        "<testsuites name=\"zunit\" tests=\"{d}\" failures=\"{d}\" errors=\"0\" skipped=\"{d}\" time=\"{d}.{d:0>9}\">\n",
        .{ stats.total(), stats.failed, stats.skipped, total_ns / 1_000_000_000, total_ns % 1_000_000_000 },
    );

    // Collect unique file paths (preserving order)
    const gpa = std.heap.page_allocator;
    var fps: std.ArrayList([]const u8) = .empty;
    defer fps.deinit(gpa);
    for (records) |rec| {
        const fp = hooks.extractFilePath(rec.full_name);
        var found = false;
        for (fps.items) |existing| {
            if (std.mem.eql(u8, existing, fp)) {
                found = true;
                break;
            }
        }
        if (!found) try fps.append(gpa, fp);
    }

    for (fps.items) |fp| {
        var suite_tests: u32 = 0;
        var suite_failures: u32 = 0;
        var suite_skipped: u32 = 0;
        var suite_ns: u64 = 0;
        for (records) |rec| {
            if (!std.mem.eql(u8, hooks.extractFilePath(rec.full_name), fp)) continue;
            suite_tests += 1;
            suite_ns += rec.elapsed_ns;
            switch (rec.result) {
                .fail => suite_failures += 1,
                .skip => suite_skipped += 1,
                .pass => {},
            }
        }

        const suite_name = if (fp.len > 0) fp else "root";
        try w.writeAll("  <testsuite name=\"");
        try writeXmlEscaped(w, suite_name);
        try w.print(
            "\" tests=\"{d}\" failures=\"{d}\" errors=\"0\" skipped=\"{d}\" time=\"{d}.{d:0>9}\">\n",
            .{ suite_tests, suite_failures, suite_skipped, suite_ns / 1_000_000_000, suite_ns % 1_000_000_000 },
        );

        for (records) |rec| {
            if (!std.mem.eql(u8, hooks.extractFilePath(rec.full_name), fp)) continue;
            const name = hooks.extractTestName(rec.full_name);
            try w.writeAll("    <testcase name=\"");
            try writeXmlEscaped(w, name);
            try w.writeAll("\" classname=\"");
            try writeXmlEscaped(w, suite_name);
            try w.print("\" time=\"{d}.{d:0>9}\"", .{
                rec.elapsed_ns / 1_000_000_000,
                rec.elapsed_ns % 1_000_000_000,
            });
            switch (rec.result) {
                .pass => try w.writeAll("/>\n"),
                .skip => try w.writeAll(">\n      <skipped/>\n    </testcase>\n"),
                .fail => {
                    try w.writeAll(">\n      <failure message=\"");
                    try writeXmlEscaped(w, if (rec.error_name.len > 0) rec.error_name else "test failed");
                    try w.writeAll("\" type=\"failure\"/>\n    </testcase>\n");
                },
            }
        }

        try w.writeAll("  </testsuite>\n");
    }

    try w.writeAll("</testsuites>\n");
}

/// Formats a nanosecond duration into `buf` and returns the written slice.
///   < 1µs  → "123ns"
///   < 1ms  → "12.3µs"
///   ≥ 1ms  → "1.234ms"
fn fmtNs(ns: u64, buf: *[32]u8) []const u8 {
    if (ns < 1_000) {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch buf[0..0];
    } else if (ns < 1_000_000) {
        const us = ns / 1_000;
        const tenth = (ns % 1_000) / 100;
        return std.fmt.bufPrint(buf, "{d}.{d}µs", .{ us, tenth }) catch buf[0..0];
    } else {
        const ms = ns / 1_000_000;
        const us = (ns % 1_000_000) / 1_000;
        return std.fmt.bufPrint(buf, "{d}.{d:0>3}ms", .{ ms, us }) catch buf[0..0];
    }
}

fn writeXmlEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}
