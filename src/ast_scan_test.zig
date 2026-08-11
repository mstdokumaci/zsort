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

test "findImportBlockEnd: alias to unimported module ends the block" {
    const source =
        \\const std = @import("std");
        \\const Enum = enums.Kind;
        \\const Other = @import("other");
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n".len, blockEndForTest(source));
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

test "analyze: alias to an alias base resolves" {
    const source =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const Allocator = mem.Allocator;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.aliases.items.len);
    for (analysis.aliases.items) |alias| {
        try std.testing.expectEqualStrings("std", alias.path);
        try std.testing.expectEqual(ast_scan.class_std_builtin, alias.class);
        try std.testing.expect(alias.member);
    }
    try std.testing.expectEqual(source.len, analysis.block_end);
}

test "analyze: multi-hop alias chain resolves" {
    const source =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const fmt = mem.fmt;
        \\const Writer = fmt.Writer;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), analysis.aliases.items.len);
    for (analysis.aliases.items) |alias| {
        try std.testing.expectEqualStrings("std", alias.path);
        try std.testing.expectEqual(ast_scan.class_std_builtin, alias.class);
    }
    try std.testing.expectEqual(source.len, analysis.block_end);
}

test "analyze: alias chain resolves regardless of decl order" {
    const source =
        \\const Allocator = mem.Allocator;
        \\const mem = std.mem;
        \\const std = @import("std");
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.aliases.items.len);
    for (analysis.aliases.items) |alias| {
        try std.testing.expectEqualStrings("std", alias.path);
        try std.testing.expectEqual(ast_scan.class_std_builtin, alias.class);
    }
    try std.testing.expectEqual(source.len, analysis.block_end);
}

test "analyze: cyclic alias chain is not collected" {
    const source =
        \\const A = B.x;
        \\const B = A.x;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: unresolvable alias is not collected" {
    const source = "const Len = Internal.len;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
}

test "analyze: alias with unresolvable base is not collected" {
    const source =
        \\const std = @import("std");
        \\const AF = system.AF;
        \\const Debug = std.debug;
    ;
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.aliases.items.len);
    try std.testing.expectEqualStrings("std", analysis.aliases.items[0].path);
    try std.testing.expectEqual("const std = @import(\"std\");\n".len, analysis.block_end);
}

test "analyze: address-of import chain collected as member import" {
    const source = "const step_list = &@import(\"root\").step_list;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.items.len);
    try std.testing.expect(analysis.imports.items[0].member);
    try std.testing.expectEqualStrings("root", analysis.imports.items[0].path);
    try std.testing.expectEqual(ast_scan.class_local, analysis.imports.items[0].class);
}

test "analyze: address-of of a local identifier is not an alias" {
    const source = "const p = &foo;\n";
    var analysis = try ast_scan.analyze(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.aliases.items.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.imports.items.len);
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
