# zunit

A custom test runner and lifecycle library for Zig. It replaces the built-in test runner, giving you `beforeAll`, `afterAll`, `beforeEach`, and `afterEach` hooks scoped globally or per-file, configurable output styles, hook failure handling, and CI-ready reporting.

**How it works:** Zig lets you swap the default test runner by pointing your build at a file that provides `pub fn main()`. zunit's runner is that file — it receives all test functions via `builtin.test_functions`, manages the full hook lifecycle around each one, tracks results, and controls the process exit code. Your `test_runner.zig` simply calls `zunit.run(...)` with whatever configuration you need.

> **Zig version support**
>
> | zunit tag | Zig versions     |
> | --------- | ---------------- |
> | `v2.x`    | `0.16.0` and up  |
> | `v1.0.0`  | `0.15.2`         |
>
> Pick the tag that matches your compiler. The two lines have different APIs
> — `v2.0.0` reworked `zunit.run` to take an `std.Io` parameter because all
> clock and file I/O moved into the `std.Io` interface in Zig 0.16. See the
> [Installation](#installation) section for the exact pin.

---

## Features

- **Full test runner** — replaces Zig's built-in runner; receives all test functions, drives execution, and owns the process exit code
- **Per-file hooks** — `beforeAll` / `afterAll` / `beforeEach` / `afterEach` declared as named test blocks, automatically scoped to the file they live in
- **Global hooks** — `zunit:beforeAll` / `zunit:afterAll` etc. run across the entire suite; also injectable as function pointers in config
- **Configurable failure handling** — choose abort, skip, or continue when a hook errors
- **Three output styles** — minimal summary, verbose per-test, or verbose with nanosecond-precision timing
- **File output** — write results to a plain text file or a JUnit-compatible XML report for CI dashboards
- **`--output-file` CLI flag** — pass the report path at runtime without recompiling
- **Memory leak detection** — resets and checks `std.testing.allocator_instance` around every test

---

## Installation

Add zunit to your `build.zig.zon`. The easiest way is `zig fetch`, which writes both the URL and the integrity hash for you. **Pick the line that matches your Zig version:**

### Zig 0.16.0 and later

```sh
zig fetch --save git+https://github.com/dariogriffo/zunit#v2.0.0
```

```zig
.dependencies = .{
    .zunit = .{
        .url  = "git+https://github.com/dariogriffo/zunit#v2.0.0",
        .hash = "<filled in by zig fetch>",
    },
},
```

### Zig 0.15.2

```sh
zig fetch --save git+https://github.com/dariogriffo/zunit#v1.0.0
```

```zig
.dependencies = .{
    .zunit = .{
        .url  = "git+https://github.com/dariogriffo/zunit#v1.0.0",
        .hash = "<filled in by zig fetch>",
    },
},
```

> The `v1.x` and `v2.x` lines have different runtime APIs. The setup snippet
> in this README is for **v2.x (Zig 0.16+)**. If you are on Zig 0.15.2,
> consult the [v1.0.0 README](https://github.com/dariogriffo/zunit/blob/v1.0.0/README.md)
> — `pub fn main()` takes no parameters there, and `zunit.run` takes only
> the config (no `io`).

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

> `if (b.args) |args| run_tests.addArgs(args);` is required to forward `--output-file` (and any future flags) from `zig build test -- ...` to the runner binary.

---

## Setup

Create `test_runner.zig` in your project root. This file becomes the entry point of the test binary — it *is* the runner. It's the only file you need to write:

```zig
const std = @import("std");
const zunit = @import("zunit");

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        .on_global_hook_failure = .abort,
        .on_file_hook_failure   = .skip_remaining,
        .output                 = .verbose_timing,
        .output_file = try zunit.outputFileArg(
            init.arena.allocator(),
            init.minimal.args,
        ),
    });
}
```

> Why `std.process.Init`? In Zig 0.16, clocks and file I/O go through the
> `std.Io` interface, and command-line arguments arrive via
> `std.process.Init`. zunit needs both, so its `main` takes the full `Init`
> and forwards `init.io` and `init.minimal.args`.

Run your tests:

```sh
zig build test                                       # console output only
zig build test -- --output-file results.xml         # + JUnit XML report
zig build test -- --output-file results.txt         # + plain text report
```

---

## Hooks

### Per-file hooks

Declare hooks as named test blocks anywhere in a `.zig` source file. zunit automatically scopes them to tests **in that file only**, matched by the module path prefix embedded in each test's full name.

```zig
const std = @import("std");

test "beforeAll" {
    // runs once before all tests in this file
    std.debug.print("setting up\n", .{});
}

test "afterAll" {
    // runs once after all tests in this file
}

test "beforeEach" {
    // runs before every individual test in this file
}

test "afterEach" {
    // runs after every individual test in this file
}

test "my feature works" {
    // actual test — preceded by beforeEach, followed by afterEach
}
```

### Global hooks (naming convention)

Prefix with `zunit:` to make a hook apply to **all tests across all files**. Put them in whichever file makes sense for your project (e.g. `src/root.zig`):

```zig
test "zunit:beforeAll" {
    // runs once before the entire suite starts
}

test "zunit:afterAll" {
    // runs once after the entire suite finishes
}

test "zunit:beforeEach" {
    // runs before every test in every file
}

test "zunit:afterEach" {
    // runs after every test in every file
}
```

### Global hooks (programmatic)

Pass functions directly to `zunit.run(...)`. These run **before** the corresponding naming-convention global hooks:

```zig
fn setupDatabase() !void {
    // spin up a test DB, open a file, etc.
}

fn teardownDatabase() !void { ... }
fn resetState() !void { ... }
fn flushLogs() !void { ... }

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        .before_all  = setupDatabase,
        .after_all   = teardownDatabase,
        .before_each = resetState,
        .after_each  = flushLogs,
    });
}
```

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

Pass a `Config` literal as the second argument to `zunit.run(io, config)`. All fields have defaults so you only need to specify what you want to change.

```zig
try zunit.run(init.io, .{
    .on_global_hook_failure = .abort,          // default
    .on_file_hook_failure   = .skip_remaining, // default
    .output                 = .verbose,        // default
    .output_file            = null,            // default
    .before_all  = null,
    .after_all   = null,
    .before_each = null,
    .after_each  = null,
});
```

### `OnHookFailure`

Controls what happens when a lifecycle hook returns an error.

| Value             | Behaviour |
|-------------------|-----------|
| `.abort`          | Print the error and exit the process immediately |
| `.skip_remaining` | Skip all remaining tests in the affected scope (file for per-file hooks, entire suite for global hooks) |
| `.@"continue"`    | Log the error and keep running |

`on_global_hook_failure` defaults to `.abort`; `on_file_hook_failure` defaults to `.skip_remaining`.

### `OutputStyle`

| Value             | What is printed |
|-------------------|-----------------|
| `.minimal`        | A single final line: `N passed  N failed  N skipped` |
| `.verbose`        | One `PASS` / `FAIL` / `SKIP` line per test |
| `.verbose_timing` | Same as verbose, plus elapsed time per test (`123ns` / `1.2µs` / `1.234ms`) |

### `output_file`

When set, results are written to the given path **in addition to** the normal stderr output.

- Path ending in **`.xml`** → JUnit-compatible XML (works with GitHub Actions, Jenkins, GitLab CI, etc.)
- Any other extension → plain text mirroring the console output

Set it at compile time:

```zig
.output_file = "results.xml",
```

Or read it from the command line at runtime with the `outputFileArg` helper. Pass `init.minimal.args` so it can scan the process argv, and `init.arena.allocator()` so the parsed path lives until process exit without manual cleanup:

```zig
.output_file = try zunit.outputFileArg(
    init.arena.allocator(),
    init.minimal.args,
),
```

Then pass it when running:

```sh
zig build test -- --output-file results.xml
zig build test -- --output-file=results.xml   # both forms are accepted
```

---

## Multi-binary test suites

When you fan out `zig build test` across many test binaries (one `b.addTest` per file), every process races to write the same `--output-file` path and only the last writer's results survive. zunit v2.1 solves this with automatic fragment consolidation: each binary writes its own JUnit fragment, and the last one to finish merges all fragments into a single file.

### Quickstart

In your `build.zig`:

```zig
const std = @import("std");
const zunit_build = @import("zunit");   // build-time import

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });

    const suite = zunit_build.testSuite(b, zunit_dep, .{
        .target = target,
        .optimize = optimize,
        .output_file = "test-results.xml",    // merged output
        .output_dir  = "zig-out/test-frags",  // per-binary fragments
    });
    suite.addFile("tests/foo_test.zig");
    suite.addFile("tests/bar_test.zig");
    // add as many files as you like

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(suite.step());
}
```

Run with:

```sh
zig build test                 # runs all binaries, merges into test-results.xml
```

That's it. Each binary writes its own JUnit fragment under `zig-out/test-frags/<run-id>/`. The last binary to finish acquires an exclusive file lock and rewrites `test-results.xml` with the fully merged result. No `-- --output-file` passthrough needed.

### How it works

1. `testSuite` generates a shared `run_id` (a hex timestamp) at build time.
2. For each `addFile`, it creates a test binary with a generated runner that reads `--output-dir`, `--run-id`, and `--consolidate-artifacts` from its argv.
3. When a binary finishes its tests, it writes a JUnit fragment to `<output_dir>/<run_id>/<pid>.xml`.
4. It then acquires an exclusive lock on `<output_dir>/<run_id>/.zunit-merge.lock`, reads all `*.xml` fragments in that directory, merges their `<testsuite>` elements into a single `<testsuites>` root with summed totals, and atomically renames the result to `<output_file>`.
5. The lock is released. The merged file always reflects the union of all fragments written so far — the last writer is always correct.

The exit code of each binary still reflects **that binary's own failures** only, so `zig build test` fails fast if any binary has a failing test.

### Advanced: low-level flags

If you prefer to wire things up manually (e.g. for custom runners), you can use the same CLI flags directly:

```zig
run_t.addArgs(&.{
    "--output-file=test-results.xml",
    "--output-dir=zig-out/test-frags",
    "--run-id=my-shared-id",
    "--consolidate-artifacts=true",
});
```

The corresponding `Config` fields and arg parsers:

```zig
// In test_runner.zig
try zunit.run(init.io, .{
    .output_file          = try zunit.outputFileArg(alloc, init.minimal.args),
    .output_dir           = try zunit.outputDirArg(alloc, init.minimal.args),
    .run_id               = try zunit.runIdArg(alloc, init.minimal.args),
    .consolidate_artifacts = try zunit.consolidateArtifactsArg(init.minimal.args),
});
```

| Flag | Parser | Config field | Description |
|------|--------|--------------|-------------|
| `--output-dir=<path>` | `outputDirArg` | `output_dir` | Directory for per-binary fragments |
| `--run-id=<id>` | `runIdArg` | `run_id` | Shared run identifier; auto-generated if absent |
| `--consolidate-artifacts[=true]` | `consolidateArtifactsArg` | `consolidate_artifacts` | Enable merge-on-exit (requires both `output_file` and `output_dir`) |

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
2. Runs the example suite with `--output-file test-results.xml`
3. Uploads the XML as a workflow artifact
4. Publishes per-test pass/fail to the PR **Checks** tab via [`dorny/test-reporter`](https://github.com/dorny/test-reporter)
5. Writes a markdown pass/fail table to the **job summary** page

To use the same pattern in your own project, add to your workflow:

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
├── build.zig                  # also contains testSuite() build helper (importable by consumers)
├── build.zig.zon
└── .github/
    └── workflows/
        └── ci.yml
```

---

## Running the examples

```sh
# Single-binary example (v2.0.0 API)
zig build example                                    # run with console output
zig build example -- --output-file results.xml      # + JUnit XML
zig build example -- --output-file results.txt      # + plain text

# Multi-binary suite example (v2.1.0 API)
zig build example-suite   # runs math.zig and strings.zig as separate binaries,
                          # merges into zig-out/example-suite-results.xml
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

// Parse --output-file <path> or --output-file=<path> from the given argv.
// Returns null if the flag is absent. The returned slice is allocated with
// the given allocator and owned by the caller; pair with init.arena to let
// the process arena free it on exit.
pub fn outputFileArg(
    allocator: std.mem.Allocator,
    args: std.process.Args,
) !?[]const u8

pub const Config = struct {
    on_global_hook_failure: OnHookFailure = .abort,
    on_file_hook_failure:   OnHookFailure = .skip_remaining,
    output:                 OutputStyle   = .verbose,
    // v2.0.0 single-writer path (unchanged)
    output_file:            ?[]const u8   = null,
    // v2.1.0 multi-binary fragment path (new, optional)
    output_dir:             ?[]const u8   = null,
    run_id:                 ?[]const u8   = null,
    consolidate_artifacts:  bool          = false,
    before_all:  ?*const fn () anyerror!void = null,
    after_all:   ?*const fn () anyerror!void = null,
    before_each: ?*const fn () anyerror!void = null,
    after_each:  ?*const fn () anyerror!void = null,
};

pub const OnHookFailure = enum { abort, skip_remaining, @"continue" };
pub const OutputStyle    = enum { minimal, verbose, verbose_timing };

// v2.1.0 CLI parsers
pub fn outputDirArg(allocator: std.mem.Allocator, args: std.process.Args) !?[]const u8
pub fn runIdArg(allocator: std.mem.Allocator, args: std.process.Args) !?[]const u8
pub fn consolidateArtifactsArg(args: std.process.Args) !bool

// v2.1.0 build helper (importable from consumer's build.zig via @import("zunit"))
pub fn testSuite(b: *std.Build, zunit_dep: *std.Build.Dependency, opts: TestSuiteOptions) *TestSuite
```
