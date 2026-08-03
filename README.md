# zsort

An opinionated import organizer for Zig, similar to [isort](https://pycqa.github.io/isort/) / [goimports](https://pkg.go.dev/golang.org/x/tools/cmd/goimports).

`zsort check` verifies import ordering; `zsort fix` rewrites files so imports are
grouped and sorted, stray imports are hoisted to the top of the file, and
attached comments travel with their imports.

## Requirements

- Zig **0.15.2 or newer** (Zig 0.16 is supported)

## Installation

There are two ways to get `zsort`.

### Homebrew

```sh
brew tap mstdokumaci/zsort
brew install zsort
```

This installs a `zsort` binary built from source with the Homebrew-provided
Zig. No cask or prebuilt bottles involved.

### As a Zig package

Add zsort to your `build.zig.zon` (run `zig fetch --save` to fill in the
hash):

```zig
.{
    .name = .my_project,
    .version = "0.0.0",
    .fingerprint = 0x..., // your own
    .dependencies = .{
        .zsort = .{
            .url = "https://github.com/mstdokumaci/zsort/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
            .lazy = true,
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
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
zig fmt --check src        # formatting
```

Linting uses [zwanzig](https://github.com/forketyfork/zwanzig) and
[zlint](https://github.com/DonIsaac/zlint), both run directly as pre-built
binaries — there is no build step for them:

```sh
# zwanzig — pick the asset for your platform:
#   zwanzig-v0.14.0-linux-x86_64.tar.gz
#   zwanzig-v0.14.0-macos-aarch64.tar.gz
#   zwanzig-v0.14.0-windows-x86_64.zip
curl -fsSL -o /tmp/zwanzig.tar.gz \
  "https://github.com/forketyfork/zwanzig/releases/download/v0.14.0/zwanzig-v0.14.0-macos-aarch64.tar.gz"
mkdir -p /tmp/zwanzig
tar -xzf /tmp/zwanzig.tar.gz -C /tmp/zwanzig
sudo mv /tmp/zwanzig/zwanzig /usr/local/bin/zwanzig

zwanzig src build.zig

zlint --deny-warnings
```

Note: `// zlint-disable no-print` at the top of `src/zsort.zig` is a zlint
file-level disable for the intentional `std.debug.print` calls that produce
CLI output — it is not dead code and must not be removed.

## License

MIT
