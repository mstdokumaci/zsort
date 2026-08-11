# zsort

An opinionated import organizer for Zig. Sorts, groups, and hoists `@import`
declarations, similar to [isort](https://pycqa.github.io/isort/) for Python or
[goimports](https://pkg.go.dev/golang.org/x/tools/cmd/goimports) for Go.

## Installation

> [!NOTE]
> Requires Zig 0.15.2 or newer (including 0.16) on Linux or macOS.
> On Windows, use [WSL2](https://learn.microsoft.com/windows/wsl/).

### Homebrew

```sh
brew tap mstdokumaci/zsort
brew install mstdokumaci/zsort/zsort
```

### Prebuilt binaries

Download from [GitHub Releases](https://github.com/mstdokumaci/zsort/releases),
unpack, and add to your `PATH`.

### Zig package (build dependency)

Add to `build.zig.zon`:

```zig
.zsort = .{
    .url = "https://github.com/mstdokumaci/zsort/archive/refs/tags/v0.7.0.tar.gz",
    // .hash
    .lazy = true,
},
```

Wire up build steps in `build.zig`:

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
    b.step("check-imports", "Run zsort check on this project").dependOn(&check_imports.step);

    const run_fix = b.addRunArtifact(zsort_exe);
    run_fix.setCwd(b.path("."));
    run_fix.addArgs(&.{ "fix", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
    b.step("fix-imports", "Fix Zig import ordering in this project").dependOn(&run_fix.step);
}
```

See [`test/consumer/`](test/consumer/) for a working example.

### From source

```sh
zig build -Doptimize=ReleaseFast    # → zig-out/bin/zsort
```

## Usage

```text
Usage: zsort [check|fix] <dir|file>... [options]

Modes:
  check              Verify import ordering (exit 1 if changes needed)
  fix                Rewrite files in place

Options:
  --ban-prefix <p>   Reject imports starting with <p> (repeatable)
  --bottom           Place the import block at the end of the file
  -h, --help         Show help
  --version          Print version
```

```sh
zsort check src/                                  # verify a directory
zsort fix .                                       # fix everything
zsort check src/ build.zig                        # mixed targets
zsort check . --ban-prefix ./ --ban-prefix src/   # ban relative paths
zsort fix . --bottom                              # imports at the end of the file
```

- `check` prints unified diffs for files that need changes.
- `// zsort: skip` anywhere in a file excludes it from processing.
- Directories are scanned recursively. `.gitignore` entries, `.git`, `.zig-cache`,
  `zig-cache`, and `zig-out` are skipped automatically.

## Sorting rules

zsort groups imports into four bands, separated by blank lines:

1. **std / builtin** — the `std` and `builtin` modules
2. **Third-party** — other module names (`httpz`, `sqlite`, …), including `@cImport`
3. **Local** — paths containing `/` or ending in `.zig`, plus Zig's package-level
   modules `root` (the package's own root source file) and `build_root` (the
   build runner's root module)
4. **Aliases** — `const X = module.Member;` where `module` resolves to an import
   above; `const X = @This();` sorts first in this band

Within each band, plain imports come before member imports, then both are sorted
by path (byte-wise). If two imports share the same path, the full line of code
breaks the tie (e.g. `const Foo = @import("x.zig").Foo;` before
`const bar = @import("x.zig").bar;`). The output is deterministic regardless
of input order.

Before `zsort fix`:

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

### What `fix` does

- Sorts and groups top-of-file imports into the bands above
- Hoists stray imports and aliases from deeper in the file into their proper band
- Keeps preceding comments attached to their import
- Ensures a blank line between the import block and the following code
- Preserves `//!` doc comments and original line endings (LF / CRLF)

With `--bottom`, the whole block instead moves to the end of the file (the
layout used by `zig init` templates): `//!` doc comments and comments
detached by a blank line stay at the top, comments directly attached to an
import travel with it, and comments after the last import stay with the
body. The sort order and bands are unchanged.

## Pre-commit

Add to `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/mstdokumaci/zsort
    rev: v0.7.0
    hooks:
      - id: zsort        # check mode (fail on unsorted)
      # - id: zsort-fix  # fix mode (rewrite in place)
```

Requires `zsort` on `$PATH` (`language: system`). Pass extra flags via `args`,
e.g. `args: [--ban-prefix, 'src/']`. Only `.zig` files are checked.

## See also

- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup and lint gates
- [CHANGELOG.md](CHANGELOG.md) — release history

## License

MIT
