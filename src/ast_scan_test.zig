const std = @import("std");

const ast_scan = @import("ast_scan.zig");

test "classify: std/builtin" {
    try std.testing.expectEqual(ast_scan.class_std_builtin, ast_scan.classify("std"));
    try std.testing.expectEqual(ast_scan.class_std_builtin, ast_scan.classify("builtin"));
}

test "classify: third-party modules" {
    try std.testing.expectEqual(ast_scan.class_third_party, ast_scan.classify("sqlite"));
    try std.testing.expectEqual(ast_scan.class_third_party, ast_scan.classify("msgpack"));
    try std.testing.expectEqual(ast_scan.class_third_party, ast_scan.classify("httpx"));
    try std.testing.expectEqual(ast_scan.class_third_party, ast_scan.classify("foo"));
}

test "classify: local" {
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("foo.zig"));
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("subdir/foo.zig"));
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("./foo.zig"));
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("../foo.zig"));
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("root"));
    try std.testing.expectEqual(ast_scan.class_local, ast_scan.classify("build_root"));
}

test "findImportBlockEnd: ends at first non-import" {
    const source =
        \\const std = @import("std");
        \\
        \\const Foo = struct {
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, blockEndForTest(source));
}

test "findImportBlockEnd: alias to struct-like module does not end block" {
    const source =
        \\const std = @import("std");
        \\const Enum = enums.Kind;
        \\const Other = @import("other");
    ;
    try std.testing.expectEqual(
        "const std = @import(\"std\");\nconst Enum = enums.Kind;\nconst Other = @import(\"other\");".len,
        blockEndForTest(source),
    );
}

test "collectImports: braces in multiline-string line don't affect depth" {
    const source = "\\\\const a = struct {\nconst real = @import(\"real.zig\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.items.len);
    try std.testing.expectEqualStrings("real.zig", analysis.imports.items[0].path);
}

test "findImportBlockEnd: stops before unterminated alias line" {
    const source =
        \\const std = @import("std");
        \\
        \\const Allocator = std.mem
        \\    .Allocator;
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, blockEndForTest(source));
}

test "analyze: typed import is collected" {
    const source = "const x: SomeType = @import(\"a\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.items.len);
    try std.testing.expectEqualStrings("a", analysis.imports.items[0].path);
}

test "analyze: member import collected with base path" {
    const source =
        \\const Foo = @import("a/b.zig").Foo;
        \\const Sqlite = @import("sqlite").Sqlite;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.imports.items.len);
    try std.testing.expect(analysis.imports.items[0].member);
    try std.testing.expectEqualStrings("sqlite", analysis.imports.items[0].path);
    try std.testing.expectEqual(ast_scan.class_third_party, analysis.imports.items[0].class);
    try std.testing.expect(analysis.imports.items[1].member);
    try std.testing.expectEqualStrings("a/b.zig", analysis.imports.items[1].path);
    try std.testing.expectEqual(ast_scan.class_local, analysis.imports.items[1].class);
}

test "analyze: chained member import path is base" {
    const source = "const Foo = @import(\"a.zig\").Foo.Bar;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.items.len);
    try std.testing.expect(analysis.imports.items[0].member);
    try std.testing.expectEqualStrings("a.zig", analysis.imports.items[0].path);
}

test "analyze: alias resolves to import path" {
    const source =
        \\const connection_state = @import("connection/state.zig");
        \\const Connection = connection_state.Connection;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("connection/state.zig", analysis.aliases.items[0].path);
    try std.testing.expectEqual(ast_scan.class_local, analysis.aliases.items[0].class);
}

test "analyze: alias to std resolves to std" {
    const source =
        \\const std = @import("std");
        \\const Debug = std.debug;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("std", analysis.aliases.items[0].path);
    try std.testing.expectEqual(ast_scan.class_std_builtin, analysis.aliases.items[0].class);
}

test "analyze: alias to member import resolves" {
    const source =
        \\const MessageHandler = @import("message_handler.zig").MessageHandler;
        \\const Config = MessageHandler.Config;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("message_handler.zig", analysis.aliases.items[0].path);
}

test "analyze: unresolvable alias keeps chain text" {
    const source = "const Len = Internal.len;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("Internal.len", analysis.aliases.items[0].path);
}

test "analyze: call-result chain is not an alias" {
    const source = "const Config = factory().Config;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: index-access chain is not an alias" {
    const source = "const Config = items[0].Config;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: alias resolves with tab-separated decl name" {
    const source = "const\tx = @import(\"a\");\nconst Y = x.Y;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("a", analysis.aliases.items[0].path);
}

test "analyze: escaped import path is decoded" {
    const source = "const foo = @import(\"\\x2ffoo.zig\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.items.len);
    try std.testing.expectEqualStrings("/foo.zig", analysis.imports.items[0].path);
    try std.testing.expectEqual(ast_scan.class_local, analysis.imports.items[0].class);
}

test "analyze: escaped paths sort by decoded text" {
    const source = "const first = @import(\"\\x7a\");\nconst second = @import(\"\\x61\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.imports.items.len);
    try std.testing.expectEqualStrings("a", analysis.imports.items[0].path);
    try std.testing.expectEqualStrings("z", analysis.imports.items[1].path);
}

test "analyze: var import is not collected" {
    const source = "var x = @import(\"a\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: bare underscore import is not collected" {
    const source = "_ = @import(\"x\");\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: spaced-dot alias stops the block" {
    const source = "const std = @import(\"std\");\nconst Debug = std . debug;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual("const std = @import(\"std\");\n".len, analysis.block_end);
}

test "analyze: @This() decl collected as alias" {
    const source = "const IP = @This();\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("@This()", analysis.aliases.items[0].path);
    try std.testing.expect(!analysis.aliases.items[0].member);
    try std.testing.expectEqual(ast_scan.class_std_builtin, analysis.aliases.items[0].class);
}

test "analyze: @This() member chain is not an alias" {
    const source = "const Foo = @This().Foo;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: alias after the block is marked stray" {
    const source =
        \\const std = @import("std");
        \\pub fn main() {}
        \\const Debug = std.debug;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expect(analysis.aliases.items[0].stray);
}

test "analyze: nested re-export import is not collected" {
    const source =
        \\const lib = struct {
        \\    pub const http = @import("httpz");
        \\};
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

fn blockEndForTest(source: [:0]const u8) usize {
    var analysis = ast_scan.analyze(std.testing.allocator, source) catch return source.len;
    defer analysis.deinit(std.testing.allocator);
    return analysis.block_end;
}
