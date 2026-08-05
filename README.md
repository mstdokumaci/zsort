# zsort

An opinionated import organizer for Zig, similar to [isort](https://pycqa.github.io/isort/) / [goimports](https://pkg.go.dev/golang.org/x/tools/cmd/goimports).

`zsort check` verifies import ordering; `zsort fix` rewrites files so imports are
grouped and sorted, stray imports are hoisted to the top of the file, and
attached comments travel with their imports.

## Requirements

- Zig **0.15.2 or newer** (Zig 0.16 is supported)
- A Unix-like operating system (Linux or macOS). Windows is not supported —
  on Windows, run `zsort` inside [WSL2](https://learn.microsoft.com/windows/wsl/).

## Installation

There are multiple ways to get `zsort`.

### Homebrew

```sh
brew tap mstdokumaci/zsort
brew install mstdokumaci/zsort/zsort
```

This installs a `zsort` binary built from source with the Homebrew-provided
Zig. No cask or prebuilt bottles involved.

### Prebuilt binaries

Linux and macOS binaries are attached to each
[GitHub Release](https://github.com/mstdokumaci/zsort/releases). Download
`zsort-<target>.tar.gz` (e.g. `zsort-x86_64-linux.tar.gz`), unpack it, and put
`zsort` on your `PATH`.

### As a Zig package

Run:

```sh
zig fetch --save https://github.com/mstdokumaci/zsort/archive/refs/tags/v0.5.0.tar.gz
```

To add zsort to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    // .version
    // .fingerprint
    .dependencies = .{
        .zsort = .{
            .url = "https://github.com/mstdokumaci/zsort/archive/refs/tags/v0.5.0.tar.gz",
            // .hash
            .lazy = true,
        },
    },
    // .paths = .{ "build.zig", "build.zig.zon", ... },
}
```

Then wire up the `check-imports` and `fix-imports` steps in `build.zig`:

```zig
const zsort = b.lazyDependency("zsort", .{
    .target = b.graph.host,
    .optimize = .ReleaseFast,
});
if (zsort) |dep| {
    const zsort_exe = dep.artifact("zsort");

    const check_imports = b.addRunArtifact(zsort_exe);
    check_imports.setCwd(b.path("."));
    check_imports.addArgs(&.{ "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
    const check_imports_step = b.step("check-imports", "Run zsort check on this project");
    check_imports_step.dependOn(&check_imports.step);

    const run_fix_imports = b.addRunArtifact(zsort_exe);
    run_fix_imports.setCwd(b.path("."));
    run_fix_imports.addArgs(&.{ "fix", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
    const fix_imports_step = b.step("fix-imports", "Fix Zig import ordering in this project");
    fix_imports_step.dependOn(&run_fix_imports.step);
}
```

Adjust the `--ban-prefix` flags and target paths to your project. The first
`zig build check-imports` or `zig build fix-imports` run fetches zsort
automatically. The `test/consumer/` project in this repo is a working copy of
this setup.

### From source

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/zsort`.

## Usage

```text
Usage: zsort [check|fix] <dir|file>... [options]

Modes:
  check              Verify Zig import ordering; exit code 1 when changes are needed
  fix                Rewrite files, sorting their imports

Options:
  --ban-prefix <p>   Reject import paths starting with this prefix (repeatable)
  -h, --help         Show this help message
  --version          Print version and exit

Multiple paths may be given; directories are scanned recursively.
```

Examples:

```sh
zsort check src/          # verify; exit 1 if any file needs fixing
zsort fix .               # rewrite all files in the repo
zsort check src/ build.zig   # mixed directories and files
zsort check . --ban-prefix ./ --ban-prefix src/
```

In `check` mode, files that need changes are reported with a unified diff.
`zsort` exits with code 0 when everything is clean, and 1 when any file needs
fixing, errors, or banned imports are found.

## Pre-commit

`zsort` ships a `.pre-commit-hooks.yaml` manifest with two hooks:

- `zsort` — `check` mode; fails when any passed file needs fixing
- `zsort-fix` — `fix` mode; rewrites files in place (use only one)

Add to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/mstdokumaci/zsort
    rev: v0.5.0        # or the latest release tag
    hooks:
      - id: zsort
      # - id: zsort-fix  # fix mode; use only one
```

Requires `zsort` on your `$PATH` (the hooks run with `language: system`).
Use `args` to pass extra flags, e.g. `args: [--ban-prefix, 'src/']`. Only
changed `.zig` files are passed to the hook.

## Ordering rules

`zsort` recognizes three kinds of top-of-file declarations:

- **Plain import** — `const x = @import("path");`
- **Member import** — `const X = @import("path").Member;` (a member access
  after the import; the base path is what gets sorted)
- **Alias** — `const X = module.Member;` (a dotted name with no `@import`).
  `const X = @This();` is treated as an alias too; since it references the
  current module it has no resolvable path and sorts first in the alias band.

Imports are emitted in this order:

1. **std/builtin** — `std`, `builtin`
2. **third-party** — any other module name (`httpz`, `sqlite`, ...)
3. **local** — `root`, `build_root`, paths containing `/`, and paths ending
   in `.zig`
4. **aliases** — keyed by the import path their module name resolves to
   (`auth` → `auth.zig`); unresolvable names fall back to the dotted text as
   written

Blank lines appear only between classification bands (1–3) and before the
alias band. Plain and member imports of the same class sit in one band, no
blank line between them. Before `zsort fix`:

```zig
const std = @import("std");
const Config = auth.Config;
const Router = @import("router.zig").Router;
const httpz = @import("httpz");
// Handles request authentication.
const auth = @import("auth.zig");
```

After:

```zig
const std = @import("std");

const httpz = @import("httpz");

// Handles request authentication.
const auth = @import("auth.zig");
const Router = @import("router.zig").Router;

const Config = auth.Config;
```

Within a band, imports are sorted by path, byte-wise (`a.zig` before
`aa.zig`); identical paths tie-break on the declaration text. Sorting never
depends on where a declaration sits in the file — any input order produces
the same output. `@cImport` blocks count as third-party imports.

### What `fix` does

- Sorts and groups top-of-file imports
- Organizes typed imports (`const x: SomeType = @import(...)`) like plain ones
- Hoists imports that appear later in the file into their proper group
- Hoists aliases stranded below the import block into the alias band
- Keeps comments that immediately precede an import attached to it (blank
  lines do not travel with an import)
- Ensures a blank line separates the import block from the following code
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

## See Also

- [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, lint gates,
and contribution guidelines.
- [CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT
