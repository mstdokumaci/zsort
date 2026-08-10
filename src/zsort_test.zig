const std = @import("std");

const ast_scan = @import("ast_scan.zig");
const compat = @import("compat.zig");
const zsort = @import("zsort.zig");

test "hasBannedPatterns: no problems" {
    const source =
        \\const std = @import("std");
        \\const foo = @import("foo");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }));
}

test "hasBannedPatterns: ./ prefix detected" {
    const source = "const foo = @import(\"./bar\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
}

test "hasBannedPatterns: ./ prefix ignored when not listed" {
    const source = "const foo = @import(\"./bar\");\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{"src/"}));
}

test "hasBannedPatterns: src/ prefix detected only when listed" {
    const src_source = "const foo = @import(\"src/bar.zig\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, src_source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "src/") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, src_source, &.{"./"}));
}

test "hasBannedPatterns: multiple prefixes, unmatched prefix no flag" {
    const source =
        \\const std = @import("std");
        \\const foo = @import("bar.zig");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "lib/", "app/" }));
}

test "hasBannedPatterns: commented-out @import ignored" {
    const source =
        \\ // const foo = @import("bar");
        \\const std = @import("std");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }));
}

test "hasBannedPatterns: inline @import detected even without prefixes" {
    const source = "fn foo() @import(\"bar\").Type {\n}\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{}) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(line 1)") != null);
}

test "buildSortedImportText: basic sort" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\const foo = @import("foo");
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);

    const pos_std = std.mem.indexOf(u8, result, "std") orelse return error.TestUnexpectedResult;
    const pos_bar = std.mem.indexOf(u8, result, "bar") orelse return error.TestUnexpectedResult;
    const pos_foo = std.mem.indexOf(u8, result, "foo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pos_std < pos_bar);
    try std.testing.expect(pos_bar < pos_foo);
}

test "buildSortedImportText: idempotent fix twice" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
    ;
    const block_end1 = blockEndForTest(source);
    var imports1 = try collectImportsForTest(source, block_end1);
    defer imports1.deinit(std.testing.allocator);
    var aliases1 = try collectAliasesForTest(source);
    defer aliases1.deinit(std.testing.allocator);
    const pass1 = try zsort.buildSortedImportText(std.testing.allocator, source, imports1.items, aliases1.items, block_end1, false);
    defer std.testing.allocator.free(pass1);

    var full1: std.ArrayListUnmanaged(u8) = .empty;
    defer full1.deinit(std.testing.allocator);
    try full1.appendSlice(std.testing.allocator, pass1);
    try full1.appendSlice(std.testing.allocator, source[block_end1..]);

    const full1_z = try std.testing.allocator.dupeZ(u8, full1.items);
    defer std.testing.allocator.free(full1_z);
    const block_end2 = blockEndForTest(full1_z);
    var imports2 = try collectImportsForTest(full1_z, block_end2);
    defer imports2.deinit(std.testing.allocator);
    var aliases2 = try collectAliasesForTest(full1_z);
    defer aliases2.deinit(std.testing.allocator);
    const pass2 = try zsort.buildSortedImportText(std.testing.allocator, full1_z, imports2.items, aliases2.items, block_end2, false);
    defer std.testing.allocator.free(pass2);

    try std.testing.expectEqualStrings(pass1, pass2);
}

test "buildSortedImportText: comments separating groups" {
    const source =
        \\const std = @import("std");
        \\
        \\// Third-party imports
        \\const sqlite = @import("sqlite");
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "// Third-party imports") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "std") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sqlite") != null);
}

fn collectImportsForTest(source: [:0]const u8, block_end: usize) !std.ArrayListUnmanaged(ast_scan.Import) {
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    var imports: std.ArrayListUnmanaged(ast_scan.Import) = .empty;
    errdefer imports.deinit(std.testing.allocator);
    try imports.appendSlice(std.testing.allocator, analysis.imports.items);
    for (imports.items) |*imp| imp.stray = imp.start >= block_end;
    return imports;
}

fn blockEndForTest(source: [:0]const u8) usize {
    var analysis = ast_scan.analyze(std.testing.allocator, source) catch return source.len;
    defer analysis.deinit(std.testing.allocator);
    return analysis.block_end;
}

fn collectAliasesForTest(source: [:0]const u8) !std.ArrayListUnmanaged(ast_scan.Import) {
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    var aliases: std.ArrayListUnmanaged(ast_scan.Import) = .empty;
    errdefer aliases.deinit(std.testing.allocator);
    try aliases.appendSlice(std.testing.allocator, analysis.aliases.items);
    return aliases;
}

test "hasBannedPatterns: self-scan clean" {
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort.zig"), &.{ "./", "src/" }));
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort_test.zig"), &.{ "./", "src/" }));
}

test "hasBannedPatterns: backslash-prefixed lines ignored" {
    const source = "\\\\const x = @import(\"a\");\nconst std = @import(\"std\");\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{}));
}

test "processSource: hoists multiline stray import intact" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\
        \\const late = @import(
        \\    "late.zig"
        \\);
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig").? < std.mem.indexOf(u8, result.new_text, "pub fn main").?);
}

test "processSource: blank line inserted between block and body" {
    const source =
        \\pub fn main() void {}
        \\
        \\const build_options = @import("build_options");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const expected = "const build_options = @import(\"build_options\");\n\npub fn main() void {}\n";
    try std.testing.expectEqualStrings(expected, result.new_text);
}

test "processSource: clean block abutting body gains a blank line" {
    const source = "const std = @import(\"std\");\npub fn main() {}\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const expected = "const std = @import(\"std\");\n\npub fn main() {}\n";
    try std.testing.expectEqualStrings(expected, result.new_text);
}

test "processSource: no double blank when rest starts blank" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(!result.changed);
    try std.testing.expect(!result.full_diff);
}

test "processSource: excessive blanks between block and body are normalized and reported" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() {}
        \\
        \\
        \\const x = 1;
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expect(result.full_diff);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n\npub fn main() {}\n\nconst x = 1;",
        result.new_text,
    );
}

test "processSource: junction blank inserted before a CR-prefixed body line" {
    const source = "const std = @import(\"std\");\n\r pub fn main() {}\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n\n\r pub fn main() {}\n",
        result.new_text,
    );
}

test "processSource: whitespace-only separator line is treated as a blank" {
    const source = "const std = @import(\"std\");\n   \npub fn main() {}\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n\npub fn main() {}\n",
        result.new_text,
    );
}

test "processSource: doc comment stays attached to the following decl" {
    const source =
        \\const std = @import("std");
        \\/// Docs for the decl.
        \\pub fn main() {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "/// Docs for the decl.\npub fn main") != null);
}

test "processSource: division-deref is not mistaken for a block comment" {
    const source =
        \\const v = a/*b;
        \\const std = @import("std");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer if (result.changed) {
        std.testing.allocator.free(result.new_text);
        std.testing.allocator.free(result.new_block);
    };
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n\nconst v = a/*b;\n",
        result.new_text,
    );
}

test "processSource: blank line before multiline stray import does not invert slice" {
    const source =
        \\const std = @import("std");
        \\
        \\const late = @import(
        \\    "late.zig"
        \\);
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
    const std_pos = std.mem.indexOf(u8, result.new_text, "const std") orelse return error.TestUnexpectedResult;
    const late_pos = std.mem.indexOf(u8, result.new_text, "const late") orelse return error.TestUnexpectedResult;
    try std.testing.expect(late_pos > std_pos);
}

test "processSource: unterminated import at EOF terminates" {
    const source =
        \\const std = @import("std");
        \\const late = @import(
        \\    "late.zig"
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
}

test "processSource: comment above multiline stray import does not invert slice" {
    const source =
        \\const std = @import("std");
        \\// c1
        \\const late = @import(
        \\    "late.zig"
        \\);
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
}

test "processSource: import expression ending in brace terminates" {
    const source =
        \\const std = @import("std");
        \\const x = @import("a")
        \\{
        \\};
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    defer if (result.banned_msg) |msg| std.testing.allocator.free(msg);
    try std.testing.expect(result.banned);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "const x = @import"));
}

test "hasBannedPatterns: whitespace after @import( still detected" {
    const source = "const foo = @import( \"./bar\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
}

test "hasBannedPatterns: escaped path decoded before prefix check" {
    const source = "const foo = @import(\"\\x2e/bar\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{"./"}) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
}

test "processSource: collapses consecutive CRLF blank lines" {
    const source = "// h\r\n\r\n\r\nconst bar = @import(\"bar\");\r\n\r\npub fn main() {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result.new_text, "\r\n\r\n\r\n"));
}

test "processSource: skip comment leaves file untouched" {
    const source =
        \\// zsort: skip
        \\const bar = @import("bar");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqualStrings(source, result.new_text);
}

test "processSource: file-leading //! block stays at top with out-of-order imports" {
    const source =
        \\//! Module docs.
        \\//! More docs.
        \\
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "//! Module docs.\n//! More docs.\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: idempotent" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\const zz = @import("zz.zig");
    ;
    const r1 = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(r1.new_text);
    defer std.testing.allocator.free(r1.new_block);
    const r1_z = try std.testing.allocator.dupeZ(u8, r1.new_text);
    defer std.testing.allocator.free(r1_z);
    const r2 = try zsort.processSource(std.testing.allocator, r1_z, &.{}, false);
    defer std.testing.allocator.free(r2.new_text);
    defer std.testing.allocator.free(r2.new_block);
    try std.testing.expect(!r2.changed);
    try std.testing.expectEqualStrings(r1.new_text, r2.new_text);
}

test "processSource: preserves CRLF line endings" {
    const source = "const bar = @import(\"bar\");\r\nconst std = @import(\"std\");\r\n\r\npub fn main() !void {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    var prev: u8 = 0;
    for (result.new_text) |ch| {
        if (ch == '\n') try std.testing.expectEqual(@as(u8, '\r'), prev);
        prev = ch;
    }
}

test "processSource: --bottom moves the import block to the end of the file" {
    const source =
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expect(result.full_diff);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom is idempotent on an already-bottom file" {
    const source =
        \\pub fn main() !void {}
        \\
        \\const a = @import("a.zig");
        \\const b = @import("b.zig");
        \\
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqualStrings(source, result.new_text);
}

test "processSource: --bottom keeps //! docs at the top" {
    const source =
        \\//! Module docs.
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "//! Module docs.\n\npub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom collapses inter-import blank lines into one seam" {
    const source =
        \\//! Module docs.
        \\
        \\const b = @import("b.zig");
        \\
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "//! Module docs.\n\npub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom hoists mid-file strays into the bottom block" {
    const source =
        \\pub fn main() !void {}
        \\
        \\const zz = @import("zz.zig");
        \\const b = @import("b.zig");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\nconst b = @import(\"b.zig\");\nconst zz = @import(\"zz.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom attached comment travels with its import" {
    const source =
        \\pub fn main() !void {}
        \\
        \\// wasm support
        \\const w = @import("w.zig");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\n// wasm support\nconst w = @import(\"w.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom trailing comment stays with the body" {
    const source =
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\// docs for main
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "// docs for main\npub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom comment adjacent to the first import travels" {
    const source =
        \\// attached note
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\n// attached note\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom blank-separated header stays at the top" {
    const source =
        \\// header
        \\
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "// header\n\npub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom //! docs stay, adjacent note travels" {
    const source =
        \\//! Module docs.
        \\// note
        \\const b = @import("b.zig");
        \\const a = @import("a.zig");
        \\
        \\pub fn main() !void {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expectEqualStrings(
        "//! Module docs.\n\npub fn main() !void {}\n\n// note\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
}

test "processSource: --bottom preserves CRLF line endings" {
    const source = "const b = @import(\"b.zig\");\r\nconst a = @import(\"a.zig\");\r\n\r\npub fn main() !void {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\r\n\r\n" ++
            "const a = @import(\"a.zig\");\r\n" ++
            "const b = @import(\"b.zig\");\r\n",
        result.new_text,
    );
    var prev: u8 = 0;
    for (result.new_text) |ch| {
        if (ch == '\n') try std.testing.expectEqual(@as(u8, '\r'), prev);
        prev = ch;
    }
}

test "processSource: --bottom collapses blank runs left in the body by hoisted bands" {
    const source =
        \\// Server timestamp.
        \\var start_fuzzing_timestamp: i64 = undefined;
        \\
        \\pub fn main() !void {}
        \\
        \\const std = @import("std");
        \\const Walk = @import("Walk");
        \\
        \\const gpa = std.heap.wasm_allocator;
        \\const log = std.log;
        \\const String = Slice(u8);
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "// Server timestamp.\n\n" ++
            "var start_fuzzing_timestamp: i64 = undefined;\n\n" ++
            "pub fn main() !void {}\n\n" ++
            "const String = Slice(u8);\n\n" ++
            "const std = @import(\"std\");\n\n" ++
            "const Walk = @import(\"Walk\");\n\n" ++
            "const gpa = std.heap.wasm_allocator;\n" ++
            "const log = std.log;\n",
        result.new_text,
    );
}

test "processSource: --bottom is idempotent on an already-bottom banded file" {
    const source =
        \\pub fn main() !void {}
        \\
        \\const std = @import("std");
        \\const Walk = @import("Walk");
        \\
        \\const gpa = std.heap.wasm_allocator;
        \\const log = std.log;
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\n" ++
            "const std = @import(\"std\");\n\n" ++
            "const Walk = @import(\"Walk\");\n\n" ++
            "const gpa = std.heap.wasm_allocator;\n" ++
            "const log = std.log;\n",
        result.new_text,
    );
    const second_src = try std.testing.allocator.dupeZ(u8, result.new_text);
    defer std.testing.allocator.free(second_src);
    const second = try zsort.processSource(std.testing.allocator, second_src, &.{}, true);
    defer std.testing.allocator.free(second.new_text);
    defer std.testing.allocator.free(second.new_block);
    try std.testing.expect(!second.changed);
    try std.testing.expectEqualStrings(result.new_text, second.new_text);
}

test "processSource: hoisting stray bands leaves no blank runs at EOF" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\
        \\const a = @import("a.zig");
        \\
        \\const b = @import("b.zig");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n\n" ++
            "const a = @import(\"a.zig\");\n" ++
            "const b = @import(\"b.zig\");\n\n" ++
            "pub fn main() !void {}\n",
        result.new_text,
    );
}

test "processSource: --bottom normalizes a trailing blank line once, then idempotent" {
    const source = "pub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\n\nconst a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n",
        result.new_text,
    );
    const second_src = try std.testing.allocator.dupeZ(u8, result.new_text);
    defer std.testing.allocator.free(second_src);
    const second = try zsort.processSource(std.testing.allocator, second_src, &.{}, true);
    defer std.testing.allocator.free(second.new_text);
    defer std.testing.allocator.free(second.new_block);
    try std.testing.expect(!second.changed);
    try std.testing.expectEqualStrings(result.new_text, second.new_text);
}

test "processSource: --bottom collapses blank runs with CRLF line endings" {
    const source = "const std = @import(\"std\");\r\n\r\npub fn main() !void {}\r\n\r\nconst a = @import(\"a.zig\");\r\n\r\nconst b = @import(\"b.zig\");\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, true);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "pub fn main() !void {}\r\n\r\n" ++
            "const std = @import(\"std\");\r\n\r\n" ++
            "const a = @import(\"a.zig\");\r\n" ++
            "const b = @import(\"b.zig\");\r\n",
        result.new_text,
    );
    var prev: u8 = 0;
    for (result.new_text) |ch| {
        if (ch == '\n') try std.testing.expectEqual(@as(u8, '\r'), prev);
        prev = ch;
    }
}

test "walkDir: excludes cache and vcs directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try compat.makePath(compat.testIo(), tmp.dir, ".git");
    try compat.makePath(compat.testIo(), tmp.dir, ".zig-cache");
    try compat.makePath(compat.testIo(), tmp.dir, "zig-cache");
    try compat.makePath(compat.testIo(), tmp.dir, "zig-out");
    try compat.makePath(compat.testIo(), tmp.dir, "sub");
    try compat.makePath(compat.testIo(), tmp.dir, "sub/.zig-cache");
    try compat.writeFile(compat.testIo(), tmp.dir, "main.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "sub/lib.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "sub/.zig-cache/e.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, ".git/a.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, ".zig-cache/b.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "zig-cache/c.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "zig-out/d.zig", "");
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f);
        found.deinit(std.testing.allocator);
    }
    try zsort.walkDir(compat.testIo(), std.testing.allocator, tmp.dir, "tmp", &found, &.{});
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, "main.zig") or std.mem.endsWith(u8, f, "sub/lib.zig"));
    }
}

test "walkDir: respects gitignore ignores at component boundaries" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try compat.makePath(compat.testIo(), tmp.dir, "ignored");
    try compat.makePath(compat.testIo(), tmp.dir, "build-tools");
    try compat.makePath(compat.testIo(), tmp.dir, "keep");
    try compat.writeFile(compat.testIo(), tmp.dir, "ignored/a.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "build-tools/b.zig", "");
    try compat.writeFile(compat.testIo(), tmp.dir, "keep/c.zig", "");
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f);
        found.deinit(std.testing.allocator);
    }
    try zsort.walkDir(compat.testIo(), std.testing.allocator, tmp.dir, "tmp", &found, &.{ "ignored", "build" });
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, "build-tools/b.zig") or std.mem.endsWith(u8, f, "keep/c.zig"));
    }
}

test "matchesIgnore: component-boundary prefix match" {
    try std.testing.expect(zsort.matchesIgnore("build/foo.zig", "build"));
    try std.testing.expect(zsort.matchesIgnore("build", "build"));
    try std.testing.expect(zsort.matchesIgnore("build/foo.zig", "build/"));
    try std.testing.expect(zsort.matchesIgnore("a/zig-out/b.zig", "zig-out"));
    try std.testing.expect(!zsort.matchesIgnore("build-tools/x.zig", "build"));
    try std.testing.expect(!zsort.matchesIgnore("buildings.zig", "build"));
    try std.testing.expect(!zsort.matchesIgnore("x", "y"));
    try std.testing.expect(!zsort.matchesIgnore("x", "/"));
    try std.testing.expect(zsort.matchesIgnore("a\\build\\b.zig", "build"));
    try std.testing.expect(!zsort.matchesIgnore("a\\build-tools\\x.zig", "build"));
    try std.testing.expect(zsort.matchesIgnore("build\\foo.zig", "build"));
    try std.testing.expect(zsort.matchesIgnore("a\\build\\b.zig", "build/"));
}

test "loadGitignore: parses patterns, skips comments and unsupported entries" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try compat.writeFile(compat.testIo(), tmp.dir, ".gitignore", "# comment\n.zig-cache\nbuild/\n\n*.tmp\n!keep\nnode_modules\n  spaced  \n");
    const ignores = try zsort.loadGitignore(compat.testIo(), std.testing.allocator, tmp.dir);
    defer {
        for (ignores) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(ignores);
    }
    try std.testing.expectEqual(@as(usize, 4), ignores.len);
    try std.testing.expectEqualStrings(".zig-cache", ignores[0]);
    try std.testing.expectEqualStrings("build/", ignores[1]);
    try std.testing.expectEqualStrings("node_modules", ignores[2]);
    try std.testing.expectEqualStrings("spaced", ignores[3]);
}

test "loadGitignore: missing file yields empty list" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ignores = try zsort.loadGitignore(compat.testIo(), std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(ignores);
    try std.testing.expectEqual(@as(usize, 0), ignores.len);
}

test "formatUnifiedDiff: local reorder with context" {
    const old = "const bar = @import(\"bar\");\nconst std = @import(\"std\");\n\nconst rest = 1;\n";
    const new = "const std = @import(\"std\");\nconst bar = @import(\"bar\");\n\nconst rest = 1;\n";
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "test.zig", old, new, false);
    defer std.testing.allocator.free(diff);
    const expected = "  --- test.zig\n" ++
        "  +++ test.zig\n" ++
        "  @@ -1,2 +1,2 @@\n" ++
        "  - const bar = @import(\"bar\");\n" ++
        "  - const std = @import(\"std\");\n" ++
        "  + const std = @import(\"std\");\n" ++
        "  + const bar = @import(\"bar\");\n" ++
        "   \n" ++
        "   const rest = 1;\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, diff);
}

test "formatUnifiedDiff: whole-file replace" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "x\ny\n", false);
    defer std.testing.allocator.free(diff);
    const expected = "  --- t.zig\n" ++
        "  +++ t.zig\n" ++
        "  @@ -1,2 +1,2 @@\n" ++
        "  - a\n" ++
        "  - b\n" ++
        "  + x\n" ++
        "  + y\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, diff);
}

test "formatUnifiedDiff: CRLF input diffs cleanly" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\r\nb\r\n", "a\r\nc\r\n", false);
    defer std.testing.allocator.free(diff);
    const expected = "  --- t.zig\n" ++
        "  +++ t.zig\n" ++
        "  @@ -2,1 +2,1 @@\n" ++
        "   a\n" ++
        "  - b\n" ++
        "  + c\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, diff);
}

test "formatUnifiedDiff: trailing-newline difference emits marker" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "a\nb", false);
    defer std.testing.allocator.free(diff);
    try std.testing.expectEqualStrings(
        "  --- t.zig\n" ++
            "  +++ t.zig\n" ++
            "  (trailing newline only)\n" ++
            "\n",
        diff,
    );
}

test "formatUnifiedDiff: colorized git-style when enabled" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "x\ny\n", true);
    defer std.testing.allocator.free(diff);
    const expected = "  \x1b[31m--- t.zig\x1b[0m\n" ++
        "  \x1b[32m+++ t.zig\x1b[0m\n" ++
        "  \x1b[36m@@ -1,2 +1,2 @@\x1b[0m\n" ++
        "  \x1b[31m- a\x1b[0m\n" ++
        "  \x1b[31m- b\x1b[0m\n" ++
        "  \x1b[32m+ x\x1b[0m\n" ++
        "  \x1b[32m+ y\x1b[0m\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, diff);
}

test "formatUnifiedDiff: trailing-newline marker is dimmed when colored" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "a\nb", true);
    defer std.testing.allocator.free(diff);
    try std.testing.expectEqualStrings(
        "  \x1b[31m--- t.zig\x1b[0m\n" ++
            "  \x1b[32m+++ t.zig\x1b[0m\n" ++
            "  \x1b[2m(trailing newline only)\x1b[0m\n" ++
            "\n",
        diff,
    );
}

test "formatUnifiedDiff: ESC bytes in file_path are escaped, not injected" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "\x1b[31mEVE\x1b[0m.zig", "a\n", "b\n", false);
    defer std.testing.allocator.free(diff);
    try std.testing.expect(std.mem.indexOfScalar(u8, diff, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\\x1b[31mEVE\\x1b[0m.zig") != null);
}

test "formatUnifiedDiff: control bytes in diff body are escaped, not injected" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\x1b[31mB\x07C\x08D\x0dE\n", "x\n", false);
    defer std.testing.allocator.free(diff);
    for ([_]u8{ 0x1b, 0x07, 0x08, 0x0d }) |byte| {
        try std.testing.expect(std.mem.indexOfScalar(u8, diff, byte) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, diff, "\\x1b[31mB\\x07C\\x08D\\x0dE") != null);
}

test "formatUnifiedDiff: CR, LF, BEL, BS in file_path are escaped, not injected" {
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "a\x0db\x0ac\x07d\x08e.zig", "a\n", "b\n", false);
    defer std.testing.allocator.free(diff);
    for ([_]u8{ 0x0d, 0x07, 0x08 }) |byte| {
        try std.testing.expect(std.mem.indexOfScalar(u8, diff, byte) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, diff, "a\\x0db\\x0ac\\x07d\\x08e.zig") != null);
}

test "escapeTerm: allocation failure propagates, never returns raw input" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, zsort.escapeTerm(fa.allocator(), "\x1b"));
}

test "escapeTerm: clean input returns unchanged without allocating" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const s = "plain.zig";
    try std.testing.expectEqualStrings(s, try zsort.escapeTerm(fa.allocator(), s));
}

test "collectImports: classes and sorted order" {
    const source =
        \\const local = @import("foo.zig");
        \\const std = @import("std");
        \\const sqlite = @import("sqlite");
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqual(ast_scan.class_std_builtin, imports.items[0].class);
    try std.testing.expectEqualStrings("std", imports.items[0].path);
    try std.testing.expectEqual(ast_scan.class_third_party, imports.items[1].class);
    try std.testing.expectEqualStrings("sqlite", imports.items[1].path);
    try std.testing.expectEqual(ast_scan.class_local, imports.items[2].class);
    try std.testing.expectEqualStrings("foo.zig", imports.items[2].path);
}

test "buildSortedImportText: comment travels with its import" {
    const source =
        \\// header
        \\const bar = @import("bar");
        \\// std comment
        \\const std = @import("std");
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const std_pos = std.mem.indexOf(u8, result, "const std") orelse return error.TestUnexpectedResult;
    const bar_pos = std.mem.indexOf(u8, result, "const bar") orelse return error.TestUnexpectedResult;
    const comment_pos = std.mem.indexOf(u8, result, "// std comment") orelse return error.TestUnexpectedResult;
    try std.testing.expect(comment_pos < std_pos);
    try std.testing.expect(std_pos < bar_pos);
}

test "buildSortedImportText: blank-line-separated comment travels with its import" {
    const source =
        \\const bar = @import("bar");
        \\// std comment
        \\
        \\const std = @import("std");
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const std_pos = std.mem.indexOf(u8, result, "const std") orelse return error.TestUnexpectedResult;
    const comment_pos = std.mem.indexOf(u8, result, "// std comment") orelse return error.TestUnexpectedResult;
    try std.testing.expect(comment_pos < std_pos);
}

test "buildSortedImportText: alias imports hoisted after imports" {
    const source =
        \\const bar = @import("bar");
        \\const Debug = std.debug;
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const bar_pos = std.mem.indexOf(u8, result, "const bar") orelse return error.TestUnexpectedResult;
    const debug_pos = std.mem.indexOf(u8, result, "const Debug = std.debug;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bar_pos < debug_pos);
}

test "buildSortedImportText: @This() sorts first in the alias band" {
    const source =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const IP = @This();
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const expected = "const std = @import(\"std\");\n\nconst IP = @This();\nconst Io = std.Io;\n\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "buildSortedImportText: full band order with members and aliases" {
    const source =
        \\const std = @import("std");
        \\const Sqlite = @import("sqlite").Sqlite;
        \\const bar = @import("bar");
        \\const Local = @import("local.zig").Local;
        \\const Debug = std.debug;
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const expected =
        \\const std = @import("std");
        \\
        \\const bar = @import("bar");
        \\const Sqlite = @import("sqlite").Sqlite;
        \\
        \\const Local = @import("local.zig").Local;
        \\
        \\const Debug = std.debug;
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "buildSortedImportText: README example sorts as documented" {
    const source =
        \\const std = @import("std");
        \\const httpz = @import("httpz");
        \\const auth = @import("auth.zig");
        \\const Router = @import("router.zig").Router;
        \\const Config = auth.Config;
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const expected =
        \\const std = @import("std");
        \\
        \\const httpz = @import("httpz");
        \\
        \\const auth = @import("auth.zig");
        \\const Router = @import("router.zig").Router;
        \\
        \\const Config = auth.Config;
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "buildSortedImportText: aliases sorted by resolved path" {
    const source =
        \\const connection_state = @import("connection/state.zig");
        \\const connection_manager = @import("connection/manager.zig");
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const Connection = connection_state.Connection;
        \\const ConnectionManager = connection_manager.ConnectionManager;
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const expected =
        \\const std = @import("std");
        \\
        \\const connection_manager = @import("connection/manager.zig");
        \\const connection_state = @import("connection/state.zig");
        \\
        \\const Allocator = std.mem.Allocator;
        \\const ConnectionManager = connection_manager.ConnectionManager;
        \\const Connection = connection_state.Connection;
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "processSource: hoisted stray import lands in its group" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\
        \\const late = @import("late.zig");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const std_pos = std.mem.indexOf(u8, result.new_text, "const std") orelse return error.TestUnexpectedResult;
    const bar_pos = std.mem.indexOf(u8, result.new_text, "const bar") orelse return error.TestUnexpectedResult;
    const late_pos = std.mem.indexOf(u8, result.new_text, "const late") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std_pos < bar_pos);
    try std.testing.expect(bar_pos < late_pos);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "pub fn main") != null);
}

test "processSource: alias stranded below block is hoisted into the alias band" {
    const source =
        \\const std = @import("std");
        \\const log = std.log.scoped(.x);
        \\const Allocator = std.mem.Allocator;
        \\
        \\pub fn main() {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const std_pos = std.mem.indexOf(u8, result.new_text, "const std") orelse return error.TestUnexpectedResult;
    const alloc_pos = std.mem.indexOf(u8, result.new_text, "const Allocator") orelse return error.TestUnexpectedResult;
    const log_pos = std.mem.indexOf(u8, result.new_text, "const log") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std_pos < alloc_pos);
    try std.testing.expect(alloc_pos < log_pos);
}

test "processSource: blank above hoisted stray import is preserved" {
    const source =
        \\const std = @import("std");
        \\const log = std.log.scoped(.x);
        \\
        \\const late = @import("late.zig");
        \\
        \\pub fn main() {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "const log = std.log.scoped(.x);\n\npub fn main") != null);
}

test "processSource: output independent of input order" {
    const forward =
        \\const std = @import("std");
        \\const MessageHandler = @import("message_handler.zig").MessageHandler;
        \\const bar = @import("bar");
        \\const connection_state = @import("connection/state.zig");
        \\
        \\const Connection = connection_state.Connection;
        \\const A = @import("x");
        \\const B = @import("x");
        \\
        \\pub fn main() {}
    ;
    const backward =
        \\const B = @import("x");
        \\const A = @import("x");
        \\const Connection = connection_state.Connection;
        \\
        \\const connection_state = @import("connection/state.zig");
        \\const bar = @import("bar");
        \\const MessageHandler = @import("message_handler.zig").MessageHandler;
        \\const std = @import("std");
        \\
        \\pub fn main() {}
    ;
    const r1 = try zsort.processSource(std.testing.allocator, forward, &.{}, false);
    defer std.testing.allocator.free(r1.new_text);
    defer std.testing.allocator.free(r1.new_block);
    const r2 = try zsort.processSource(std.testing.allocator, backward, &.{}, false);
    defer std.testing.allocator.free(r2.new_text);
    defer std.testing.allocator.free(r2.new_block);
    try std.testing.expectEqualStrings(r1.new_text, r2.new_text);
}

test "processSource: stray member import hoisted into member band" {
    const source =
        \\const bar = @import("bar");
        \\
        \\pub fn main() !void {}
        \\
        \\const Thing = @import("thing.zig").Thing;
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const bar_pos = std.mem.indexOf(u8, result.new_text, "const bar") orelse return error.TestUnexpectedResult;
    const thing_pos = std.mem.indexOf(u8, result.new_text, "const Thing") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bar_pos < thing_pos);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "pub fn main") != null);
}

test "hasBannedPatterns: nested re-export import not banned" {
    const source =
        \\const lib = struct {
        \\    pub const http = @import("httpz");
        \\};
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{}));
}

test "hasBannedPatterns: dotted import alias not banned" {
    const source = "const Allocator = @import(\"std\").heap.ArenaAllocator;\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{}));
}

test "hasBannedPatterns: typed import with banned prefix detected" {
    const source = "const x: T = @import(\"./bar\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{"./"}) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(line 1)") != null);
}

test "hasBannedPatterns: message includes the offending line number" {
    const source =
        \\const std = @import("std");
        \\
        \\const bar = @import("./bar");
    ;
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{"./"}) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(line 3)") != null);
}

test "processSource: typed import hoisted and sorted" {
    const source =
        \\const bar = @import("bar");
        \\const x: SomeType = @import("a");
        \\
        \\pub fn main() {}
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const a_pos = std.mem.indexOf(u8, result.new_text, "const x: SomeType") orelse return error.TestUnexpectedResult;
    const bar_pos = std.mem.indexOf(u8, result.new_text, "const bar") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < bar_pos);
}

test "processSource: trailing comment on multiline import travels" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() {}
        \\
        \\const late = @import(
        \\    "late.zig"
        \\); // late comment
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const late_pos = std.mem.indexOf(u8, result.new_text, "const late") orelse return error.TestUnexpectedResult;
    const joined_pos = std.mem.indexOf(u8, result.new_text, "); // late comment") orelse return error.TestUnexpectedResult;
    const main_pos = std.mem.indexOf(u8, result.new_text, "pub fn main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(joined_pos > late_pos);
    try std.testing.expect(joined_pos < main_pos);
}

test "processSource: cimport block kept intact" {
    const source =
        \\const c = @cImport({
        \\    #include <stdio.h>
        \\}); // c trailing
        \\const rest = 1;
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const expected =
        \\const c = @cImport({
        \\    #include <stdio.h>
        \\}); // c trailing
        \\
        \\const rest = 1;
    ;
    try std.testing.expectEqualStrings(expected, result.new_text);
}

test "processSource: stray cimport hoisted" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() {}
        \\const c = @cImport({
        \\    #include <x.h>
        \\});
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    const c_pos = std.mem.indexOf(u8, result.new_text, "const c = @cImport") orelse return error.TestUnexpectedResult;
    const main_pos = std.mem.indexOf(u8, result.new_text, "pub fn main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c_pos < main_pos);
}

test "processSource: comment-only file unchanged" {
    const source = "// just comments\n// more\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{}, false);
    defer if (result.changed) {
        std.testing.allocator.free(result.new_text);
        std.testing.allocator.free(result.new_block);
    };
    try std.testing.expect(!result.changed);
    try std.testing.expectEqualStrings(source, result.new_text);
}

test "buildSortedImportText: comment above alias travels" {
    const source =
        \\const bar = @import("bar");
        \\// Debug alias
        \\const Debug = std.debug;
        \\
        \\const rest = 1;
    ;
    const block_end = blockEndForTest(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    var aliases = try collectAliasesForTest(source);
    defer aliases.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, aliases.items, block_end, false);
    defer std.testing.allocator.free(result);
    const comment_pos = std.mem.indexOf(u8, result, "// Debug alias") orelse return error.TestUnexpectedResult;
    const debug_pos = std.mem.indexOf(u8, result, "const Debug") orelse return error.TestUnexpectedResult;
    try std.testing.expect(comment_pos < debug_pos);
}

test "parseArgs: check mode with prefixes" {
    var msg: ?[]const u8 = null;
    const args = [_][]const u8{ "zsort", "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args, &msg);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .check);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.items.len);
    try std.testing.expectEqualStrings("src", parsed.targets.items[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.banned_prefixes.items.len);
    try std.testing.expectEqualStrings("./", parsed.banned_prefixes.items[0]);
    try std.testing.expectEqualStrings("src/", parsed.banned_prefixes.items[1]);
}

test "parseArgs: fix mode" {
    var msg: ?[]const u8 = null;
    const args = [_][]const u8{ "zsort", "fix", "tools" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args, &msg);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .fix);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.items.len);
    try std.testing.expectEqualStrings("tools", parsed.targets.items[0]);
    try std.testing.expectEqual(@as(usize, 0), parsed.banned_prefixes.items.len);
}

test "parseArgs: help and version flags" {
    var msg: ?[]const u8 = null;
    var help = try zsort.parseArgs(std.testing.allocator, &.{ "zsort", "--help" }, &msg);
    defer help.deinit(std.testing.allocator);
    try std.testing.expect(help.help);
    try std.testing.expect(!help.version);

    var version = try zsort.parseArgs(std.testing.allocator, &.{ "zsort", "--version" }, &msg);
    defer version.deinit(std.testing.allocator);
    try std.testing.expect(version.version);
    try std.testing.expect(!version.help);
}

test "parseArgs: errors" {
    var msg: ?[]const u8 = null;
    defer if (msg) |m| std.testing.allocator.free(m);

    try std.testing.expectError(error.Usage, zsort.parseArgs(std.testing.allocator, &.{"zsort"}, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "Missing mode and target") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.Usage, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "Missing target") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.InvalidMode, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "fixx", "src" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "fixx") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.MissingBanValue, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--ban-prefix" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "requires a value") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.UnexpectedArg, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--bogus" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "Unknown option") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "--bogus") != null);
}

test "parseArgs: multiple targets" {
    var msg: ?[]const u8 = null;
    const args = [_][]const u8{ "zsort", "check", "src", "tools", "src/main.zig" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args, &msg);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .check);
    try std.testing.expectEqual(@as(usize, 3), parsed.targets.items.len);
    try std.testing.expectEqualStrings("src", parsed.targets.items[0]);
    try std.testing.expectEqualStrings("tools", parsed.targets.items[1]);
    try std.testing.expectEqualStrings("src/main.zig", parsed.targets.items[2]);
    try std.testing.expectEqual(@as(usize, 0), parsed.banned_prefixes.items.len);
}

test "parseArgs: --bottom flag accepted in both modes" {
    var msg: ?[]const u8 = null;
    defer if (msg) |m| std.testing.allocator.free(m);

    var check = try zsort.parseArgs(std.testing.allocator, &.{ "zsort", "--bottom", "check", "src" }, &msg);
    defer check.deinit(std.testing.allocator);
    try std.testing.expect(check.mode == .check);
    try std.testing.expect(check.bottom);

    var fix = try zsort.parseArgs(std.testing.allocator, &.{ "zsort", "fix", "src", "--bottom", "--ban-prefix", "./" }, &msg);
    defer fix.deinit(std.testing.allocator);
    try std.testing.expect(fix.mode == .fix);
    try std.testing.expect(fix.bottom);
    try std.testing.expectEqual(@as(usize, 1), fix.banned_prefixes.items.len);

    try std.testing.expectError(error.UnexpectedArg, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--bottomx" }, &msg));
}

test "formatSummary: check mode, plain without color" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 1,
        .errors = 2,
        .banned = 0,
        .files = 179,
        .elapsed_ns = 12 * std.time.ns_per_ms,
    }, .check, false) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("  Found 1 of 179 files to fix, 2 failed in 12ms.\n", s);
}

test "formatSummary: fix mode, plain without color" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 0,
        .errors = 0,
        .banned = 0,
        .files = 179,
        .elapsed_ns = 500_000,
    }, .fix, false) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\n  Fixed 0 of 179 files in 0ms.\n", s);
}

test "formatSummary: colorized per-category numbers, sub-ms truncates to 0ms" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 0,
        .errors = 0,
        .banned = 0,
        .files = 179,
        .elapsed_ns = 500_000,
    }, .check, true) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("  Found \x1b[33m0\x1b[0m of \x1b[33m179\x1b[0m files to fix in \x1b[33m0\x1b[0mms.\n", s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[") != null);
}

test "formatSummary: no escape bytes when color disabled" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 0,
        .errors = 0,
        .banned = 0,
        .files = 1,
        .elapsed_ns = 0,
    }, .check, false) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[") == null);
}

test "formatSummary: single-file target uses singular 'file'" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 1,
        .errors = 0,
        .banned = 0,
        .files = 1,
        .elapsed_ns = 2 * std.time.ns_per_ms,
    }, .check, false) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("  Found 1 of 1 file to fix in 2ms.\n", s);
}

test "formatSummary: banned-only segment shown, failed omitted" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 1,
        .errors = 0,
        .banned = 3,
        .files = 4,
        .elapsed_ns = 0,
    }, .check, true) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("  Found \x1b[33m1\x1b[0m of \x1b[33m4\x1b[0m files to fix, \x1b[35m3\x1b[0m banned in \x1b[33m0\x1b[0mms.\n", s);
}

test "formatSummary: failed and banned segments both shown in order" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 1,
        .errors = 2,
        .banned = 3,
        .files = 4,
        .elapsed_ns = 5 * std.time.ns_per_ms,
    }, .check, false) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("  Found 1 of 4 files to fix, 2 failed, 3 banned in 5ms.\n", s);
}
