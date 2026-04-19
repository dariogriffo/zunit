/// merge.zig - JUnit XML fragment merging for zunit v2.1.
///
/// This module handles the "opaque inner XML" strategy: each fragment produced
/// by zunit's own runner contains well-formed `<testsuite …>…</testsuite>`
/// elements. We scan for those elements, extract their attribute totals for
/// recomputation, and paste the verbatim inner XML into a unified
/// `<testsuites>` wrapper.
///
/// No full XML parser is needed — zunit controls the output format.
const std = @import("std");

pub const MergeError = error{OutOfMemory};

/// Aggregated totals from all parsed testsuites.
pub const Totals = struct {
    tests: u64 = 0,
    failures: u64 = 0,
    errors: u64 = 0,
    skipped: u64 = 0,
    /// Sum of time attributes in seconds (stored as fractional * 1e9 for precision).
    time_ns: u64 = 0,
};

/// A single parsed testsuite block: the verbatim `<testsuite …>…</testsuite>`
/// substring plus its extracted attribute totals.
pub const Suite = struct {
    /// Verbatim XML substring (points into the original fragment slice).
    verbatim: []const u8,
    tests: u64,
    failures: u64,
    errors: u64,
    skipped: u64,
    time_ns: u64,
};

/// Parse all `<testsuite …>…</testsuite>` blocks from a single JUnit XML
/// fragment produced by zunit. Returns a slice owned by `alloc`.
///
/// Corrupt or unparseable attributes are treated as 0 (with a soft skip).
pub fn parseSuites(alloc: std.mem.Allocator, fragment: []const u8) ![]Suite {
    var suites: std.ArrayList(Suite) = .empty;
    defer suites.deinit(alloc);

    var pos: usize = 0;
    while (true) {
        // Find next <testsuite (must be followed by a space or newline to avoid matching <testsuites>)
        const open_start = blk: {
            var search_pos = pos;
            while (true) {
                const found = std.mem.indexOfPos(u8, fragment, search_pos, "<testsuite") orelse break :blk null;
                // Make sure it's not <testsuites (check the char after "testsuite")
                const after = found + "<testsuite".len;
                if (after >= fragment.len) break :blk null;
                const next_ch = fragment[after];
                if (next_ch == ' ' or next_ch == '\t' or next_ch == '\n' or next_ch == '\r') {
                    break :blk found;
                }
                search_pos = found + 1;
            }
            break :blk null;
        } orelse break;

        // Find closing > of the opening tag
        const open_end = std.mem.indexOfPos(u8, fragment, open_start, ">") orelse break;

        // Find </testsuite>
        const close_tag = "</testsuite>";
        const close_start = std.mem.indexOfPos(u8, fragment, open_end, close_tag) orelse break;
        const close_end = close_start + close_tag.len;

        const verbatim = fragment[open_start..close_end];
        const open_tag = fragment[open_start .. open_end + 1];

        const suite = Suite{
            .verbatim = verbatim,
            .tests = parseAttrU64(open_tag, "tests") orelse 0,
            .failures = parseAttrU64(open_tag, "failures") orelse 0,
            .errors = parseAttrU64(open_tag, "errors") orelse 0,
            .skipped = parseAttrU64(open_tag, "skipped") orelse 0,
            .time_ns = parseAttrTimeNs(open_tag, "time") orelse 0,
        };
        try suites.append(alloc, suite);
        pos = close_end;
    }

    return suites.toOwnedSlice(alloc);
}

/// Write the merged `<testsuites>…</testsuites>` document to `w`.
/// `fragments` is a slice of JUnit XML document strings (as produced by
/// `writeJUnitXml`). Each is parsed for its `<testsuite>` children; the
/// verbatim children are concatenated and totals are summed.
pub fn writesMergedXml(w: *std.Io.Writer, fragments: []const []const u8) !void {
    const alloc = std.heap.page_allocator;

    var totals = Totals{};
    var all_suites: std.ArrayList(Suite) = .empty;
    defer all_suites.deinit(alloc);

    for (fragments) |frag| {
        const suites = parseSuites(alloc, frag) catch continue; // skip corrupt fragments
        defer alloc.free(suites);
        for (suites) |s| {
            totals.tests += s.tests;
            totals.failures += s.failures;
            totals.errors += s.errors;
            totals.skipped += s.skipped;
            totals.time_ns += s.time_ns;
            try all_suites.append(alloc, s);
        }
    }

    const time_s = totals.time_ns / 1_000_000_000;
    const time_frac = totals.time_ns % 1_000_000_000;

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print(
        "<testsuites name=\"zunit\" tests=\"{d}\" failures=\"{d}\" errors=\"{d}\" skipped=\"{d}\" time=\"{d}.{d:0>9}\">\n",
        .{ totals.tests, totals.failures, totals.errors, totals.skipped, time_s, time_frac },
    );

    for (all_suites.items) |s| {
        try w.writeAll("  ");
        try w.writeAll(s.verbatim);
        try w.writeAll("\n");
    }

    try w.writeAll("</testsuites>\n");
}

// -----------------------------------------------------------------------------
// Attribute parsing helpers
// -----------------------------------------------------------------------------

/// Extract `attr="<value>"` from an XML open tag and parse it as u64.
/// Returns null if the attribute is absent or the value is not a valid integer.
pub fn parseAttrU64(tag: []const u8, attr: []const u8) ?u64 {
    const value_str = extractAttrValue(tag, attr) orelse return null;
    return std.fmt.parseInt(u64, value_str, 10) catch null;
}

/// Extract the `time` attribute (format: "seconds.fraction") and convert to nanoseconds.
pub fn parseAttrTimeNs(tag: []const u8, attr: []const u8) ?u64 {
    const value_str = extractAttrValue(tag, attr) orelse return null;
    if (std.mem.indexOfScalar(u8, value_str, '.')) |dot| {
        const sec_part = std.fmt.parseInt(u64, value_str[0..dot], 10) catch return null;
        const frac_str = value_str[dot + 1 ..];
        // Pad or truncate frac to 9 digits
        var frac_buf: [9]u8 = [_]u8{'0'} ** 9;
        const copy_len = @min(frac_str.len, 9);
        @memcpy(frac_buf[0..copy_len], frac_str[0..copy_len]);
        const frac_ns = std.fmt.parseInt(u64, &frac_buf, 10) catch return null;
        return sec_part * 1_000_000_000 + frac_ns;
    } else {
        const sec_part = std.fmt.parseInt(u64, value_str, 10) catch return null;
        return sec_part * 1_000_000_000;
    }
}

/// Extract the value of `attr="<value>"` (double-quoted) from an XML tag string.
/// Returns null if not found.
fn extractAttrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    // Build pattern: `attr="`
    var needle_buf: [64]u8 = undefined;
    if (attr.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..attr.len], attr);
    needle_buf[attr.len] = '=';
    needle_buf[attr.len + 1] = '"';
    const needle = needle_buf[0 .. attr.len + 2];

    const start = std.mem.indexOf(u8, tag, needle) orelse return null;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfPos(u8, tag, value_start, "\"") orelse return null;
    return tag[value_start..value_end];
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const fragment_a =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<testsuites name="zunit" tests="3" failures="1" errors="0" skipped="0" time="0.000001234">
    \\  <testsuite name="src.math" tests="3" failures="1" errors="0" skipped="0" time="0.000001234">
    \\    <testcase name="add" classname="src.math" time="0.000000100"/>
    \\    <testcase name="sub" classname="src.math" time="0.000000100">
    \\      <failure message="TestExpectedEqual" type="failure"/>
    \\    </testcase>
    \\    <testcase name="mul" classname="src.math" time="0.000001034"/>
    \\  </testsuite>
    \\</testsuites>
;

const fragment_b =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<testsuites name="zunit" tests="2" failures="0" errors="0" skipped="1" time="0.000000500">
    \\  <testsuite name="src.strings" tests="2" failures="0" errors="0" skipped="1" time="0.000000500">
    \\    <testcase name="isPalindrome" classname="src.strings" time="0.000000400"/>
    \\    <testcase name="countChar" classname="src.strings" time="0.000000100">
    \\      <skipped/>
    \\    </testcase>
    \\  </testsuite>
    \\</testsuites>
;

const fragment_c =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<testsuites name="zunit" tests="4" failures="0" errors="0" skipped="0" time="0.000002000">
    \\  <testsuite name="src.server" tests="2" failures="0" errors="0" skipped="0" time="0.000001000">
    \\    <testcase name="connect" classname="src.server" time="0.000001000"/>
    \\    <testcase name="disconnect" classname="src.server" time="0.000000000"/>
    \\  </testsuite>
    \\  <testsuite name="src.client" tests="2" failures="0" errors="0" skipped="0" time="0.000001000">
    \\    <testcase name="send" classname="src.client" time="0.000000500"/>
    \\    <testcase name="recv" classname="src.client" time="0.000000500"/>
    \\  </testsuite>
    \\</testsuites>
;

test "parseAttrU64: found" {
    const tag = "<testsuite name=\"foo\" tests=\"42\" failures=\"3\" errors=\"0\" skipped=\"1\">";
    try std.testing.expectEqual(@as(?u64, 42), parseAttrU64(tag, "tests"));
    try std.testing.expectEqual(@as(?u64, 3), parseAttrU64(tag, "failures"));
    try std.testing.expectEqual(@as(?u64, 0), parseAttrU64(tag, "errors"));
    try std.testing.expectEqual(@as(?u64, 1), parseAttrU64(tag, "skipped"));
}

test "parseAttrU64: absent" {
    const tag = "<testsuite name=\"foo\" tests=\"5\">";
    try std.testing.expectEqual(@as(?u64, null), parseAttrU64(tag, "failures"));
}

test "parseAttrTimeNs: with fraction" {
    const tag = "<testsuite time=\"1.000001234\">";
    const ns = parseAttrTimeNs(tag, "time");
    try std.testing.expectEqual(@as(?u64, 1_000_001_234), ns);
}

test "parseAttrTimeNs: whole seconds" {
    const tag = "<testsuite time=\"2\">";
    const ns = parseAttrTimeNs(tag, "time");
    try std.testing.expectEqual(@as(?u64, 2_000_000_000), ns);
}

test "parseSuites: single suite" {
    const alloc = std.testing.allocator;
    const suites = try parseSuites(alloc, fragment_a);
    defer alloc.free(suites);
    try std.testing.expectEqual(@as(usize, 1), suites.len);
    try std.testing.expectEqual(@as(u64, 3), suites[0].tests);
    try std.testing.expectEqual(@as(u64, 1), suites[0].failures);
    try std.testing.expectEqual(@as(u64, 0), suites[0].skipped);
}

test "parseSuites: two suites in one fragment" {
    const alloc = std.testing.allocator;
    const suites = try parseSuites(alloc, fragment_c);
    defer alloc.free(suites);
    try std.testing.expectEqual(@as(usize, 2), suites.len);
    // Verify verbatim content contains the expected testsuite names
    try std.testing.expect(std.mem.indexOf(u8, suites[0].verbatim, "src.server") != null);
    try std.testing.expect(std.mem.indexOf(u8, suites[1].verbatim, "src.client") != null);
    // Verify numeric totals
    try std.testing.expectEqual(@as(u64, 2), suites[0].tests);
    try std.testing.expectEqual(@as(u64, 2), suites[1].tests);
}

test "writesMergedXml: three fragments sum to correct totals" {
    const alloc = std.testing.allocator;
    const fragments = [_][]const u8{ fragment_a, fragment_b, fragment_c };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try writesMergedXml(&aw.writer, &fragments);
    const result = aw.writer.buffered();

    // Should contain <testsuites with summed totals: tests=9, failures=1, skipped=1
    try std.testing.expect(std.mem.indexOf(u8, result, "tests=\"9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "failures=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "skipped=\"1\"") != null);
    // Should contain all 4 <testsuite> blocks (1 + 1 + 2)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, result, pos, "<testsuite ")) |found| {
        count += 1;
        pos = found + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "writesMergedXml: empty fragments list produces zero-total header" {
    const alloc = std.testing.allocator;
    const fragments = [_][]const u8{};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try writesMergedXml(&aw.writer, &fragments);
    const result = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, result, "tests=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "failures=\"0\"") != null);
}

test "writesMergedXml: corrupt fragment is skipped, others proceed" {
    const alloc = std.testing.allocator;
    const corrupt = "this is not xml at all";
    const fragments = [_][]const u8{ fragment_a, corrupt, fragment_b };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try writesMergedXml(&aw.writer, &fragments);
    const result = aw.writer.buffered();

    // fragment_a has 3 tests, fragment_b has 2 → total 5
    try std.testing.expect(std.mem.indexOf(u8, result, "tests=\"5\"") != null);
}
