const std = @import("std");

const zsort = @import("zsort.zig");

test "classify: std/builtin" {
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("std"));
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("builtin"));
}

test "classify: third-party modules" {
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("sqlite"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("msgpack"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("httpx"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("foo"));
}

test "classify: local" {
    try std.testing.expectEqual(zsort.class_local, zsort.classify("foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("subdir/foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("./foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("../foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("root"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("build_root"));
}

test "extractPath: normal" {
    try std.testing.expectEqualStrings("bar", zsort.extractPath("@import(\"bar\")", "@import(").?);
}

test "extractPath: null on malformed" {
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.extractPath("@import(bar)", "@import("));
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.extractPath("noimport", "@import("));
}

test "isTopLevelImportLine: basic import" {
    try std.testing.expect(zsort.isTopLevelImportLine("const std = @import(\"std\");\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("pub const foo = @import(\"foo\");\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("_ = @import(\"bar\");\n"));
}

test "isTopLevelImportLine: semicolon terminated alias" {
    try std.testing.expect(zsort.isTopLevelImportLine("const Payload = msgpack.Payload;\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const Debug = std.debug;\n"));
}

test "isTopLevelImportLine: alias to struct-like module name" {
    try std.testing.expect(zsort.isTopLevelImportLine("const Enum = enums.Kind;\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const Union = unions.Kind;\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const Opaque = opaques.Handle;\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const Structs = structs.Kind;\n"));
}

test "isTopLevelImportLine: trailing type-keyword comment on import line" {
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // = struct\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // = enum\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // = union\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // = opaque\n"));
}

test "isTopLevelImportLine: not import lines" {
    try std.testing.expect(!zsort.isTopLevelImportLine("const S = struct {\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("const E = enum {\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("pub fn main() !void {\n"));
}

test "isTopLevelImportLine: comments and empty lines" {
    try std.testing.expect(zsort.isTopLevelImportLine("// some comment\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("  \t\n"));
}

test "findImportBlockEnd: ends at first non-import" {
    const source =
        \\const std = @import("std");
        \\
        \\const Foo = struct {
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, zsort.findImportBlockEnd(source));
}

test "findImportBlockEnd: alias to struct-like module does not end block" {
    const source =
        \\const std = @import("std");
        \\const Enum = enums.Kind;
        \\const Other = @import("other");
    ;
    try std.testing.expectEqual(
        "const std = @import(\"std\");\nconst Enum = enums.Kind;\nconst Other = @import(\"other\");".len,
        zsort.findImportBlockEnd(source),
    );
}

test "findCImportEnd: basic block" {
    const source =
        \\const c = @cImport({
        \\    int x = 1;
        \\});
        \\
        \\const rest = 42;
    ;
    const cimport_pos = std.mem.indexOf(u8, source, "@cImport(") orelse return error.TestFailed;
    const end = zsort.findCImportEnd(source, cimport_pos);
    try std.testing.expect(end > cimport_pos);
    try std.testing.expect(std.mem.indexOf(u8, source[end..], "const rest") != null);
}

test "findCImportEnd: braces in strings ignored" {
    const source =
        \\const c = @cImport({
        \\    printf("{ hello }");
        \\});
        \\
        \\const rest = 42;
    ;
    const cimport_pos = std.mem.indexOf(u8, source, "@cImport(") orelse return error.TestFailed;
    const end = zsort.findCImportEnd(source, cimport_pos);
    try std.testing.expect(end > cimport_pos);
    try std.testing.expect(std.mem.indexOf(u8, source[end..], "const rest") != null);
}

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
}

test "buildSortedImportText: basic sort" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\const foo = @import("foo");
        \\
        \\const rest = 1;
    ;
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
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
    const block_end1 = zsort.findImportBlockEnd(source);
    var imports1 = try collectImportsForTest(source, block_end1);
    defer imports1.deinit(std.testing.allocator);
    const pass1 = try zsort.buildSortedImportText(std.testing.allocator, source, imports1.items, block_end1);
    defer std.testing.allocator.free(pass1);

    var full1: std.ArrayListUnmanaged(u8) = .empty;
    defer full1.deinit(std.testing.allocator);
    try full1.appendSlice(std.testing.allocator, pass1);
    try full1.appendSlice(std.testing.allocator, source[block_end1..]);

    const block_end2 = zsort.findImportBlockEnd(full1.items);
    var imports2 = try collectImportsForTest(full1.items, block_end2);
    defer imports2.deinit(std.testing.allocator);
    const pass2 = try zsort.buildSortedImportText(std.testing.allocator, full1.items, imports2.items, block_end2);
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
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "// Third-party imports") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "std") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sqlite") != null);
}

fn collectImportsForTest(source: []const u8, block_end: usize) !std.ArrayListUnmanaged(zsort.Import) {
    return zsort.collectImports(std.testing.allocator, source, block_end);
}

test "hasBannedPatterns: self-scan clean" {
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort.zig"), &.{ "./", "src/" }));
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort_test.zig"), &.{ "./", "src/" }));
}

test "hasBannedPatterns: backslash-prefixed lines ignored" {
    const source = "\\\\const x = @import(\"a\");\nconst std = @import(\"std\");\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try zsort.hasBannedPatterns(std.testing.allocator, source, &.{}));
}

test "collectImports: braces in multiline-string line don't affect depth" {
    const source = "\\\\const a = struct {\nconst real = @import(\"real.zig\");\n";
    var imports = try zsort.collectImports(std.testing.allocator, source, 0);
    defer imports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqualStrings("real.zig", imports.items[0].path);
}

test "isTopLevelImportLine: unterminated lines are not import lines" {
    try std.testing.expect(!zsort.isTopLevelImportLine("const Allocator = std.mem\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("const x = @import(\"a\")\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // comment\n"));
}

test "findImportBlockEnd: stops before unterminated alias line" {
    const source =
        \\const std = @import("std");
        \\
        \\const Allocator = std.mem
        \\    .Allocator;
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, zsort.findImportBlockEnd(source));
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig").? < std.mem.indexOf(u8, result.new_text, "pub fn main").?);
}

test "processSource: division-deref is not mistaken for a block comment" {
    const source =
        \\const v = a/*b;
        \\const std = @import("std");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer if (result.changed) {
        std.testing.allocator.free(result.new_text);
        std.testing.allocator.free(result.new_block);
    };
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nconst v = a/*b;\n",
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(!result.changed);
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "const x = @import"));
}

test "hasBannedPatterns: whitespace after @import( still detected" {
    const source = "const foo = @import( \"./bar\");\n";
    const msg = try zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
}

test "processSource: collapses consecutive CRLF blank lines" {
    const source = "// h\r\n\r\n\r\nconst bar = @import(\"bar\");\r\n\r\npub fn main() {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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
    const r1 = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(r1.new_text);
    defer std.testing.allocator.free(r1.new_block);
    const r2 = try zsort.processSource(std.testing.allocator, r1.new_text, &.{});
    defer std.testing.allocator.free(r2.new_text);
    defer std.testing.allocator.free(r2.new_block);
    try std.testing.expect(!r2.changed);
    try std.testing.expectEqualStrings(r1.new_text, r2.new_text);
}

test "processSource: preserves CRLF line endings" {
    const source = "const bar = @import(\"bar\");\r\nconst std = @import(\"std\");\r\n\r\npub fn main() !void {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    var prev: u8 = 0;
    for (result.new_text) |ch| {
        if (ch == '\n') try std.testing.expectEqual(@as(u8, '\r'), prev);
        prev = ch;
    }
}

test "walkDir: excludes cache and vcs directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath(".git");
    try tmp.dir.makePath(".zig-cache");
    try tmp.dir.makePath("zig-cache");
    try tmp.dir.makePath("zig-out");
    try tmp.dir.makePath("sub");
    try tmp.dir.makePath("sub/.zig-cache");
    try tmp.dir.writeFile(.{ .sub_path = "main.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "sub/lib.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "sub/.zig-cache/e.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = ".git/a.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = ".zig-cache/b.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-cache/c.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/d.zig", .data = "" });
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f);
        found.deinit(std.testing.allocator);
    }
    try zsort.walkDir(std.testing.allocator, tmp.dir, "tmp", &found, &.{});
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, "main.zig") or std.mem.endsWith(u8, f, "sub/lib.zig"));
    }
}

test "walkDir: respects gitignore ignores at component boundaries" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("ignored");
    try tmp.dir.makePath("build-tools");
    try tmp.dir.makePath("keep");
    try tmp.dir.writeFile(.{ .sub_path = "ignored/a.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "build-tools/b.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "keep/c.zig", .data = "" });
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f);
        found.deinit(std.testing.allocator);
    }
    try zsort.walkDir(std.testing.allocator, tmp.dir, "tmp", &found, &.{ "ignored", "build" });
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
    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "# comment\n.zig-cache\nbuild/\n\n*.tmp\n!keep\nnode_modules\n  spaced  \n",
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const ignores = try zsort.loadGitignore(std.testing.allocator, root);
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
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const ignores = try zsort.loadGitignore(std.testing.allocator, root);
    defer std.testing.allocator.free(ignores);
    try std.testing.expectEqual(@as(usize, 0), ignores.len);
}

test "formatUnifiedDiff: local reorder with context" {
    const old = "const bar = @import(\"bar\");\nconst std = @import(\"std\");\n\nconst rest = 1;\n";
    const new = "const std = @import(\"std\");\nconst bar = @import(\"bar\");\n\nconst rest = 1;\n";
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "test.zig", old, new);
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
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "x\ny\n");
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
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\r\nb\r\n", "a\r\nc\r\n");
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
    const diff = try zsort.formatUnifiedDiff(std.testing.allocator, "t.zig", "a\nb\n", "a\nb");
    defer std.testing.allocator.free(diff);
    try std.testing.expectEqualStrings(
        "  --- t.zig\n" ++
            "  +++ t.zig\n" ++
            "  (trailing newline only)\n" ++
            "\n",
        diff,
    );
}

test "collectImports: classes and sorted order" {
    const source =
        \\const local = @import("foo.zig");
        \\const std = @import("std");
        \\const sqlite = @import("sqlite");
        \\
        \\const rest = 1;
    ;
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqual(zsort.class_std_builtin, imports.items[0].class);
    try std.testing.expectEqualStrings("std", imports.items[0].path);
    try std.testing.expectEqual(zsort.class_third_party, imports.items[1].class);
    try std.testing.expectEqualStrings("sqlite", imports.items[1].path);
    try std.testing.expectEqual(zsort.class_local, imports.items[2].class);
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
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
    defer std.testing.allocator.free(result);
    const std_pos = std.mem.indexOf(u8, result, "const std") orelse return error.TestUnexpectedResult;
    const bar_pos = std.mem.indexOf(u8, result, "const bar") orelse return error.TestUnexpectedResult;
    const comment_pos = std.mem.indexOf(u8, result, "// std comment") orelse return error.TestUnexpectedResult;
    try std.testing.expect(comment_pos < std_pos);
    try std.testing.expect(std_pos < bar_pos);
}

test "buildSortedImportText: alias imports hoisted after imports" {
    const source =
        \\const bar = @import("bar");
        \\const Debug = std.debug;
        \\
        \\const rest = 1;
    ;
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);
    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
    defer std.testing.allocator.free(result);
    const bar_pos = std.mem.indexOf(u8, result, "const bar") orelse return error.TestUnexpectedResult;
    const debug_pos = std.mem.indexOf(u8, result, "const Debug = std.debug;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bar_pos < debug_pos);
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
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
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

test "parseArgs: check mode with prefixes" {
    var msg: ?[]const u8 = null;
    const args = [_][]const u8{ "zsort", "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args, &msg);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .check);
    try std.testing.expectEqualStrings("src", parsed.target);
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
    try std.testing.expectEqualStrings("tools", parsed.target);
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
    try std.testing.expectError(error.Usage, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check" }, &msg));

    try std.testing.expectError(error.InvalidMode, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "fixx", "src" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "fixx") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.MissingBanValue, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--ban-prefix" }, &msg));

    try std.testing.expectError(error.UnexpectedArg, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "extra" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "extra") != null);
    std.testing.allocator.free(msg.?);
    msg = null;

    try std.testing.expectError(error.UnexpectedArg, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--bogus" }, &msg));
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "unknown option") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "--bogus") != null);
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
    try std.testing.expectEqualStrings("\t1 needs fixing, 2 errors, 0 banned across 179 files in 12ms.\n", s);
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
    try std.testing.expectEqualStrings("\n\tFixed 0 files, 0 errors, 0 banned across 179 files in 0ms.\n", s);
}

test "formatSummary: colorized numbers, sub-ms truncates to 0ms" {
    const s = zsort.formatSummary(std.testing.allocator, .{
        .changed = 0,
        .errors = 0,
        .banned = 0,
        .files = 179,
        .elapsed_ns = 500_000,
    }, .check, true) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\t\x1b[33m0\x1b[39m needs fixing, \x1b[33m0\x1b[39m errors, \x1b[33m0\x1b[39m banned across \x1b[33m179\x1b[39m files in \x1b[33m0\x1b[39mms.\n", s);
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
