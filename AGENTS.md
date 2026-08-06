Local environment might have zig, zig15, zig16 binaries, verify which one has which version before starting to work (`zig version`).

Lint gates: for both 0.15.2 and 0.16
- `zig build test`
- `zig build check-imports`
- `zig fmt --check src`
- `zlint --deny-warnings`
- `zwanzig src build.zig`
- `(cd test/consumer || exit 1; git diff --quiet -- src || exit 1; trap 'git checkout -- src' EXIT; zig build && zig build fix-imports && zig build check-imports)` (the fixture is deliberately unsorted; check-imports must fail on a raw checkout)

When a new issue or improvement is reported, we accept it only if:
- it can be reproduced by a failing test before fixing (test → red → fix → green)
- it will simplify the code without changing the behaviour, either by reducing LOC or complexity
