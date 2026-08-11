//! Import/alias discovery over `std.zig.Ast`, replacing the previous
//! hand-rolled scanner. Tolerates malformed input the same way it did:
//! parse errors never stop collection (error recovery drops broken decls),
//! invalid tokens reset at the next newline, and plain `//` comments emit
//! no tokens so they are invisible to every rule here.

const std = @import("std");

const Ast = std.zig.Ast;

pub const class_std_builtin: u2 = 0;
pub const class_third_party: u2 = 1;
pub const class_local: u2 = 2;

pub const Import = struct {
    start: usize,
    end: usize,
    /// Resolved import path; for aliases, the full resolved dotted chain.
    path: []const u8,
    class: u2,
    stray: bool = false,
    comment_start: ?usize = null,
    /// const name of the decl (`connection_state`); aliases resolve against
    /// these names to find their module's import path.
    name: []const u8 = "",
    /// True for `@import("p").Foo` chains: sorted after plain imports within
    /// the same class, keyed by the base path `p`.
    member: bool = false,
    /// Full decl text (`source[start..end]`); final sort tiebreak so the
    /// output never depends on input order.
    text: []const u8 = "",
    /// False when the base name is neither an import nor a resolved alias
    /// (a local decl); such aliases are dropped from the band.
    resolved: bool = true,

    fn lessThan(ctx: void, a: Import, b: Import) bool {
        _ = ctx;
        if (a.class != b.class) return a.class < b.class;
        if (a.member != b.member) return !a.member;
        const cmp = std.mem.order(u8, a.path, b.path);
        if (cmp != .eq) return cmp == .lt;
        return std.mem.order(u8, a.text, b.text) == .lt;
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
        const prev_trimmed = std.mem.trim(u8, source[prev_start..prev_end], " \t\r\n");
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

pub const Analysis = struct {
    imports: std.ArrayListUnmanaged(Import) = .empty,
    aliases: std.ArrayListUnmanaged(Import) = .empty,
    block_end: usize = 0,
    /// Every `@import` call in the tree (offset + path), for banned checks.
    calls: std.ArrayListUnmanaged(ImportCall) = .empty,
    /// Offsets of `calls` that head a `const` decl initializer (not inline).
    allowed: std.ArrayListUnmanaged(usize) = .empty,
    /// Decoded import paths that no longer slice into `source` (escaped
    /// literals), freed by deinit.
    owned_paths: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        for (self.owned_paths.items) |p| allocator.free(p);
        self.owned_paths.deinit(allocator);
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
/// into it (or into `Analysis.owned_paths` for escaped literals), so both
/// must outlive the analysis.
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
        const found = if (vd) |decl| try classifyDecl(allocator, &result.owned_paths, tree, source, node, decl) else null;
        if (found) |f| {
            if (f.alias) {
                try result.aliases.append(allocator, f.imp);
            } else {
                try result.imports.append(allocator, f.imp);
            }
        }
    }

    result.block_end = lineBlockEnd(source, result.imports.items, result.aliases.items);

    result.calls = try importCalls(allocator, &result.owned_paths, tree);
    result.allowed = try collectAllowedOffsets(allocator, tree);

    // Resolve alias bases to full dotted chains via import/alias names so
    // the alias band sorts by chain. Container consts are order-independent,
    // so this iterates to a fixed point; unresolvable bases are dropped.
    for (result.aliases.items) |*alias| {
        if (std.mem.indexOfScalar(u8, alias.path, '.') != null) alias.resolved = false;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (result.aliases.items) |*alias| {
            if (alias.resolved) continue;
            const dot = std.mem.indexOfScalar(u8, alias.path, '.');
            const base = if (dot) |d| alias.path[0..d] else alias.path;
            const suffix = if (dot) |d| alias.path[d..] else "";
            for (result.imports.items) |imp| {
                if (std.mem.eql(u8, imp.name, base)) {
                    alias.path = try std.mem.concat(allocator, u8, &.{ imp.path, suffix });
                    try result.owned_paths.append(allocator, alias.path);
                    alias.class = classify(imp.path);
                    alias.resolved = true;
                    changed = true;
                    break;
                }
            }
            if (alias.resolved) continue;
            for (result.aliases.items) |*other| {
                if (other.resolved and std.mem.eql(u8, other.name, base)) {
                    alias.path = try std.mem.concat(allocator, u8, &.{ other.path, suffix });
                    try result.owned_paths.append(allocator, alias.path);
                    alias.class = other.class;
                    alias.resolved = true;
                    changed = true;
                    break;
                }
            }
        }
    }
    var alias_i: usize = 0;
    while (alias_i < result.aliases.items.len) {
        if (!result.aliases.items[alias_i].resolved) {
            _ = result.aliases.swapRemove(alias_i);
        } else alias_i += 1;
    }

    // Dropping unresolvable aliases may shorten the block region.
    result.block_end = lineBlockEnd(source, result.imports.items, result.aliases.items);

    // Aliases below the block are marked stray so they can be hoisted into
    // the alias band, mirroring how stray imports are hoisted.
    for (result.aliases.items) |*alias| alias.stray = alias.start >= result.block_end;

    for (result.imports.items) |*imp| imp.stray = imp.start >= result.block_end;
    std.sort.pdq(Import, result.imports.items, {}, Import.lessThan);
    std.sort.pdq(Import, result.aliases.items, {}, Import.lessThan);
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
    while (tree.nodeTag(cur) == .address_of) {
        cur = tree.nodeData(cur).node;
    }
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
const ImportCall = struct {
    offset: usize,
    path: ?[]const u8,
};

fn importCalls(allocator: std.mem.Allocator, owned: *std.ArrayListUnmanaged([]const u8), tree: Ast) !std.ArrayListUnmanaged(ImportCall) {
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
            .path = if (arg) |a| try stringPath(allocator, owned, tree, a) else null,
        });
    }
    return calls;
}

// zwanzig-disable-next-line: unused-parameter
// zwanzig-disable-next-line: unused-parameter
fn classifyDecl(allocator: std.mem.Allocator, owned: *std.ArrayListUnmanaged([]const u8), tree: Ast, source: []const u8, node: Ast.Node.Index, vd: Ast.full.VarDecl) !?Found {
    if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return null;
    const init = vd.ast.init_node.unwrap() orelse return null;
    const start = declStart(tree, node);
    const end = spanEnd(tree, source, node);
    const text = source[start..end];
    // The name token always immediately follows `const`; token-based so
    // whitespace between modifiers and name (tabs, doubled spaces) is moot.
    const name = tree.tokenSlice(vd.ast.mut_token + 1);
    const comment_start = findCommentStart(source, findLineStart(source, start));

    // Base of a dotted chain: `@import("a").Foo` → the `@import` call.
    // `&` wraps member chains (`&@import("root").step_list`) to reference
    // a decl of the imported module; peel it so the chain is recognized.
    var base = init;
    var member = false;
    while (tree.nodeTag(base) == .address_of) {
        base = tree.nodeData(base).node;
    }
    while (tree.nodeTag(base) == .field_access) {
        base = tree.nodeData(base).node_and_token[0];
        member = true;
    }

    const base_slice = tree.tokenSlice(tree.firstToken(base));
    if (std.mem.eql(u8, base_slice, "@import") or std.mem.eql(u8, base_slice, "@cImport")) {
        const is_cimport = std.mem.eql(u8, base_slice, "@cImport");
        const path, const cls = if (is_cimport)
            .{ "<cimport>", class_third_party }
        else blk: {
            const arg = builtinArg(tree, base) orelse return null;
            const p = (try stringPath(allocator, owned, tree, arg)) orelse return null;
            break :blk .{ p, classify(p) };
        };
        return .{ .imp = .{
            .start = start,
            .end = end,
            .path = path,
            .class = cls,
            .comment_start = comment_start,
            .name = name,
            .member = member,
            .text = text,
        }, .alias = false };
    }

    if (std.mem.eql(u8, base_slice, "@This") and !member) {
        // `const X = @This();` references the current module, so it has no
        // resolvable path; the sentinel sorts it first in the alias band.
        return .{ .imp = .{
            .start = start,
            .end = end,
            .path = "@This()",
            .class = class_std_builtin,
            .comment_start = comment_start,
            .name = name,
            .text = text,
        }, .alias = true };
    }

    if (tree.nodeTag(init) == .identifier) {
        // Direct alias to an import or alias name (`const B = A;`): the
        // fixed-point resolver below rewrites the path to its target's
        // resolved chain, or drops it if the base never resolves.
        return .{ .imp = .{
            .start = start,
            .end = end,
            .path = base_slice,
            .class = classify(base_slice),
            .comment_start = comment_start,
            .name = name,
            .resolved = false,
            .text = text,
        }, .alias = true };
    }

    if (member and isAliasChain(tree, init)) {
        const first = tree.firstToken(init);
        const last = tree.lastToken(init);
        const chain = source[tree.tokens.items(.start)[first] .. tree.tokens.items(.start)[last] + @as(u32, @intCast(tree.tokenSlice(last).len))];
        const dot = std.mem.indexOfScalar(u8, chain, '.') orelse return null;
        return .{ .imp = .{
            .start = start,
            .end = end,
            .path = chain,
            .class = classify(chain[0..dot]),
            .comment_start = comment_start,
            .name = name,
            .member = member,
            .text = text,
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

/// Path of a string-literal argument: the raw token body when it contains no
/// escapes, otherwise the decoded contents stored in `owned`. Returns null
/// for non-string or invalid (multiline) literals.
fn stringPath(allocator: std.mem.Allocator, owned: *std.ArrayListUnmanaged([]const u8), tree: Ast, arg: Ast.Node.Index) !?[]const u8 {
    if (tree.nodeTag(arg) != .string_literal) return null;
    const lit = tree.tokenSlice(tree.firstToken(arg));
    if (lit.len < 2) return null;
    const body = lit[1 .. lit.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
    if (lit[0] != '"' or lit[lit.len - 1] != '"') return null;
    const decoded = std.zig.string_literal.parseAlloc(allocator, lit) catch return null;
    try owned.append(allocator, decoded);
    return decoded;
}

/// Single-line, whitespace-free dotted chain starting with an identifier:
/// `std.debug`, `a.b.c`. Anything else (spaced dots, multi-line chains,
/// `@import("a").Foo` — a member import, postfix calls and index access) is
/// not an alias.
fn isAliasChain(tree: Ast, init: Ast.Node.Index) bool {
    const first = tree.firstToken(init);
    const last = tree.lastToken(init);
    if (tree.tokens.items(.tag)[first] != .identifier) return false;
    if (!tree.tokensOnSameLine(first, last)) return false;
    var t = first;
    while (t < last) : (t += 1) {
        const tag = tree.tokens.items(.tag)[t];
        if (tag != .identifier and tag != .period) return false;
        const end = tree.tokens.items(.start)[t] + @as(u32, @intCast(tree.tokenSlice(t).len));
        if (end != tree.tokens.items(.start)[t + 1]) return false;
    }
    return true;
}

fn declStart(tree: Ast, node: Ast.Node.Index) usize {
    return tree.tokens.items(.start)[tree.firstToken(node)];
}

/// End of an import/alias span: the `;` immediately following the decl's
/// last token (decl nodes exclude it), then to the end of that line so
/// trailing inline comments travel with the import. A missing `;` ends the
/// span at the last token's line instead of crossing into a later decl.
fn spanEnd(tree: Ast, source: []const u8, node: Ast.Node.Index) usize {
    const last_node_token = tree.lastToken(node);
    const next = last_node_token + 1;
    if (next < tree.tokens.len and tree.tokens.items(.tag)[next] == .semicolon) {
        return findLineEnd(source, tree.tokens.items(.start)[next]);
    }
    return findLineEnd(source, tree.tokens.items(.start)[last_node_token] + @as(u32, @intCast(tree.tokenSlice(last_node_token).len)));
}
