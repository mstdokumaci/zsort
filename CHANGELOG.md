# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-08-04

### Changed

- CLI output overhaul: git-style colored diffs, semantic colors for
  per-file events and the summary, and uniformly indented messages when
  running on a terminal (plain output when piped)
- Summary wording is now `Found/Fixed N of M files to fix, N failed, N
  banned in Nms.`; parse errors print the reason before the usage block
  instead of duplicating it
- Help text clarifies `fix` and `--ban-prefix`; usage hint on errors now
  matches `--help`
- Platform support: Windows is explicitly not supported; WSL2 is the
  recommended way to run zsort on Windows

## [0.3.0] - 2026-08-04

### Added

- Deterministic sorting: any input order produces the same output
- CI workflow that publishes cross-platform binaries on `v*` tag pushes
- Version is declared in both `build.zig.zon` and `src/version.zig`, with a
  build-time consistency check in `build.zig`
- CONTRIBUTING.md with lint gates, acceptance criteria, and a releasing
  checklist

### Changed

- CI zig gates (tests, `check-imports`, fmt, compile) now run on both Zig
  0.15.2 and 0.16; external linters (zlint, zwanzig) run on 0.15.2
- Homebrew tap is auto-bumped on `v*` tag pushes

## [0.2.0] - 2026-08-04

### Changed

- Import analysis rewritten on top of `std.zig.Ast` (replaces handrolled
  scans); handles typed imports, `@cImport` blocks, and escaped paths
- Lint setup (zlint, zwanzig) added to CI and CONTRIBUTING

### Fixed

- Homebrew installation instructions

## [0.1.0] - 2026-08-03

### Added

- Initial release: `zsort check` / `zsort fix` with 4-band import grouping
  (std/builtin, third-party, local, aliases)
- Comment attachment, `//!` module doc preservation, stray import hoisting
- `--ban-prefix`, `// zsort: skip`, `.gitignore` support
- `build.zig` integration as a lazy dependency (`check-imports` /
  `fix-imports` steps) and a Homebrew tap
