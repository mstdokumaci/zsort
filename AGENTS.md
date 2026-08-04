Local environment might have zig, zig15, zig16 binaries, verify which one has which version before starting to work.

Lint gates: for both 0.15.2 and 0.16
- zig build test
- zig build check-imports
- zig fmt --check src
- zlint --deny-warnings
- zwanzig src build.zig
- also verify build and check-imports still work for the consumer in test/consumer
