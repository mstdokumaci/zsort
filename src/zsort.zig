// zlint-disable no-print

const std = @import("std");

const compat = @import("compat.zig");

pub const version = "0.1.0";

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

fn skipStringOrComment(source: []const u8, pos: usize) usize {
    const ch = source[pos];
    if (ch == '"' or ch == '\'') {
        var i = pos + 1;
        while (i < source.len and source[i] != ch) : (i += 1) {
            if (source[i] == '\\') i += 1;
        }
        return @min(i + 1, source.len);
    }
    if (ch == '/' and pos + 1 < source.len) {
        if (source[pos + 1] == '/') {
            var i = pos + 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            return @min(i + 1, source.len);
        }
    }
    if (ch == '\\' and pos + 1 < source.len and source[pos + 1] == '\\') {
        var k = pos;
        while (k > 0 and source[k - 1] != '\n') : (k -= 1) {
            if (source[k - 1] != ' ' and source[k - 1] != '\t') break;
        }
        if (k == 0 or source[k - 1] == '\n') {
            var i = pos + 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            return @min(i + 1, source.len);
        }
    }
    return pos;
}

fn findLineStart(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return i;
    }
    return 0;
}

fn findLineEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') return i + 1;
    }
    return source.len;
}

fn findCommentStart(source: []const u8, line_start: usize) ?usize {
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

pub fn findCImportEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    var depth: usize = 0;
    var started = false;
    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        if (source[i] == '{') {
            started = true;
            depth += 1;
        } else if (source[i] == '}') {
            if (!started) break;
            depth -= 1;
            if (depth == 0) {
                while (i + 1 < source.len and source[i + 1] != '\n') : (i += 1) {}
                if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
                return i + 1;
            }
        }
        i += 1;
    }
    return findLineEnd(source, pos);
}

pub fn extractPath(source: []const u8, needle: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, source, needle) orelse return null;
    var open = pos + needle.len;
    while (open < source.len and
        (source[open] == ' ' or source[open] == '\t' or source[open] == '\r' or source[open] == '\n')) : (open += 1)
    {}
    if (open >= source.len) return null;
    const close = std.mem.indexOfScalar(u8, source[open..], ')') orelse return null;
    const inner = source[open .. open + close];
    if (inner.len == 0) return null;
    if (inner[0] == '"') {
        const e = std.mem.indexOfScalar(u8, inner[1..], '"') orelse return null;
        return inner[1 .. 1 + e];
    }
    return null;
}

fn endsWithSemicolon(trimmed: []const u8) bool {
    var t = trimmed;
    if (std.mem.indexOf(u8, t, "//")) |c| t = t[0..c];
    t = std.mem.trimEnd(u8, t, " \t\r\n");
    return t.len > 0 and t[t.len - 1] == ';';
}

// only the first token after = is a type keyword; trailing comment/string text must not count
fn hasTypeKeyword(trimmed: []const u8, keyword: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const rhs = std.mem.trimStart(u8, trimmed[eq + 1 ..], " \t");
    if (!std.mem.startsWith(u8, rhs, keyword)) return false;
    const after = keyword.len;
    return after >= rhs.len or
        (!std.ascii.isAlphanumeric(rhs[after]) and rhs[after] != '_');
}

pub fn isTopLevelImportLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t\n\r");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "//")) return true;

    if (std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "pub const "))
    {
        if (hasTypeKeyword(trimmed, "struct")) return false;
        if (hasTypeKeyword(trimmed, "enum")) return false;
        if (hasTypeKeyword(trimmed, "union")) return false;
        if (hasTypeKeyword(trimmed, "opaque")) return false;

        if (std.mem.indexOf(u8, trimmed, "@import") != null) return endsWithSemicolon(trimmed);
        if (std.mem.indexOf(u8, trimmed, "@cImport") != null) return endsWithSemicolon(trimmed);

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
        const before_eq = trimmed[0..eq];
        if (std.mem.indexOfScalar(u8, before_eq, ':') != null) return false;
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t;\n\r");
        if (rhs.len == 0 or (!std.ascii.isAlphabetic(rhs[0]) and rhs[0] != '_')) return false;
        var has_dot = false;
        for (rhs) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_') return false;
            if (c == '.') has_dot = true;
        }
        if (!has_dot) return false;
        return endsWithSemicolon(trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "_ = @import")) return endsWithSemicolon(trimmed);

    return false;
}

pub fn collectImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    block_end: usize,
) !std.ArrayListUnmanaged(Import) {
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    errdefer imports.deinit(allocator);

    var i: usize = 0;
    var depth: usize = 0;

    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        if (source[i] == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (source[i] == '}') {
            depth -|= 1;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            if (depth > 0) {
                i += "@import(".len;
                continue;
            }
            const found = i;
            const line_start = findLineStart(source, found);
            const line_end = findLineEnd(source, found);
            const line = std.mem.trimStart(u8, source[line_start..line_end], " \t\r");
            if (!std.mem.startsWith(u8, line, "const ") and
                !std.mem.startsWith(u8, line, "pub const ") and
                !std.mem.startsWith(u8, line, "_ = @import"))
            {
                i = line_end;
                continue;
            }
            const path = extractPath(source[found..], "@import(") orelse {
                i = line_end;
                continue;
            };
            const comment_start = findCommentStart(source, line_start);
            var import_end = line_end;
            if (!endsWithSemicolon(line)) {
                var j = line_end;
                while (j < source.len) {
                    const j_skip = skipStringOrComment(source, j);
                    if (j_skip != j) {
                        j = j_skip;
                        continue;
                    }
                    if (source[j] == ';') {
                        import_end = j + 1;
                        break;
                    }
                    if (source[j] == '{' or source[j] == '}') break;
                    j += 1;
                }
                if (import_end == line_end) {
                    i = line_end;
                    continue;
                }
            }
            try imports.append(allocator, .{
                .start = line_start,
                .end = import_end,
                .path = path,
                .class = classify(path),
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = import_end;
            continue;
        }

        if (std.mem.startsWith(u8, source[i..], "@cImport(")) {
            if (depth > 0) {
                i += "@cImport(".len;
                continue;
            }
            const found = i;
            const line_start = findLineStart(source, found);
            const block_end_cimport = findCImportEnd(source, found);
            const comment_start = findCommentStart(source, line_start);
            try imports.append(allocator, .{
                .start = line_start,
                .end = block_end_cimport,
                .path = "<cimport>",
                .class = class_third_party,
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = block_end_cimport;
            continue;
        }

        i += 1;
    }

    std.sort.pdq(Import, imports.items, {}, Import.lessThan);
    return imports;
}

pub fn findImportBlockEnd(source: []const u8) usize {
    var pos: usize = 0;
    while (pos < source.len) {
        const line_end = findLineEnd(source, pos);
        const line = source[pos..line_end];
        if (std.mem.indexOf(u8, line, "@cImport(")) |cimport_pos| {
            pos = findCImportEnd(source, pos + cimport_pos);
            continue;
        }
        if (!isTopLevelImportLine(line)) return pos;
        pos = line_end;
    }
    return pos;
}

fn allocFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch |err| {
        std.debug.print("zsort: failed to format message: {s}\n", .{@errorName(err)});
        return null;
    };
}

pub fn hasBannedPatterns(
    allocator: std.mem.Allocator,
    source: []const u8,
    banned_prefixes: []const []const u8,
) !?[]const u8 {
    var i: usize = 0;
    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            const found = i;
            const line_start = findLineStart(source, found);
            const line_end_excl = findLineEnd(source, found);
            const line = std.mem.trimStart(u8, source[line_start..line_end_excl], " \t\r");

            if (!std.mem.startsWith(u8, line, "const ") and
                !std.mem.startsWith(u8, line, "pub const ") and
                !std.mem.startsWith(u8, line, "_ = @import"))
            {
                return allocFmt(allocator, "inline @import in type expression", .{}) orelse return error.OutOfMemory;
            }

            if (extractPath(source[found..], "@import(")) |path| {
                for (banned_prefixes) |prefix| {
                    if (std.mem.startsWith(u8, path, prefix)) {
                        return allocFmt(allocator, "import path starts with banned prefix '{s}'", .{prefix}) orelse return error.OutOfMemory;
                    }
                }
            }

            i = line_end_excl;
            continue;
        }
        i += 1;
    }

    return null;
}

fn detectNewline(source: []const u8) []const u8 {
    var crlf: usize = 0;
    var lf: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            lf += 1;
            if (i > 0 and source[i - 1] == '\r') crlf += 1;
        }
    }
    return if (crlf * 2 > lf) "\r\n" else "\n";
}

pub fn buildSortedImportText(
    allocator: std.mem.Allocator,
    source: []const u8,
    sorted_imports: []const Import,
    block_end: usize,
) ![]const u8 {
    var extra_imports: std.ArrayListUnmanaged(Import) = .empty;
    defer extra_imports.deinit(allocator);

    var preamble_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer preamble_lines.deinit(allocator);

    var trailing_comments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer trailing_comments.deinit(allocator);

    var trailing_comment_start: ?usize = null;

    var seen_content: bool = false;
    var pos: usize = 0;
    while (pos < block_end) {
        const le = findLineEnd(source, pos);
        const line = source[pos..le];
        const trimmed = std.mem.trimStart(u8, line, " \t\n\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            if (!seen_content) {
                try preamble_lines.append(allocator, line);
            } else {
                if (trailing_comment_start == null) trailing_comment_start = pos;
                try trailing_comments.append(allocator, line);
            }
            pos = le;
            continue;
        }
        seen_content = true;
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ")) {
            if (std.mem.indexOf(u8, trimmed, "@import(") == null and
                std.mem.indexOf(u8, trimmed, "@cImport(") == null)
            {
                const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                };
                const rhs_raw = trimmed[eq + 1 ..];
                const rhs = std.mem.trim(u8, rhs_raw, " \t;\n\r");
                if (rhs.len == 0 or (!std.ascii.isAlphabetic(rhs[0]) and rhs[0] != '_')) {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                }
                var valid_rhs = true;
                for (rhs) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_') {
                        valid_rhs = false;
                        break;
                    }
                }
                if (!valid_rhs) {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                }
                const dot = std.mem.indexOfScalar(u8, rhs, '.') orelse {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                };
                const module_name = rhs[0..dot];
                const attached_comment_start = trailing_comment_start;
                trailing_comment_start = null;
                trailing_comments.clearRetainingCapacity();
                try extra_imports.append(allocator, .{
                    .start = pos,
                    .end = le,
                    .path = rhs,
                    .class = classify(module_name),
                    .stray = false,
                    .comment_start = attached_comment_start,
                });
            } else {
                trailing_comment_start = null;
                trailing_comments.clearRetainingCapacity();
            }
        } else {
            trailing_comment_start = null;
            trailing_comments.clearRetainingCapacity();
        }
        pos = le;
    }

    var all_imports: std.ArrayListUnmanaged(Import) = .empty;
    defer all_imports.deinit(allocator);
    try all_imports.appendSlice(allocator, sorted_imports);

    var imports_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer imports_buf.deinit(allocator);

    const nl = detectNewline(source);

    var prev_class: ?u2 = null;
    for (all_imports.items) |imp| {
        if (prev_class != null and prev_class.? != imp.class) {
            try imports_buf.appendSlice(allocator, nl);
        }
        prev_class = imp.class;
        if (imp.comment_start) |cs| {
            try imports_buf.appendSlice(allocator, source[cs..imp.start]);
        }
        const text = source[imp.start..imp.end];
        const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed_import.len > 0) {
            try imports_buf.appendSlice(allocator, trimmed_import);
            try imports_buf.appendSlice(allocator, nl);
        }
    }

    if (extra_imports.items.len > 0) {
        if (imports_buf.items.len > 0 and imports_buf.items[imports_buf.items.len - 1] != '\n') {
            try imports_buf.appendSlice(allocator, nl);
        }
        if (all_imports.items.len > 0) {
            try imports_buf.appendSlice(allocator, nl);
        }
        for (extra_imports.items) |imp| {
            if (imp.comment_start) |cs| {
                try imports_buf.appendSlice(allocator, source[cs..imp.start]);
            }
            const text = source[imp.start..imp.end];
            const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
            if (trimmed_import.len > 0) {
                try imports_buf.appendSlice(allocator, trimmed_import);
                try imports_buf.appendSlice(allocator, nl);
            }
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (preamble_lines.items) |line| {
        try buf.appendSlice(allocator, line);
    }
    if (preamble_lines.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        try buf.appendSlice(allocator, nl);
    }

    try buf.appendSlice(allocator, imports_buf.items);

    if (trailing_comments.items.len > 0) {
        try buf.appendSlice(allocator, nl);
        for (trailing_comments.items) |line| {
            try buf.appendSlice(allocator, line);
        }
    }

    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n') {
        try buf.appendSlice(allocator, nl);
    }

    var deduped: std.ArrayListUnmanaged(u8) = .empty;
    errdefer deduped.deinit(allocator);
    var blank_run: usize = 0;
    var line_pos: usize = 0;
    while (line_pos < buf.items.len) {
        const le = findLineEnd(buf.items, line_pos);
        const line = buf.items[line_pos..le];
        const is_blank = std.mem.trim(u8, line, " \t\r\n").len == 0;
        blank_run = if (is_blank) blank_run + 1 else 0;
        if (blank_run < 2) try deduped.appendSlice(allocator, line);
        line_pos = le;
    }

    return deduped.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, std.mem.trimEnd(u8, line, "\r"));
    }
    // A trailing newline produces a final empty element; drop it so that
    // "a\n" and "a" compare equal.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        lines.items.len -= 1;
    }
    return lines;
}

/// Minimal unified-style diff: trims common prefix/suffix lines and shows the
/// changed middle with up to two context lines around it.
/// ponytail: prefix/suffix diff, switch to Myers if multi-hunk noise ever matters
pub fn formatUnifiedDiff(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old: []const u8,
    new: []const u8,
) ![]const u8 {
    var old_lines = try splitLines(allocator, old);
    defer old_lines.deinit(allocator);
    var new_lines = try splitLines(allocator, new);
    defer new_lines.deinit(allocator);

    var p: usize = 0;
    while (p < old_lines.items.len and p < new_lines.items.len and
        std.mem.eql(u8, old_lines.items[p], new_lines.items[p])) : (p += 1)
    {}

    var s: usize = 0;
    while (s < old_lines.items.len - p and s < new_lines.items.len - p and
        std.mem.eql(u8, old_lines.items[old_lines.items.len - 1 - s], new_lines.items[new_lines.items.len - 1 - s])) : (s += 1)
    {}

    const old_mid = old_lines.items[p .. old_lines.items.len - s];
    const new_mid = new_lines.items[p .. new_lines.items.len - s];
    const after_start = old_lines.items.len - s;
    const after_end = @min(old_lines.items.len, after_start + 2);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = compat.ListWriter.init(allocator, &buf);
    errdefer buf = w.toArrayList();

    if (old_mid.len == 0 and new_mid.len == 0) {
        try w.print("  --- {s}\n", .{file_path});
        try w.print("  +++ {s}\n", .{file_path});
        try w.print("  (trailing newline only)\n", .{});
        try w.writeByte('\n');
        buf = w.toArrayList();
        return buf.toOwnedSlice(allocator);
    }

    try w.print("  --- {s}\n", .{file_path});
    try w.print("  +++ {s}\n", .{file_path});
    try w.print("  @@ -{d},{d} +{d},{d} @@\n", .{ p + 1, old_mid.len, p + 1, new_mid.len });
    for (old_lines.items[p -| 2..p]) |line| try w.print("   {s}\n", .{line});
    for (old_mid) |line| try w.print("  - {s}\n", .{line});
    for (new_mid) |line| try w.print("  + {s}\n", .{line});
    for (old_lines.items[after_start..after_end]) |line| try w.print("   {s}\n", .{line});
    try w.writeByte('\n');
    buf = w.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn showDiff(io: compat.Io, allocator: std.mem.Allocator, file_path: []const u8, old: []const u8, new: []const u8) void {
    const diff = formatUnifiedDiff(allocator, file_path, old, new) catch return;
    if (compat.is_v016) {
        var obuf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writer(io, &obuf);
        stdout_w.interface.writeAll(diff) catch return;
        stdout_w.flush() catch return;
    } else {
        var obuf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_w = stdout_file.writer(&obuf);
        stdout_w.interface.writeAll(diff) catch return;
    }
}

const excluded_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };

fn isExcludedPath(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        for (excluded_dirs) |dir_name| {
            if (std.mem.eql(u8, component, dir_name)) return true;
        }
    }
    return false;
}

/// Component-boundary prefix match: a slash-free `pattern` matches any path
/// component and everything below it (`build` matches `build` and `a/build/x.zig`,
/// but not `build-tools/x.zig`). A pattern containing a slash is anchored at the
/// path root. A trailing slash in `pattern` is ignored.
pub fn matchesIgnore(path: []const u8, pattern: []const u8) bool {
    const pat = std.mem.trimEnd(u8, pattern, "/");
    if (pat.len == 0) return false;
    if (std.mem.indexOfScalar(u8, pat, '/') != null) {
        return matchesComponentPrefix(path, pat);
    }
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (matchesComponentPrefix(component, pat)) return true;
    }
    return false;
}

fn matchesComponentPrefix(s: []const u8, pat: []const u8) bool {
    if (!std.mem.startsWith(u8, s, pat)) return false;
    return s.len == pat.len or s[pat.len] == '/' or s[pat.len] == '\\';
}

fn matchesAnyIgnore(path: []const u8, ignores: []const []const u8) bool {
    for (ignores) |pattern| {
        if (matchesIgnore(path, pattern)) return true;
    }
    return false;
}

/// Read `<dir>/.gitignore` and return its cleaned patterns, allocated with
/// `allocator` (patterns and the slice belong to that allocator).
/// Missing or unreadable files yield an empty list (not an error).
/// ponytail: no wildcards or negation; entries match as path-component prefixes
pub fn loadGitignore(io: compat.Io, allocator: std.mem.Allocator, dir: compat.Dir) ![]const []const u8 {
    const contents = compat.readFileAlloc(io, dir, ".gitignore", allocator, 1024 * 1024) catch return &[_][]const u8{};
    defer allocator.free(contents);

    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer patterns.deinit(allocator);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '!' or std.mem.indexOfAny(u8, line, "*?[") != null) continue;
        try patterns.append(allocator, try allocator.dupe(u8, line));
    }
    return patterns.toOwnedSlice(allocator);
}

pub fn walkDir(
    io: compat.Io,
    allocator: std.mem.Allocator,
    dir: compat.Dir,
    base_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    ignores: []const []const u8,
) !void {
    const Item = struct {
        dir: compat.Dir,
        iter: compat.Iterator,
        rel_len: usize,
    };
    var stack: std.ArrayListUnmanaged(Item) = .empty;
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        if (stack.items.len > 1) {
            for (stack.items[1..]) |*item| compat.close(io, &item.dir);
        }
        stack.deinit(allocator);
        name_buf.deinit(allocator);
    }

    try stack.append(allocator, .{ .dir = dir, .iter = compat.iterate(dir), .rel_len = 0 });

    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const entry = try compat.next(io, &top.iter) orelse {
            var item = stack.pop().?;
            if (stack.items.len != 0) compat.close(io, &item.dir);
            continue;
        };
        name_buf.shrinkRetainingCapacity(top.rel_len);
        if (name_buf.items.len != 0) try name_buf.append(allocator, std.fs.path.sep);
        try name_buf.appendSlice(allocator, entry.name);
        const rel = name_buf.items;

        switch (entry.kind) {
            .directory => {
                if (isExcludedPath(rel)) continue;
                if (matchesAnyIgnore(rel, ignores)) continue;
                var sub = try compat.openDir(io, top.dir, entry.name, .{ .iterate = true });
                errdefer compat.close(io, &sub);
                try stack.append(allocator, .{ .dir = sub, .iter = compat.iterate(sub), .rel_len = name_buf.items.len });
            },
            .file => {
                if (isExcludedPath(rel)) continue;
                if (matchesAnyIgnore(rel, ignores)) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const full_path = try std.fs.path.join(allocator, &.{ base_path, rel });
                try files.append(allocator, full_path);
            },
            else => {},
        }
    }
}

fn hasSkipComment(source: []const u8) bool {
    var pos: usize = 0;
    while (pos < source.len) {
        const le = findLineEnd(source, pos);
        const trimmed = std.mem.trimStart(u8, source[pos..le], " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//") and std.mem.indexOf(u8, trimmed, "zsort: skip") != null) {
            return true;
        }
        pos = le;
    }
    return false;
}

pub const ProcessResult = struct {
    new_text: []const u8,
    new_block: []const u8,
    block_end: usize,
    changed: bool,
    banned: bool,
    banned_msg: ?[]const u8,
    stray_count: usize,
};

pub fn processSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    banned_prefixes: []const []const u8,
) !ProcessResult {
    if (hasSkipComment(source)) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = 0,
            .changed = false,
            .banned = false,
            .banned_msg = null,
            .stray_count = 0,
        };
    }

    const block_end = findImportBlockEnd(source);
    var imports = try collectImports(allocator, source, block_end);
    defer imports.deinit(allocator);

    const banned_msg = try hasBannedPatterns(allocator, source, banned_prefixes);
    errdefer if (banned_msg) |msg| allocator.free(msg);

    if (imports.items.len == 0) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = block_end,
            .changed = false,
            .banned = banned_msg != null,
            .banned_msg = banned_msg,
            .stray_count = 0,
        };
    }

    var stray_imports = std.ArrayListUnmanaged(Import).empty;
    defer stray_imports.deinit(allocator);
    for (imports.items) |imp| {
        if (imp.stray) {
            try stray_imports.append(allocator, imp);
        }
    }

    var rest = source[block_end..];
    var rest_owned: ?[]const u8 = null;
    errdefer if (rest_owned) |owned| allocator.free(owned);
    if (stray_imports.items.len > 0) {
        std.sort.pdq(Import, stray_imports.items, {}, struct {
            fn lt(_: void, a: Import, b: Import) bool {
                return a.start < b.start;
            }
        }.lt);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        var pos: usize = block_end;
        for (stray_imports.items) |imp| {
            const raw_start = if (imp.comment_start) |cs| cs else imp.start;
            const removal_start = @max(raw_start, pos);
            if (imp.end <= pos) continue;
            try buf.appendSlice(allocator, source[pos..removal_start]);
            pos = imp.end;
        }
        try buf.appendSlice(allocator, source[pos..]);
        const owned = try buf.toOwnedSlice(allocator);
        rest_owned = owned;
        rest = owned;
    }

    const new_imports = try buildSortedImportText(allocator, source, imports.items, block_end);
    errdefer allocator.free(new_imports);

    const original_block = source[0..block_end];
    const changed = !std.mem.eql(u8, original_block, new_imports) or stray_imports.items.len > 0;

    const full_new = try std.mem.concat(allocator, u8, &.{ new_imports, rest });
    if (rest_owned) |owned| allocator.free(owned);

    return .{
        .new_text = full_new,
        .new_block = new_imports,
        .block_end = block_end,
        .changed = changed,
        .banned = banned_msg != null,
        .banned_msg = banned_msg,
        .stray_count = stray_imports.items.len,
    };
}

pub const CliMode = enum { check, fix };

pub const ParseError = error{ OutOfMemory, Usage, InvalidMode, MissingBanValue, UnexpectedArg };

pub const Args = struct {
    mode: CliMode,
    target: []const u8,
    banned_prefixes: std.ArrayListUnmanaged([]const u8),
    help: bool = false,
    version: bool = false,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.banned_prefixes.deinit(allocator);
    }
};

/// On error, `err_msg` (when non-null) is set to a heap-allocated message
/// describing what went wrong; the caller frees it.
pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    err_msg: *?[]const u8,
) ParseError!Args {
    var mode: ?CliMode = null;
    var target: ?[]const u8 = null;
    var help = false;
    var show_version = false;

    var banned_prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer banned_prefixes.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--ban-prefix")) {
            if (i + 1 >= args.len) return error.MissingBanValue;
            i += 1;
            try banned_prefixes.append(allocator, args[i]);
        } else if (arg.len > 0 and arg[0] == '-') {
            err_msg.* = allocFmt(allocator, "unknown option '{s}'", .{arg});
            return error.UnexpectedArg;
        } else if (mode == null) {
            if (std.mem.eql(u8, arg, "check")) {
                mode = .check;
            } else if (std.mem.eql(u8, arg, "fix")) {
                mode = .fix;
            } else {
                err_msg.* = allocFmt(allocator, "unknown mode '{s}'. Expected 'check' or 'fix'", .{arg});
                return error.InvalidMode;
            }
        } else if (target == null) {
            target = arg;
        } else {
            err_msg.* = allocFmt(allocator, "unexpected argument '{s}'", .{arg});
            return error.UnexpectedArg;
        }
    }

    if (help or show_version) {
        return .{
            .mode = mode orelse .check,
            .target = target orelse ".",
            .banned_prefixes = banned_prefixes,
            .help = help,
            .version = show_version,
        };
    }
    return .{
        .mode = mode orelse return error.Usage,
        .target = target orelse return error.Usage,
        .banned_prefixes = banned_prefixes,
    };
}

fn printStdout(io: compat.Io, comptime fmt: []const u8, args: anytype) void {
    if (compat.is_v016) {
        var obuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &obuf);
        w.interface.print(fmt, args) catch return;
        w.flush() catch return;
    } else {
        var obuf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&obuf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch return;
    }
}

fn useColor(io: compat.Io) bool {
    if (compat.is_v016) {
        return std.Io.File.isTty(std.Io.File.stdout(), io) catch return false;
    }
    return std.posix.isatty(std.fs.File.stdout().handle);
}

pub const SummaryStats = struct {
    changed: usize,
    errors: usize,
    banned: usize,
    files: usize,
    elapsed_ns: u64,
};

pub fn formatSummary(
    allocator: std.mem.Allocator,
    stats: SummaryStats,
    mode: CliMode,
    use_color: bool,
) ?[]const u8 {
    const on = "\x1b[33m";
    const off = "\x1b[39m";
    const ms = @divTrunc(stats.elapsed_ns, std.time.ns_per_ms);
    if (use_color) {
        return switch (mode) {
            .check => allocFmt(allocator, "\t{[0]s}{[2]d}{[1]s} needs fixing, {[0]s}{[3]d}{[1]s} errors, {[0]s}{[4]d}{[1]s} banned across {[0]s}{[5]d}{[1]s} files in {[0]s}{[6]d}{[1]s}ms.\n", .{ on, off, stats.changed, stats.errors, stats.banned, stats.files, ms }),
            .fix => allocFmt(allocator, "\n\tFixed {[0]s}{[2]d}{[1]s} files, {[0]s}{[3]d}{[1]s} errors, {[0]s}{[4]d}{[1]s} banned across {[0]s}{[5]d}{[1]s} files in {[0]s}{[6]d}{[1]s}ms.\n", .{ on, off, stats.changed, stats.errors, stats.banned, stats.files, ms }),
        };
    }
    return switch (mode) {
        .check => allocFmt(allocator, "\t{d} needs fixing, {d} errors, {d} banned across {d} files in {d}ms.\n", .{ stats.changed, stats.errors, stats.banned, stats.files, ms }),
        .fix => allocFmt(allocator, "\n\tFixed {d} files, {d} errors, {d} banned across {d} files in {d}ms.\n", .{ stats.changed, stats.errors, stats.banned, stats.files, ms }),
    };
}

fn printHelp(io: compat.Io) void {
    printStdout(io,
        \\Usage: zsort [check|fix] <dir|file> [options]
        \\
        \\Modes:
        \\  check              Verify Zig import ordering; exits 1 when changes are needed
        \\  fix                Rewrite files with sorted imports
        \\
        \\Options:
        \\  --ban-prefix <p>   Reject import paths starting with prefix (repeatable)
        \\  -h, --help         Show this help message
        \\  --version          Print version and exit
        \\
    , .{});
}

const JobSlot = struct {
    arena: *std.heap.ArenaAllocator,
    source: []const u8,
    result: ?ProcessResult = null,
    read_err: ?[]const u8 = null,
    proc_err: ?[]const u8 = null,
};

const FileJob = struct {
    slot: *JobSlot,
    path: []const u8,
    banned: []const []const u8,
};

fn processFileJob(job: *const FileJob, io: compat.Io) void {
    const allocator = job.slot.arena.allocator();
    const source = compat.readFileAlloc(io, compat.cwd(), job.path, allocator, 10 * 1024 * 1024) catch |err| {
        job.slot.read_err = @errorName(err);
        return;
    };
    job.slot.source = source;
    job.slot.result = processSource(allocator, source, job.banned) catch |err| {
        job.slot.proc_err = @errorName(err);
        return;
    };
}

fn mainV15() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    const io: compat.Io = {};
    try runMain(allocator, args, io);
}

fn mainV16(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try collectArgs(allocator, init.minimal.args);
    try runMain(allocator, args, init.io);
}

pub const main = if (compat.is_v016) mainV16 else mainV15;

/// Zig 0.16 has no `argsAlloc`; the args arrive via `Init` and must be
/// collected into a slice.
fn collectArgs(allocator: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.process.Args.Iterator.init(args);
    while (it.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
    return list.toOwnedSlice(allocator);
}

fn runMain(allocator: std.mem.Allocator, args: []const []const u8, io: compat.Io) !void {
    var err_msg: ?[]const u8 = null;
    var parsed = parseArgs(allocator, args, &err_msg) catch |e| switch (e) {
        error.Usage => {
            std.debug.print("Usage: zsort [check|fix] <dir|file> [--ban-prefix <prefix>]...\n", .{});
            std.debug.print("Run 'zsort --help' for details.\n", .{});
            std.process.exit(1);
        },
        error.InvalidMode => {
            std.debug.print("Invalid mode: {s}\n", .{err_msg orelse "expected 'check' or 'fix'"});
            std.process.exit(1);
        },
        error.MissingBanValue => {
            std.debug.print("Missing value for --ban-prefix\n", .{});
            std.process.exit(1);
        },
        error.UnexpectedArg => {
            std.debug.print("Unexpected argument: {s}\n", .{err_msg orelse ""});
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printHelp(io);
        return;
    }
    if (parsed.version) {
        printStdout(io, "zsort {s}\n", .{version});
        return;
    }

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    const stat = compat.statFile(io, compat.cwd(), parsed.target) catch |err| {
        std.debug.print("Cannot access '{s}': {s}\n", .{ parsed.target, @errorName(err) });
        std.process.exit(1);
    };

    if (stat.kind == .directory) {
        var dir = try compat.openDir(io, compat.cwd(), parsed.target, .{ .iterate = true });
        defer compat.close(io, &dir);
        const ignores = try loadGitignore(io, allocator, dir);
        try walkDir(io, allocator, dir, parsed.target, &files, ignores);
    } else if (stat.kind == .file) {
        try files.append(allocator, parsed.target);
    } else {
        std.debug.print("'{s}' is not a supported file or directory\n", .{parsed.target});
        std.process.exit(1);
    }

    if (files.items.len == 0) {
        std.debug.print("No .zig files found in '{s}'\n", .{parsed.target});
        std.process.exit(1);
    }

    var timer = try compat.Timer.start(io);

    const slots = try allocator.alloc(JobSlot, files.items.len);
    defer allocator.free(slots);
    for (slots) |*slot| {
        const file_arena = try allocator.create(std.heap.ArenaAllocator);
        file_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // SAFETY: source is set by the worker before main reads it; read_err
        // and proc_err guard every access path.
        slot.* = .{
            .arena = file_arena,
            .source = undefined,
        };
    }

    const jobs = try allocator.alloc(FileJob, files.items.len);
    defer allocator.free(jobs);
    for (jobs, slots, files.items) |*job, *slot, file_path| {
        job.* = .{
            .slot = slot,
            .path = file_path,
            .banned = parsed.banned_prefixes.items,
        };
    }

    // SAFETY: init() fully initializes the pool before any use below.
    if (compat.is_v016) {
        var g: std.Io.Group = .init;
        for (jobs) |*job| g.async(io, processFileJob, .{ job, io });
        try g.await(io);
    } else {
        var pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&pool, .{ .allocator = allocator, .n_jobs = null });
        defer pool.deinit();
        var wg: std.Thread.WaitGroup = .{};
        for (jobs) |*job| pool.spawnWg(&wg, processFileJob, .{ job, {} });
        pool.waitAndWork(&wg);
    }

    var changed_count: usize = 0;
    var fixed_count: usize = 0;
    var error_count: usize = 0;
    var banned_count: usize = 0;

    for (jobs) |*job| {
        const slot = job.slot;
        defer allocator.destroy(slot.arena);
        defer slot.arena.deinit();
        const file_path = job.path;

        if (slot.read_err) |msg| {
            std.debug.print("Error reading {s}: {s}\n", .{ file_path, msg });
            error_count += 1;
            continue;
        }
        if (slot.proc_err) |msg| {
            std.debug.print("Error processing {s}: {s}\n", .{ file_path, msg });
            error_count += 1;
            continue;
        }
        const result = slot.result orelse continue;
        if (result.banned_msg) |msg| {
            std.debug.print("{s}: banned: {s}\n", .{ file_path, msg });
            banned_count += 1;
        }
        if (!result.changed) continue;

        changed_count += 1;

        if (parsed.mode == .fix) {
            fixFile: {
                compat.atomicWrite(io, compat.cwd(), file_path, result.new_text) catch |err| {
                    std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                    error_count += 1;
                    break :fixFile;
                };
                fixed_count += 1;
                printStdout(io, "Fixed: {s}\n", .{file_path});
            }
        } else {
            if (result.stray_count > 0) {
                showDiff(io, allocator, file_path, slot.source, result.new_text);
            } else {
                showDiff(io, allocator, file_path, slot.source[0..result.block_end], result.new_block);
            }
        }
    }

    const stats = SummaryStats{
        .changed = if (parsed.mode == .fix) fixed_count else changed_count,
        .errors = error_count,
        .banned = banned_count,
        .files = files.items.len,
        .elapsed_ns = timer.read(),
    };
    if (parsed.mode == .check) {
        if (formatSummary(allocator, stats, .check, useColor(io))) |summary| {
            printStdout(io, "{s}", .{summary});
        }
        if (changed_count > 0 or error_count > 0 or banned_count > 0) {
            std.process.exit(1);
        }
    } else {
        if (formatSummary(allocator, stats, .fix, useColor(io))) |summary| {
            printStdout(io, "{s}", .{summary});
        }
        if (error_count > 0 or banned_count > 0) std.process.exit(1);
    }
}
