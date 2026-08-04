//! Import/alias discovery over `std.zig.Ast`, replacing the previous
//! hand-rolled scanner. Tolerates malformed input the same way it did:
//! parse errors never stop collection (error recovery drops broken decls),
//! invalid tokens reset at the next newline, and plain `//` comments emit
//! no tokens so they are invisible to every rule here.

const std = @import("std");

pub const class_std_builtin: u2 = 0;
pub const class_third_party: u2 = 1;
pub const class_local: u2 = 2;

pub const Import = struct {
    start: usize,
    end: usize,
    path: []const u8,
    class: u2,
    stray: bool = false,
    comment_start: ?usize = null,

    fn lessThan(ctx: void, a: Import, b: Import) bool {
        _ = ctx;
        if (a.class != b.class) return a.class < b.class;
        const cmp = std.mem.order(u8, a.path, b.path);
        if (cmp != .eq) return cmp == .lt;
        const a_len = a.end - a.start;
        const b_len = b.end - b.start;
        if (a_len != b_len) return a_len < b_len;
        return a.start < b.start;
    }
};

pub fn classify(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin")) {
        return class_std_builtin;
    }
    if (std.mem.eql(u8, path, "root") or std.mem.eql(u8, path, "build_root") or
        std.mem.indexOfScalar(u8, path, '/') != null or
        std.mem.endsWith(u8, path, ".zig"))
    {
        return class_local;
    }
    return class_third_party;
}

pub fn findLineStart(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return i;
    }
    return 0;
}

pub fn findLineEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') return i + 1;
    }
    return source.len;
}

pub fn findCommentStart(source: []const u8, line_start: usize) ?usize {
    if (line_start == 0) return null;
    var comment_start: ?usize = null;
    var back = line_start - 1;
    while (true) {
        const prev_start = findLineStart(source, back);
        const prev_end = findLineEnd(source, prev_start);
        const prev_trimmed = std.mem.trimStart(u8, source[prev_start..prev_end], " \t\r");
        if (prev_trimmed.len == 0 or std.mem.startsWith(u8, prev_trimmed, "//")) {
            comment_start = prev_start;
            if (prev_start == 0) return null;
            back = prev_start - 1;
        } else {
            break;
        }
    }
    return comment_start;
}

const Ast = std.zig.Ast;

pub const Analysis = struct {
    imports: std.ArrayListUnmanaged(Import) = .empty,
    aliases: std.ArrayListUnmanaged(Import) = .empty,
    block_end: usize = 0,
    /// Every `@import` call in the tree (offset + path), for banned checks.
    calls: std.ArrayListUnmanaged(ImportCall) = .empty,
    /// Offsets of `calls` that head a `const` decl initializer (not inline).
    allowed: std.ArrayListUnmanaged(usize) = .empty,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.imports.deinit(allocator);
        self.aliases.deinit(allocator);
        self.calls.deinit(allocator);
        self.allowed.deinit(allocator);
    }
};

const Found = struct {
    imp: Import,
    alias: bool,
};

/// `source` must be sentinel-terminated; returned `Import.path` slices point
/// into it, so it must outlive the analysis.
pub fn analyze(allocator: std.mem.Allocator, source: [:0]const u8) !Analysis {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var result: Analysis = .{};
    errdefer result.deinit(allocator);

    for (tree.rootDecls()) |node| {
        const vd: ?Ast.full.VarDecl = switch (tree.nodeTag(node)) {
            .simple_var_decl => tree.simpleVarDecl(node),
            .global_var_decl => tree.globalVarDecl(node),
            .aligned_var_decl => tree.alignedVarDecl(node),
            else => null,
        };
        const found = if (vd) |decl| classifyDecl(tree, source, node, decl) else null;
        if (found) |f| {
            if (f.alias) {
                try result.aliases.append(allocator, f.imp);
            } else {
                try result.imports.append(allocator, f.imp);
            }
        }
    }

    result.block_end = lineBlockEnd(source, result.imports.items, result.aliases.items);

    result.calls = try importCalls(allocator, tree);
    result.allowed = try collectAllowedOffsets(allocator, tree);

    // Aliases outside the block are left alone (never hoisted).
    var j: usize = 0;
    while (j < result.aliases.items.len) {
        if (result.aliases.items[j].start >= result.block_end) {
            _ = result.aliases.orderedRemove(j);
        } else {
            j += 1;
        }
    }

    for (result.imports.items) |*imp| imp.stray = imp.start >= result.block_end;
    std.sort.pdq(Import, result.imports.items, {}, Import.lessThan);
    return result;
}

/// Offsets of every `@import` call that heads a `const` declaration's
/// initializer, at any nesting depth (direct call or leading dotted chain).
fn collectAllowedOffsets(allocator: std.mem.Allocator, tree: Ast) !std.ArrayListUnmanaged(usize) {
    var allowed: std.ArrayListUnmanaged(usize) = .empty;
    errdefer allowed.deinit(allocator);
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const vd: ?Ast.full.VarDecl = switch (tree.nodeTag(node)) {
            .simple_var_decl => tree.simpleVarDecl(node),
            .local_var_decl => tree.localVarDecl(node),
            .global_var_decl => tree.globalVarDecl(node),
            .aligned_var_decl => tree.alignedVarDecl(node),
            else => null,
        };
        const decl = vd orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token), "const")) continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        if (importHeadOffset(tree, init)) |off| try allowed.append(allocator, off);
    }
    return allowed;
}

/// Offset of the `@import` call heading `init`: `@import("a")` itself, or the
/// base of a dotted chain like `@import("a").Foo.Bar`.
fn importHeadOffset(tree: Ast, init: Ast.Node.Index) ?usize {
    var cur = init;
    while (tree.nodeTag(cur) == .field_access) {
        cur = tree.nodeData(cur).node_and_token[0];
    }
    switch (tree.nodeTag(cur)) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(cur)), "@import")) return null;
    return tree.tokens.items(.start)[tree.firstToken(cur)];
}

/// The import block ends at the first line that is not blank, a comment, or
/// covered by a collected import/alias span. Line-based rather than
/// decl-based so decls the parser dropped under error recovery (unterminated
/// calls, missing semicolons) are preserved verbatim as trailing text
/// instead of being swallowed by the rebuilt block.
fn lineBlockEnd(source: []const u8, imports: []const Import, aliases: []const Import) usize {
    var pos: usize = 0;
    while (pos < source.len) {
        const le = findLineEnd(source, pos);
        const trimmed = std.mem.trimStart(u8, source[pos..le], " \t\n\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            pos = le;
            continue;
        }
        var covered = false;
        for (imports) |imp| {
            if (pos < imp.end and imp.start < le) {
                covered = true;
                break;
            }
        }
        if (!covered) for (aliases) |a| {
            if (pos < a.end and a.start < le) {
                covered = true;
                break;
            }
        };
        if (!covered) return pos;
        pos = le;
    }
    return pos;
}

/// Every `@import` builtin call in the tree, with its source offset and path
/// (when the argument is a plain string literal). Drives banned-pattern
/// detection; offsets match `tree.source`.
pub const ImportCall = struct {
    offset: usize,
    path: ?[]const u8,
};

pub fn importCalls(allocator: std.mem.Allocator, tree: Ast) !std.ArrayListUnmanaged(ImportCall) {
    var calls: std.ArrayListUnmanaged(ImportCall) = .empty;
    errdefer calls.deinit(allocator);

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const tag = tree.nodeTag(node);
        if (tag != .builtin_call and tag != .builtin_call_comma and
            tag != .builtin_call_two and tag != .builtin_call_two_comma) continue;
        const name = tree.tokenSlice(tree.firstToken(node));
        if (!std.mem.eql(u8, name, "@import")) continue;
        const arg = builtinArg(tree, node);
        try calls.append(allocator, .{
            .offset = tree.tokens.items(.start)[tree.firstToken(node)],
            .path = if (arg) |a| stringPath(tree, a) else null,
        });
    }
    return calls;
}

fn classifyDecl(tree: Ast, source: []const u8, node: Ast.Node.Index, vd: Ast.full.VarDecl) ?Found {
    if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return null;
    const init = vd.ast.init_node.unwrap() orelse return null;
    const init_slice = tree.tokenSlice(tree.firstToken(init));
    const start = declStart(tree, node);

    if (std.mem.eql(u8, init_slice, "@import") or std.mem.eql(u8, init_slice, "@cImport")) {
        const is_cimport = std.mem.eql(u8, init_slice, "@cImport");
        const path, const cls = if (is_cimport)
            .{ "<cimport>", class_third_party }
        else blk: {
            const arg = builtinArg(tree, init) orelse return null;
            const p = stringPath(tree, arg) orelse return null;
            break :blk .{ p, classify(p) };
        };
        return .{ .imp = .{
            .start = start,
            .end = spanEnd(tree, source, node),
            .path = path,
            .class = cls,
            .comment_start = findCommentStart(source, findLineStart(source, start)),
        }, .alias = false };
    }

    if (tree.nodeTag(init) == .field_access and isAliasChain(tree, init)) {
        const first = tree.firstToken(init);
        const last = tree.lastToken(init);
        const path = source[tree.tokens.items(.start)[first] .. tree.tokens.items(.start)[last] + @as(u32, @intCast(tree.tokenSlice(last).len))];
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
        return .{ .imp = .{
            .start = start,
            .end = spanEnd(tree, source, node),
            .path = path,
            .class = classify(path[0..dot]),
            .comment_start = findCommentStart(source, findLineStart(source, start)),
        }, .alias = true };
    }

    return null;
}

/// First argument node of a `builtin_call_two`-family call; zero-arg and
/// comma-less variants have no argument.
fn builtinArg(tree: Ast, call: Ast.Node.Index) ?Ast.Node.Index {
    const args = switch (tree.nodeTag(call)) {
        .builtin_call_two, .builtin_call_two_comma => tree.nodeData(call).opt_node_and_opt_node,
        else => return null,
    };
    return args[0].unwrap();
}

fn stringPath(tree: Ast, arg: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(arg) != .string_literal) return null;
    const lit = tree.tokenSlice(tree.firstToken(arg));
    if (lit.len < 2) return null;
    return lit[1 .. lit.len - 1];
}

/// Single-line, whitespace-free dotted chain starting with an identifier:
/// `std.debug`, `a.b.c`. Anything else (spaced dots, multi-line chains,
/// `@import("a").Foo`, postfix calls) stops the block, like the old
/// alphanumeric-dot line check did.
fn isAliasChain(tree: Ast, init: Ast.Node.Index) bool {
    const first = tree.firstToken(init);
    const last = tree.lastToken(init);
    if (tree.tokens.items(.tag)[first] != .identifier) return false;
    if (!tree.tokensOnSameLine(first, last)) return false;
    var t = first;
    while (t < last) : (t += 1) {
        const end = tree.tokens.items(.start)[t] + @as(u32, @intCast(tree.tokenSlice(t).len));
        if (end != tree.tokens.items(.start)[t + 1]) return false;
    }
    return true;
}

fn declStart(tree: Ast, node: Ast.Node.Index) usize {
    return tree.tokens.items(.start)[tree.firstToken(node)];
}

/// End of an import/alias span: decl nodes exclude the trailing `;`, so
/// extend to the next `;` token, then to the end of that line so trailing
/// inline comments travel with the import.
fn spanEnd(tree: Ast, source: []const u8, node: Ast.Node.Index) usize {
    const eof_idx = tree.tokens.len - 1;
    const last_node_token = tree.lastToken(node);
    var t: u32 = last_node_token;
    while (t < eof_idx) : (t += 1) {
        if (tree.tokens.items(.tag)[t] == .semicolon) {
            return findLineEnd(source, tree.tokens.items(.start)[t]);
        }
        // Do not cross into a later declaration.
        if (t > last_node_token and !tree.tokensOnSameLine(last_node_token, t)) break;
    }
    const last = if (t > 0) t - 1 else 0;
    return findLineEnd(source, tree.tokens.items(.start)[last] + @as(u32, @intCast(tree.tokenSlice(last).len)));
}
