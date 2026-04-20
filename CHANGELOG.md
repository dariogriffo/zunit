# Changelog

## [2.2.0](https://github.com/dariogriffo/zunit/compare/v2.1.1...v2.2.0) (2026-04-20)


### Features

* runner updates ([#13](https://github.com/dariogriffo/zunit/issues/13)) ([e2a8cac](https://github.com/dariogriffo/zunit/commit/e2a8cac0eeac042c0dc11de4b549b70c7f797565))

## [2.1.1](https://github.com/dariogriffo/zunit/compare/v2.1.0...v2.1.1) (2026-04-19)


### Bug Fixes

* ci errors ([#11](https://github.com/dariogriffo/zunit/issues/11)) ([428513a](https://github.com/dariogriffo/zunit/commit/428513a30e4f32f5a83caa3941259a49fa1aa4d1))

## [2.1.0](https://github.com/dariogriffo/zunit/compare/v2.0.0...v2.1.0) (2026-04-19)


### Features

* multi-binary test suits ([#9](https://github.com/dariogriffo/zunit/issues/9)) ([dd3f152](https://github.com/dariogriffo/zunit/commit/dd3f152738c8faaeea51f37183859ebfba97b3b3))

## [2.1.0](https://github.com/dariogriffo/zunit/compare/v2.0.0...v2.1.0) (2026-04-19)

### Features

* **multi-binary test suites**: add `testSuite` build helper for fan-out test runs with automatic JUnit XML consolidation
* **runner**: add `output_dir`, `run_id`, `consolidate_artifacts` fields to `Config`
* **runner**: add `outputDirArg`, `runIdArg`, `consolidateArtifactsArg` CLI parsers
* **merge**: add `merge.zig` with pure fragment-merge logic (flock-protected, atomic rename)

### Notes

* Fully backward-compatible with v2.0.0. All existing `Config.output_file` / `outputFileArg` usage is unchanged.
* Windows: flock-based merge uses `Io.File.lock(.exclusive)` which delegates to `LockFileEx` via the Zig stdlib; no extra work needed.

## [2.0.0](https://github.com/dariogriffo/zunit/compare/v1.0.0...v2.0.0) (2026-04-17)


### ⚠ BREAKING CHANGES

* update build to zig 0.16.0 ([#7](https://github.com/dariogriffo/zunit/issues/7))

### Features

* update build to zig 0.16.0 ([#7](https://github.com/dariogriffo/zunit/issues/7)) ([03ea08c](https://github.com/dariogriffo/zunit/commit/03ea08c5607b2fcd2c5183381cda173d44f58b34))

## [1.0.0](https://github.com/dariogriffo/zunit/compare/v0.2.0...v1.0.0) (2026-04-15)


### ⚠ BREAKING CHANGES

* Rename to zunit ([#5](https://github.com/dariogriffo/zunit/issues/5))

### Code Refactoring

* Rename to zunit ([#5](https://github.com/dariogriffo/zunit/issues/5)) ([e51cc66](https://github.com/dariogriffo/zunit/commit/e51cc664e73fc1db879de9626a3f75e7eec06d4d))

## [0.2.0](https://github.com/dariogriffo/zunit/compare/v0.1.0...v0.2.0) (2026-04-14)


### Features

* first release ([cbf7f2f](https://github.com/dariogriffo/zunit/commit/cbf7f2fadf64132dc694c8c383d2147e7b5d0439))
