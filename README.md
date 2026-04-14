# zuit

A custom test runner and lifecycle library for Zig. It replaces the built-in test runner, giving you `beforeAll`, `afterAll`, `beforeEach`, and `afterEach` hooks scoped globally or per-file, configurable output styles, hook failure handling, and CI-ready reporting.

**How it works:** Zig lets you swap the default test runner by pointing your build at a file that provides `pub fn main()`. zuit's runner is that file — it receives all test functions via `builtin.test_functions`, manages the full hook lifecycle around each one, tracks results, and controls the process exit code. Your `test_runner.zig` simply calls `zuit.run(...)` with whatever configuration you need.

> Requires Zig **0.15.2** or later.

---

## Features

- **Full test runner** — replaces Zig's built-in runner; receives all test functions, drives execution, and owns the process exit code
- **Per-file hooks** — `beforeAll` / `afterAll` / `beforeEach` / `afterEach` declared as named test blocks, automatically scoped to the file they live in
- **Global hooks** — `zuit:beforeAll` / `zuit:afterAll` etc. run across the entire suite; also injectable as function pointers in config
- **Configurable failure handling** — choose abort, skip, or continue when a hook errors
- **Three output styles** — minimal summary, verbose per-test, or verbose with nanosecond-precision timing
- **File output** — write results to a plain text file or a JUnit-compatible XML report for CI dashboards
- **`--output-file` CLI flag** — pass the report path at runtime without recompiling
- **Memory leak detection** — resets and checks `std.testing.allocator_instance` around every test

---

## Installation

Add zuit to your `build.zig.zon`:

```zig
.dependencies = .{
    .zuit = .{
        .url = "https://github.com/yourname/zuit/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

In `build.zig`, fetch the dependency, expose the module, and wire it into your test step:

```zig
const zuit_dep = b.dependency("zuit", .{ .target = target, .optimize = optimize });
const zuit_mod = zuit_dep.module("zuit");

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
tests.root_module.addImport("zuit", zuit_mod);

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
const zuit = @import("zuit");

pub fn main() !void {
    try zuit.run(.{
        .on_global_hook_failure = .abort,
        .on_file_hook_failure   = .skip_remaining,
        .output                 = .verbose_timing,
        .output_file = try zuit.outputFileArg(std.heap.page_allocator),
    });
}
```

Run your tests:

```sh
zig build test                                       # console output only
zig build test -- --output-file results.xml         # + JUnit XML report
zig build test -- --output-file results.txt         # + plain text report
```

---

## Hooks

### Per-file hooks

Declare hooks as named test blocks anywhere in a `.zig` source file. zuit automatically scopes them to tests **in that file only**, matched by the module path prefix embedded in each test's full name.

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

Prefix with `zuit:` to make a hook apply to **all tests across all files**. Put them in whichever file makes sense for your project (e.g. `src/root.zig`):

```zig
test "zuit:beforeAll" {
    // runs once before the entire suite starts
}

test "zuit:afterAll" {
    // runs once after the entire suite finishes
}

test "zuit:beforeEach" {
    // runs before every test in every file
}

test "zuit:afterEach" {
    // runs after every test in every file
}
```

### Global hooks (programmatic)

Pass functions directly to `zuit.run(...)`. These run **before** the corresponding naming-convention global hooks:

```zig
fn setupDatabase() !void {
    // spin up a test DB, open a file, etc.
}

fn teardownDatabase() !void { ... }
fn resetState() !void { ... }
fn flushLogs() !void { ... }

pub fn main() !void {
    try zuit.run(.{
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
  zuit:beforeAll              ← named global, once

  [for each file, in discovery order]

    beforeAll                 ← named per-file, once per file

    [for each test in this file]

      config.before_each      ← programmatic global
      zuit:beforeEach         ← named global
      beforeEach              ← named per-file

      >>>  TEST  <<<

      afterEach               ← named per-file
      zuit:afterEach          ← named global
      config.after_each       ← programmatic global

    afterAll                  ← named per-file, once per file

  zuit:afterAll               ← named global, once
  config.after_all            ← programmatic, once

[suite end]
```

Hook test blocks (all `beforeAll`, `afterAll`, etc.) are **never counted** in the pass/fail/skip totals.

---

## Configuration reference

Pass a `Config` literal to `zuit.run(...)`. All fields have defaults so you only need to specify what you want to change.

```zig
try zuit.run(.{
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

Or read it from the command line at runtime with the `outputFileArg` helper:

```zig
.output_file = try zuit.outputFileArg(std.heap.page_allocator),
```

Then pass it when running:

```sh
zig build test -- --output-file results.xml
zig build test -- --output-file=results.xml   # both forms are accepted
```

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
<testsuites name="zuit" tests="4" failures="1" errors="0" skipped="1" time="0.000002001">
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

zuit resets `std.testing.allocator_instance` before each test and checks for leaks after it completes. A test that leaks memory is reported as `LEAK` and counted as a failure — matching the behaviour of Zig's built-in test runner:

```
  LEAK  my allocating test
```

---

## CI integration

### GitHub Actions

The repository ships a ready-to-use workflow at `.github/workflows/ci.yml` that:

1. Runs `zig build test` (zuit's own internal tests)
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

The JUnit XML format produced by zuit is also compatible with **Jenkins** (JUnit plugin), **GitLab CI** (`junit` artifact reports), and any other tool that reads the standard JUnit schema.

---

## Project structure

```
zuit/
├── src/
│   ├── zuit.zig          # public API (re-exports from runner + hooks)
│   ├── runner.zig        # test orchestration, output, file writing
│   └── hooks.zig         # hook name constants and classification helpers
├── examples/
│   └── basic/
│       ├── src/
│       │   ├── root.zig      # pulls math + strings into the test binary
│       │   ├── math.zig      # math functions + per-file hooks + tests
│       │   └── strings.zig   # string functions + per-file hooks + tests
│       └── test_runner.zig   # example runner using outputFileArg
├── build.zig
├── build.zig.zon
└── .github/
    └── workflows/
        └── ci.yml
```

---

## Running the example

```sh
zig build example                                    # run with console output
zig build example -- --output-file results.xml      # + JUnit XML
zig build example -- --output-file results.txt      # + plain text
```

---

## Public API summary

```zig
const zuit = @import("zuit");

// Drive the entire test suite. Call this from pub fn main() in your
// test_runner.zig — that makes zuit the runner for the test binary.
pub fn run(config: Config) !void

// Parse --output-file <path> or --output-file=<path> from process argv.
// Returns null if the flag is absent. The returned slice is allocated with
// the given allocator and owned by the caller.
pub fn outputFileArg(allocator: std.mem.Allocator) !?[]const u8

pub const Config = struct {
    on_global_hook_failure: OnHookFailure = .abort,
    on_file_hook_failure:   OnHookFailure = .skip_remaining,
    output:                 OutputStyle   = .verbose,
    output_file:            ?[]const u8   = null,
    before_all:  ?*const fn () anyerror!void = null,
    after_all:   ?*const fn () anyerror!void = null,
    before_each: ?*const fn () anyerror!void = null,
    after_each:  ?*const fn () anyerror!void = null,
};

pub const OnHookFailure = enum { abort, skip_remaining, @"continue" };
pub const OutputStyle    = enum { minimal, verbose, verbose_timing };
```


