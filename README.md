# zsort

An opinionated import organizer for Zig, similar to [isort](https://pycqa.github.io/isort/) / [goimports](https://pkg.go.dev/golang.org/x/tools/cmd/goimports).

`zsort check` verifies import ordering; `zsort fix` rewrites files so imports are
grouped and sorted, stray imports are hoisted to the top of the file, and
attached comments travel with their imports.

## Requirements

- Zig **0.15.2 or newer** (0.16 support is in progress)

## Installation

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/zsort`.

## Usage

```
Usage: zsort [check|fix] <dir|file> [options]

Modes:
  check              Verify Zig import ordering; exits 1 when changes are needed
  fix                Rewrite files with sorted imports

Options:
  --ban-prefix <p>   Reject import paths starting with prefix (repeatable)
  -h, --help         Show this help message
  --version          Print version and exit
```

Examples:

```sh
zsort check src/          # verify; exit 1 if any file needs fixing
zsort fix .               # rewrite all files in the repo
zsort check . --ban-prefix ./ --ban-prefix src/
```

In `check` mode, files that need changes are reported with a unified diff.
`zsort` exits with code 0 when everything is clean, and 1 when any file needs
fixing, errors, or banned imports are found.

## Ordering rules

Imports are classified into three groups, in this order:

1. **std/builtin** — `std`, `builtin`
2. **third-party** — any other module name (`sqlite`, `httpz`, ...)
3. **local** — `root`, `build_root`, paths containing `/`, and paths ending in `.zig`

Within each group, imports are sorted by path, then by import-text length, then
by original position (so identical imports stay stable). Groups are separated
by a blank line. `@cImport` blocks are treated as third-party imports and
moved as a whole.

### What `fix` does

- Sorts and groups top-of-file imports
- Hoists imports that appear later in the file into their proper group
- Keeps comments that immediately precede an import attached to it
- Preserves `//!` module documentation and the file's line endings (CRLF kept)

### Escape hatches

- `// zsort: skip` anywhere in a file leaves it completely untouched
- `--ban-prefix <prefix>` makes any import starting with `prefix` fail in both
  `check` and `fix` modes (e.g. ban `./`-relative and `src/`-prefixed paths)

### .gitignore support

When given a directory, `zsort` reads `<dir>/.gitignore` and skips matching
paths, along with `.git`, `.zig-cache`, `zig-cache`, and `zig-out`.

> **Limitation:** gitignore entries are matched as path-component prefixes.
> Wildcards (`*?[`) and negation (`!`) are not supported and are skipped.
> A pattern like `build` matches `build/` and `a/build/x.zig`, but not
> `build-tools/x.zig`.

## Development

```sh
zig build test             # unit tests
zig build check-imports    # run zsort on its own source (dogfood)
zig build lint             # zwanzig, whole repo
zig fmt --check src        # formatting
```

Linting uses [zwanzig](https://github.com/forketyfork/zwanzig). The repo is
also linted with [zlint](https://github.com/DonIsaac/zlint):

```sh
zlint --deny-warnings
```

Note: `// zlint-disable no-print` at the top of `src/zsort.zig` is a zlint
file-level disable for the intentional `std.debug.print` calls that produce
CLI output — it is not dead code and must not be removed.

## License

MIT
