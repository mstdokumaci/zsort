# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--bottom` flag places the entire import block (imports, aliases, and
  their attached comments) at the end of the file, keeping `//!` doc
  comments and detached header comments at the top; works with both
  `check` and `fix`

## [0.6.0] - 2026-08-05

### Fixed

- `check`/`fix` output is no longer corrupted when redirected to a file:
  stdout/stderr writers now append at the current offset instead of the
  positional default, which overwrote earlier output from offset 0
- `const X = @This();` is now treated as an alias and sorts first in the
  alias band instead of splitting the import block
- aliases stranded below the import block are now hoisted into the alias
  band instead of being left unsorted in the body
- hoisting a stray import no longer swallows the blank line separating it
  from the code above
- the sorted import block is now always separated from the body by a blank
  line (doc comments stay attached to the decls they document)
- the maximum readable file size was raised from 10 MiB to 32 MiB, so large
  generated files are processed instead of failing with `FileTooBig`

## [0.5.0] - 2026-08-05

### Changed

- Banned-import messages now include the offending line number; summary
  lines omit `failed`/`banned` counts when they are zero

### Added

- Multiple targets: `zsort [check|fix] <path>...` accepts any mix of files
  and directories, enabling pre-commit hook usage
- `.pre-commit-hooks.yaml` manifest with `zsort` (check) and `zsort-fix`
  hooks; inaccessible targets are reported in the summary's failed count
  and still exit 1

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
