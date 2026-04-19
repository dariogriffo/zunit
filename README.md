# zunit

A custom test runner and lifecycle library for Zig. It replaces the built-in test runner, giving you `beforeAll`, `afterAll`, `beforeEach`, and `afterEach` hooks scoped globally or per-file, configurable output styles, hook failure handling, and CI-ready reporting.

**How it works:** Zig lets you swap the default test runner by pointing your build at a file that provides `pub fn main()`. zunit's runner is that file — it receives all test functions via `builtin.test_functions`, manages the full hook lifecycle around each one, tracks results, and controls the process exit code. Your `test_runner.zig` simply calls `zunit.run(...)` with whatever configuration you need.

> **Zig version support.** zunit `v2.x` targets Zig `0.16.0` and up. Every
> example in this README is written against the v2 API.

---

## Examples

Each example is self-contained and builds on the previous. The first few cover the single-binary case; the later ones show the multi-binary `testSuite` helper.

### 1. Minimal `test_runner.zig`

The shortest runner you can write — every `Config` field has a sensible default:

```zig
const std = @import("std");
const zunit = @import("zunit");

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{});
}
```

Point `build.zig` at this file as the test runner (see [Installation](#installation)) and `zig build test` prints `PASS` / `FAIL` / `SKIP` per test and exits non-zero on failure.

### 2. Choosing an output style

```zig
try zunit.run(init.io, .{ .output = .verbose_timing });
```

| Style | Output |
|---|---|
| `.minimal` | Final line: `N passed  N failed  N skipped` |
| `.verbose` | One `PASS` / `FAIL` / `SKIP` line per test (default) |
| `.verbose_timing` | Verbose + nanosecond-precision elapsed time per test |

### 3. Writing JUnit XML to a file

Pass a path ending in `.xml`:

```zig
try zunit.run(init.io, .{ .output_file = "results.xml" });
```

Any other extension writes plain text that mirrors the console output. Relative paths resolve against the process working directory.

### 4. Accepting the output path from the command line

Let users and CI pick the output path at run time without recompiling:

```zig
pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        .output_file = try zunit.outputFileArg(
            init.arena.allocator(),
            init.minimal.args,
        ),
    });
}
```

```sh
zig build test -- --output-file results.xml
zig build test -- --output-file=/tmp/results.xml   # both forms accepted
```

Pass `init.arena.allocator()` so the parsed string lives until process exit with no manual cleanup.

### 5. Per-file hooks

Name a test block `beforeAll`, `afterAll`, `beforeEach`, or `afterEach` — zunit scopes it to that source file automatically:

```zig
const std = @import("std");

test "beforeAll" { std.debug.print("db: connect\n", .{}); }
test "afterAll"  { std.debug.print("db: close\n",   .{}); }
test "beforeEach" { /* reset state */ }
test "afterEach"  { /* log query count */ }

test "users.create inserts a row" { /* ... */ }
test "users.delete cascades"      { /* ... */ }
```

### 6. Global hooks (naming convention)

Prefix with `zunit:` to apply a hook across every file in the suite. Put it wherever makes sense — `src/root.zig` is conventional:

```zig
test "zunit:beforeAll"  { /* once, before the entire suite */ }
test "zunit:afterAll"   { /* once, after the entire suite */ }
test "zunit:beforeEach" { /* before every test in every file */ }
test "zunit:afterEach"  { /* after every test in every file */ }
```

### 7. Global hooks (programmatic)

Function pointers on `Config` run **before** the naming-convention hooks — useful when setup depends on imports or closures that a `test` block can't express:

```zig
fn setupDb()    !void { /* ... */ }
fn teardownDb() !void { /* ... */ }

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        .before_all = setupDb,
        .after_all  = teardownDb,
    });
}
```

### 8. Controlling hook failure behaviour

```zig
try zunit.run(init.io, .{
    .on_global_hook_failure = .abort,           // default
    .on_file_hook_failure   = .skip_remaining,  // default
});
```

| Value | Behaviour |
|---|---|
| `.abort` | Print the error and exit the process immediately |
| `.skip_remaining` | Skip the rest of the affected scope (file for per-file hooks, suite for global) |
| `.@"continue"` | Log the error and keep running |

### 9. Multi-binary test suite — simplest case

When `zig build test` fans out into many test binaries (one `b.addTest` per file), every process races for the same `--output-file` path and only the last writer survives. The `testSuite` build helper solves this with automatic fragment consolidation — no CLI flags at run time:

```zig
// build.zig
const std = @import("std");
const zunit_build = @import("zunit");   // build-time import

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });
    const suite = zunit_build.testSuite(b, zunit_dep, .{
        .target = target,
        .optimize = optimize,
    });
    suite.addFile("tests/users_test.zig");
    suite.addFile("tests/orders_test.zig");

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(suite.step());
}
```

```sh
zig build test
```

All tests run across separate binaries, each writes its own JUnit fragment under `zig-out/test-fragments/<run-id>/`, and the last binary to finish merges them into `zig-out/test-fragments/test-results.xml`.

### 10. Multi-binary with shared module imports

If every test binary needs the same set of `@import` names, declare them once:

```zig
const suite = zunit_build.testSuite(b, zunit_dep, .{
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "app",     .module = app_module },
        .{ .name = "storage", .module = storage_module },
    },
});
suite.addFile("tests/users_test.zig");    // sees @import("app") and @import("storage")
suite.addFile("tests/orders_test.zig");
```

### 11. Custom output paths

```zig
const suite = zunit_build.testSuite(b, zunit_dep, .{
    .target = target,
    .optimize = optimize,
    .output_dir  = "zig-out/ci",
    .output_file = "junit.xml",   // relative → resolves to zig-out/ci/junit.xml
});
```

### 12. Relative vs absolute `output_file`

When `output_file` is **relative**, zunit resolves it under `output_dir`:

```
output_dir  = "zig-out/ci"
output_file = "junit.xml"
→ merged XML at zig-out/ci/junit.xml
```

When it's **absolute**, it's used as-is:

```
output_dir  = "zig-out/ci"
output_file = "/tmp/junit.xml"
→ merged XML at /tmp/junit.xml
```

The same rule applies to the `--output-file` CLI flag.

### 13. Defaulting `output_file` with `--consolidate-artifacts`

Passing `--consolidate-artifacts` without `--output-file` defaults to `test-results.xml` — which, per the rule above, resolves under `--output-dir`:

```sh
your-test-binary --output-dir=zig-out --consolidate-artifacts=true
# merged XML lands at zig-out/test-results.xml
```

### 14. Low-level: driving consolidation from CLI flags

If you run zunit outside of the `testSuite` helper (custom runners, non-Zig build systems, manual fan-out), the same consolidation works via CLI flags directly. Each process writes its own fragment and the last one finishes the merge:

```sh
your-test-binary \
  --output-dir=zig-out/frags \
  --run-id=$CI_JOB_ID \
  --consolidate-artifacts=true \
  --output-file=results.xml
```

| Flag | `Config` field | Description |
|---|---|---|
| `--output-file=<path>` | `output_file` | Final merged JUnit XML (relative → resolved under `--output-dir`; defaults to `test-results.xml` when `--consolidate-artifacts` is set) |
| `--output-dir=<path>` | `output_dir` | Directory for per-binary fragments; also the base for a relative `output_file` |
| `--run-id=<id>` | `run_id` | Shared identifier for one consolidated run (generated per-process if unset) |
| `--consolidate-artifacts[=true]` | `consolidate_artifacts` | Enable merge-on-exit (requires `--output-dir`) |

In `test_runner.zig`, the corresponding parsers:

```zig
try zunit.run(init.io, .{
    .output_file           = try zunit.outputFileArg(alloc, init.minimal.args),
    .output_dir            = try zunit.outputDirArg(alloc, init.minimal.args),
    .run_id                = try zunit.runIdArg(alloc, init.minimal.args),
    .consolidate_artifacts = try zunit.consolidateArtifactsArg(init.minimal.args),
});
```

If you're using `testSuite`, this runner file is generated for you.

---

## Features

- **Full test runner** — replaces Zig's built-in runner; receives all test functions, drives execution, and owns the process exit code
- **Per-file hooks** — `beforeAll` / `afterAll` / `beforeEach` / `afterEach` declared as named test blocks, automatically scoped to the file they live in
- **Global hooks** — `zunit:beforeAll` / `zunit:afterAll` etc. run across the entire suite; also injectable as function pointers in config
- **Configurable failure handling** — choose abort, skip, or continue when a hook errors
- **Three output styles** — minimal summary, verbose per-test, or verbose with nanosecond-precision timing
- **File output** — write results to a plain text file or a JUnit-compatible XML report for CI dashboards
- **`--output-file` CLI flag** — pass the report path at runtime without recompiling
- **Multi-binary consolidation** — `testSuite` helper merges JUnit fragments from many test binaries into one report
- **Memory leak detection** — resets and checks `std.testing.allocator_instance` around every test

---

## Installation

Add zunit to your `build.zig.zon`. The easiest way is `zig fetch`, which writes both the URL and the integrity hash for you:

```sh
zig fetch --save git+https://github.com/dariogriffo/zunit#v2.1.1
```

```zig
.dependencies = .{
    .zunit = .{
        .url  = "git+https://github.com/dariogriffo/zunit#v2.1.1",
        .hash = "<filled in by zig fetch>",
    },
},
```

In `build.zig`, fetch the dependency, expose the module, and wire it into your test step:

```zig
const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });
const zunit_mod = zunit_dep.module("zunit");

const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .test_runner = .{
        .path = b.path("test_runner.zig"),
        .mode = .simple,
    },
});
tests.root_module.addImport("zunit", zunit_mod);

const run_tests = b.addRunArtifact(tests);
if (b.args) |args| run_tests.addArgs(args); // forward -- ... args to the runner
const test_step = b.step("test", "Run tests");
test_step.dependOn(&run_tests.step);
```

> `if (b.args) |args| run_tests.addArgs(args);` is required to forward `--output-file` (and any future flags) from `zig build test -- ...` to the runner binary. If you're using the `testSuite` helper (example 9 above), this is handled for you.

---

## Hooks

### Per-file hooks

Declare hooks as named test blocks anywhere in a `.zig` source file. zunit automatically scopes them to tests **in that file only**, matched by the module path prefix embedded in each test's full name. See [example 5](#5-per-file-hooks) for a complete sample.

### Global hooks (naming convention)

Prefix with `zunit:` to make a hook apply to **all tests across all files**. See [example 6](#6-global-hooks-naming-convention).

### Global hooks (programmatic)

Pass functions directly to `zunit.run(...)`. These run **before** the corresponding naming-convention global hooks. See [example 7](#7-global-hooks-programmatic).

---

## Hook execution order

```
[suite start]

  config.before_all           ← programmatic, once
  zunit:beforeAll              ← named global, once

  [for each file, in discovery order]

    beforeAll                 ← named per-file, once per file

    [for each test in this file]

      config.before_each      ← programmatic global
      zunit:beforeEach         ← named global
      beforeEach              ← named per-file

      >>>  TEST  <<<

      afterEach               ← named per-file
      zunit:afterEach          ← named global
      config.after_each       ← programmatic global

    afterAll                  ← named per-file, once per file

  zunit:afterAll               ← named global, once
  config.after_all            ← programmatic, once

[suite end]
```

Hook test blocks (all `beforeAll`, `afterAll`, etc.) are **never counted** in the pass/fail/skip totals.

---

## Configuration reference

Pass a `Config` literal as the second argument to `zunit.run(io, config)`. All fields have defaults, so you only need to specify what you want to change.

```zig
try zunit.run(init.io, .{
    // Output
    .output                 = .verbose,        // .minimal | .verbose | .verbose_timing
    .output_file            = null,            // []const u8 or null

    // Hook failure behaviour
    .on_global_hook_failure = .abort,          // .abort | .skip_remaining | .@"continue"
    .on_file_hook_failure   = .skip_remaining,

    // Programmatic global hooks
    .before_all  = null,
    .after_all   = null,
    .before_each = null,
    .after_each  = null,

    // Multi-binary consolidation (usually set by the testSuite helper, not by hand)
    .output_dir            = null,
    .run_id                = null,
    .consolidate_artifacts = false,
});
```

See the [multi-binary examples](#9-multi-binary-test-suite--simplest-case) for how `output_dir`, `run_id`, and `consolidate_artifacts` interact.

---

## How consolidation works

When `testSuite` (or the equivalent CLI flags) wire up multi-binary consolidation:

1. `testSuite` generates a shared `run_id` (a hex timestamp) at build time and passes it to every test binary as `--run-id=<id>`.
2. Each binary runs its tests, then writes a self-contained JUnit fragment to `<output_dir>/<run_id>/<pid>.xml`.
3. It acquires an exclusive lock on `<output_dir>/<run_id>/.zunit-merge.lock`, reads every `*.xml` fragment in that directory, merges their `<testsuite>` elements into a single `<testsuites>` root with summed totals, and atomically renames the result to `<output_file>` (resolved per [example 12](#12-relative-vs-absolute-output_file)).
4. The lock is released. Every process performs steps 2–4; the last writer wins, and the merged file always reflects the union of all fragments.

The exit code of each binary still reflects **that binary's own failures** only, so `zig build test` fails fast if any binary has a failing test.

---

## Output examples

### Console (`verbose_timing`)

```
[db] setting up

  PASS  insert: single row   487ns
  PASS  insert: batch         1.2µs
  FAIL  delete: cascade      312ns
  SKIP  update: soft-delete

[db] tearing down

  2 passed  1 failed  1 skipped
```

### JUnit XML

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="zunit" tests="4" failures="1" errors="0" skipped="1" time="0.000002001">
  <testsuite name="db" tests="4" failures="1" errors="0" skipped="1" time="0.000002001">
    <testcase name="insert: single row" classname="db" time="0.000000487"/>
    <testcase name="insert: batch"      classname="db" time="0.000001200"/>
    <testcase name="delete: cascade"    classname="db" time="0.000000312">
      <failure message="TestExpectedEqual" type="failure"/>
    </testcase>
    <testcase name="update: soft-delete" classname="db" time="0.000000000">
      <skipped/>
    </testcase>
  </testsuite>
</testsuites>
```

The `time` attribute is in seconds with nanosecond precision. Test names and classnames are XML-escaped automatically.

---

## Memory leak detection

zunit resets `std.testing.allocator_instance` before each test and checks for leaks after it completes. A test that leaks memory is reported as `LEAK` and counted as a failure — matching the behaviour of Zig's built-in test runner:

```
  LEAK  my allocating test
```

---

## CI integration

### GitHub Actions

The repository ships a ready-to-use workflow at `.github/workflows/ci.yml` that:

1. Runs `zig build test` (zunit's own internal tests)
2. Runs the multi-binary example suite and produces a merged JUnit XML
3. Uploads the XML as a workflow artifact
4. Publishes per-test pass/fail to the PR **Checks** tab via [`dorny/test-reporter`](https://github.com/dorny/test-reporter)
5. Writes a markdown pass/fail table to the **job summary** page

To use the same pattern in your own project (single-binary case):

```yaml
- name: Run tests
  run: zig build test -- --output-file test-results.xml

- name: Upload test results
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: test-results
    path: test-results.xml

- name: Publish test report
  uses: dorny/test-reporter@v1
  if: always()
  with:
    name: Test Results
    path: test-results.xml
    reporter: java-junit
    fail-on-error: false
```

If you're using the `testSuite` helper, drop the `-- --output-file …` from the run step and point `path:` at `zig-out/test-fragments/test-results.xml` (or wherever your `output_dir` / `output_file` resolved to).

The JUnit XML format produced by zunit is also compatible with **Jenkins** (JUnit plugin), **GitLab CI** (`junit` artifact reports), and any other tool that reads the standard JUnit schema.

---

## Project structure

```
zunit/
├── src/
│   ├── zunit.zig          # public API (re-exports from runner + hooks + merge)
│   ├── runner.zig         # test orchestration, output, fragment writing, consolidation
│   ├── hooks.zig          # hook name constants and classification helpers
│   └── merge.zig          # pure JUnit XML fragment merge logic
├── examples/
│   └── basic/
│       ├── src/
│       │   ├── root.zig       # pulls math + strings into the single-binary example
│       │   ├── math.zig       # math functions + per-file hooks + tests
│       │   └── strings.zig    # string functions + per-file hooks + tests
│       └── test_runner.zig    # example runner using outputFileArg
├── build.zig                  # also exposes the testSuite() build helper
├── build.zig.zon
└── .github/
    └── workflows/
        └── ci.yml
```

---

## Running the examples

```sh
# Single-binary example (basic test_runner.zig usage)
zig build example                                    # console output
zig build example -- --output-file results.xml      # + JUnit XML
zig build example -- --output-file results.txt      # + plain text

# Multi-binary suite example (testSuite helper)
zig build example-suite
# merged JUnit XML lands at zig-out/example-suite/test-results.xml
```

---

## Public API summary

```zig
const std   = @import("std");
const zunit = @import("zunit");

// Drive the entire test suite. Call this from
// pub fn main(init: std.process.Init) in your test_runner.zig — that makes
// zunit the runner for the test binary. `io` powers the monotonic clock
// and JUnit-XML file writes.
pub fn run(io: std.Io, config: Config) !void

// CLI flag parsers. All return the parsed value, or null (or false) when
// the flag is absent. String results are allocated with the given allocator
// and owned by the caller; pair with init.arena to let the process arena
// free them on exit.
pub fn outputFileArg(          allocator, args) !?[]const u8
pub fn outputDirArg(           allocator, args) !?[]const u8
pub fn runIdArg(               allocator, args) !?[]const u8
pub fn consolidateArtifactsArg(args)             !bool

pub const Config = struct {
    on_global_hook_failure: OnHookFailure = .abort,
    on_file_hook_failure:   OnHookFailure = .skip_remaining,
    output:                 OutputStyle   = .verbose,

    output_file:            ?[]const u8   = null,
    output_dir:             ?[]const u8   = null,
    run_id:                 ?[]const u8   = null,
    consolidate_artifacts:  bool          = false,

    before_all:  ?*const fn () anyerror!void = null,
    after_all:   ?*const fn () anyerror!void = null,
    before_each: ?*const fn () anyerror!void = null,
    after_each:  ?*const fn () anyerror!void = null,
};

pub const OnHookFailure = enum { abort, skip_remaining, @"continue" };
pub const OutputStyle   = enum { minimal, verbose, verbose_timing };

// Build helper — importable from a consumer's build.zig via @import("zunit").
pub fn testSuite(
    b: *std.Build,
    zunit_dep: *std.Build.Dependency,
    opts: TestSuiteOptions,
) *TestSuite

pub fn testSuiteFromModule(
    b: *std.Build,
    zunit_mod: *std.Build.Module,
    opts: TestSuiteOptions,
) *TestSuite
```
