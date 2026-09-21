//! Fixture consumer project: imports are deliberately unsorted so CI can
//! prove that `zig build fix-imports` rewrites them and `zig build
//! check-imports` rejects the dirty state.
// zlint-disable unused-decls -- `ignored` exists to exercise --remove-unused

const local = @import("local.zig");
const ignored = @import("local.zig");
const zsort = @import("zsort");
const std = @import("std");
const builtin = @import("builtin");

pub fn main() void {
    _ = local;
    _ = zsort;
    _ = std;
    _ = builtin;
}
