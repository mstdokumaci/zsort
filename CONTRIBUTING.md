# Contributing

Open an issue before sending a pull request so the change can be discussed first.

## Requirements

Zig 0.15.2 or newer (including 0.16). All checks below must pass on both versions.

## Acceptance criteria

A change is accepted only if:

- It fixes a bug or adds an improvement, reproduced by a failing test before
  the fix (red → green).
- It simplifies the code without changing behavior, by reducing lines or
  complexity.

## Lint gates

Run all of these before opening a PR:

```sh
zig build test
zig build check-imports
zig fmt --check src
zig build check --summary all
zlint --deny-warnings
zwanzig src build.zig
```

Then verify the `test/consumer/` fixture (it ships with intentionally unsorted
imports, so `check-imports` must fail on a raw checkout and pass after
`fix-imports`):

```sh
cd test/consumer
zig build
zig build fix-imports
zig build check-imports
git checkout -- src        # restore the unsorted fixture
cd ../..
```

### Installing zlint and zwanzig

Both are pre-built binaries. Pick the asset for your platform from the links
below and verify the SHA-256 before use.

[zwanzig v0.14.0](https://github.com/forketyfork/zwanzig/releases/tag/v0.14.0):

| Platform | SHA-256 |
|---|---|
| linux-x86_64 | `4667f5f0635b27362a4c9340aa971318f71e5aee778bd5302e88c008e5ce368d` |
| macos-aarch64 | `ab2059d3da4e01b716b7888c4642da3b96e1160e9c7f1bf9dbfa5085669c3d0b` |

[zlint v0.9.1](https://github.com/DonIsaac/zlint/releases/tag/v0.9.1):

| Platform | SHA-256 |
|---|---|
| linux-x86_64 | `3290bd511d37e4f6ccca3621b9894cd6c378195cdaac27520d0bd894058b2b9b` |
| macos-aarch64 | `520924b1c4898b37ed98270b0774f657729e3c9775997482c6f8f3fe75051144` |
| macos-x86_64 | `ba51351036752bcba3bf01808c24bf8eb48123e1d2ad11d7bc82c1dcc10dc30b` |

> [!NOTE]
> `// zlint-disable no-print` at the top of `src/zsort.zig` suppresses the
> lint for intentional `std.debug.print` calls in CLI output. Don't remove it.

## Commits

[Conventional commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
`chore:`), one logical change per commit.

## Pull requests

CI runs the same gates on every PR across Zig 0.15.2 and 0.16 on Linux and
macOS. Passing the checks above locally is the best way to avoid a red build.
Keep `test/consumer/` in sync when behavior changes.

## Releasing

1. Bump `.version` in both `build.zig.zon` and `src/version.zig` (the build
   fails if they differ). Add a CHANGELOG entry and update the README example
   URL.
2. Tag and push:
   ```sh
   git tag v<version> && git push origin v<version>
   ```
   This triggers the `release` workflow (cross-platform binaries) and
   `bump-tap` (Homebrew formula update).
3. Verify: the release page should have four `zsort-<target>.tar.gz` assets
   and the Homebrew tap should be updated. To re-publish, delete the release
   and run the `release` workflow manually with the tag as input.
