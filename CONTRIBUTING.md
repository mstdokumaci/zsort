# Contributing

Thanks for considering a contribution to zsort. The project is small and
intentionally simple — please open an issue before sending a pull request so
the change can be discussed first.

## Requirements

- Zig **0.15.2 or newer** (Zig 0.16 is supported). Verify your local Zig
  version before starting; the lint gates below run against both 0.15.2 and
  0.16.

## Acceptance criteria

A change is accepted only if:

- **it fixes a bug or implements an improvement** — reproduced by a failing
  test before fixing (test → red → fix → green), or
- **it simplifies the code** without changing behavior, by reducing lines of
  code or complexity.

## Local verification

Run all of these against both Zig 0.15.2 and 0.16 before opening a PR:

```sh
zig build test
zig build check-imports    # run zsort on its own source (dogfood)
zig fmt --check src
zig build check --summary all
cd test/consumer && zig build && zig build check-imports && cd ..
```

## Linting

Linting uses [zwanzig](https://github.com/forketyfork/zwanzig) and
[zlint](https://github.com/DonIsaac/zlint), both run directly as pre-built
binaries — there is no build step for them. Install both pinned versions and
verify each download against its trusted SHA-256 before use:

```sh
# zwanzig v0.14.0 — pick the asset for your platform, then verify:
#   linux-x86_64:  sha256 4667f5f0635b27362a4c9340aa971318f71e5aee778bd5302e88c008e5ce368d
#   macos-aarch64: sha256 ab2059d3da4e01b716b7888c4642da3b96e1160e9c7f1bf9dbfa5085669c3d0b
#   windows-x86_64: sha256 2b7fd8e3a027f3f7a9a4e1519a6cca66ce4f01ba214c0a854bc0ccb09d5c320d
curl -fsSL -o /tmp/zwanzig.tar.gz \
  "https://github.com/forketyfork/zwanzig/releases/download/v0.14.0/zwanzig-v0.14.0-macos-aarch64.tar.gz"
echo "ab2059d3da4e01b716b7888c4642da3b96e1160e9c7f1bf9dbfa5085669c3d0b  /tmp/zwanzig.tar.gz" | shasum -a 256 -c -
mkdir -p /tmp/zwanzig
tar -xzf /tmp/zwanzig.tar.gz -C /tmp/zwanzig
sudo mv /tmp/zwanzig/zwanzig /usr/local/bin/zwanzig

zwanzig src build.zig
```

The zwanzig commands above are POSIX-only; on Windows, verify the zip with its
sha256 and place the extracted `zwanzig.exe` on your PATH.

```sh
# zlint v0.9.1 — pick the asset for your platform, then verify:
#   linux-x86_64:  sha256 3290bd511d37e4f6ccca3621b9894cd6c378195cdaac27520d0bd894058b2b9b
#   macos-aarch64: sha256 520924b1c4898b37ed98270b0774f657729e3c9775997482c6f8f3fe75051144
#   macos-x86_64:  sha256 ba51351036752bcba3bf01808c24bf8eb48123e1d2ad11d7bc82c1dcc10dc30b
curl -fsSL -o /tmp/zlint \
  "https://github.com/DonIsaac/zlint/releases/download/v0.9.1/zlint-macos-aarch64"
echo "520924b1c4898b37ed98270b0774f657729e3c9775997482c6f8f3fe75051144  /tmp/zlint" | shasum -a 256 -c -
chmod +x /tmp/zlint
sudo mv /tmp/zlint /usr/local/bin/zlint

zlint --deny-warnings
```

Note: `// zlint-disable no-print` at the top of `src/zsort.zig` is a zlint
file-level disable for the intentional `std.debug.print` calls that produce
CLI output — it is not dead code and must not be removed.

## Commits

Use [conventional commits](https://www.conventionalcommits.org/) (e.g.
`feat:`, `fix:`, `chore:`), one logical change per commit.

## Pull requests

CI runs the same gates on every PR (lint chain plus the test matrix across
0.15.2 and 0.16 on Linux and macOS), so passing the local verification above
is the best way to avoid a failing run. Please keep the `test/consumer/`
fixture project in sync when behavior changes — it exercises zsort as a
real package dependency.
