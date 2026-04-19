//! test_runner.zig — zunit's default test runner entry point.
//!
//! Drop this file into your project root and point `build.zig` at it as
//! `test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple }`.
//! zunit handles everything else. This is the same runner zunit uses to
//! run its own internal tests.
const std = @import("std");
const zunit = @import("zunit");

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        // Output style: .minimal | .verbose | .verbose_timing
        .output = .verbose_timing,

        // What to do if a global hook errors
        .on_global_hook_failure = .abort,

        // What to do if a per-file hook errors
        .on_file_hook_failure = .skip_remaining,

        // Optional output file — pass `--output-file results.xml` (or
        // `.txt` for plain text) via `zig build test -- …` to populate.
        .output_file = try zunit.outputFileArg(
            init.arena.allocator(),
            init.minimal.args,
        ),

        // Multi-binary consolidation flags (see README → "Examples" → 14).
        .output_dir = try zunit.outputDirArg(
            init.arena.allocator(),
            init.minimal.args,
        ),
        .run_id = try zunit.runIdArg(
            init.arena.allocator(),
            init.minimal.args,
        ),
        .consolidate_artifacts = try zunit.consolidateArtifactsArg(init.minimal.args),
    });
}
