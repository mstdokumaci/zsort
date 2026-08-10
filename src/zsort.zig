// zlint-disable no-print

const std = @import("std");

const ast_scan = @import("ast_scan.zig");
const compat = @import("compat.zig");
const version = @import("version.zig").version;

const Import = ast_scan.Import;
const findLineEnd = ast_scan.findLineEnd;
const findLineStart = ast_scan.findLineStart;

/// Emit the comment block attached to a decl (`source[comment_start..imp.start]`),
/// dropping blank lines: `findCommentStart` walks back over blanks, but a
/// blank line must not travel with the decl, or the output would depend on
/// the input order.
fn appendCommentBlock(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), block: []const u8) !void {
    var pos: usize = 0;
    while (pos < block.len) {
        const le = findLineEnd(block, pos);
        const line = block[pos..le];
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r\n"), "//")) {
            try buf.appendSlice(allocator, line);
        }
        pos = le;
    }
}

fn allocFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch |err| {
        std.debug.print("zsort: failed to format message: {s}\n", .{@errorName(err)});
        return null;
    };
}

const ansi_reset = "\x1b[0m";
const ansi_red = "\x1b[31m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";
const ansi_magenta = "\x1b[35m";
const ansi_cyan = "\x1b[36m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";

/// Returns `code` when color is enabled, else an empty slice, so call sites
/// can build plain and colored strings from the same format string.
fn ansi(enable: bool, code: []const u8) []const u8 {
    return if (enable) code else "";
}

fn printStdout(io: compat.Io, comptime fmt: []const u8, args: anytype) void {
    var obuf: [4096]u8 = undefined;
    var w = compat.stdoutWriter(io, &obuf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

fn writeStdout(io: compat.Io, bytes: []const u8) void {
    var obuf: [4096]u8 = undefined;
    var w = compat.stdoutWriter(io, &obuf);
    w.interface.writeAll(bytes) catch return;
    w.interface.flush() catch return;
}

fn printStderr(io: compat.Io, comptime fmt: []const u8, args: anytype) void {
    var obuf: [4096]u8 = undefined;
    var w = compat.stderrWriter(io, &obuf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// Replace terminal-control bytes with visible `\xNN` forms (ESC, CR, LF,
/// BEL, backspace), so dynamic text (filenames, diff lines, error strings)
/// can't inject ANSI escapes or line forgeries into the terminal;
/// `ansi_*` codes are the only intentional raw escape sequences.
/// Returns `s` unchanged when clean (no allocation). Propagates
/// `error.OutOfMemory` rather than ever returning the raw input.
pub fn escapeTerm(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |b| {
        switch (b) {
            0x1b, 0x0d, 0x0a, 0x07, 0x08 => n += 1,
            else => {},
        }
    }
    if (n == 0) return s;
    const out = try allocator.alloc(u8, s.len + n * 3);
    var o: usize = 0;
    for (s) |b| {
        switch (b) {
            0x1b => out[o..][0..4].* = "\\x1b".*,
            0x0d => out[o..][0..4].* = "\\x0d".*,
            0x0a => out[o..][0..4].* = "\\x0a".*,
            0x07 => out[o..][0..4].* = "\\x07".*,
            0x08 => out[o..][0..4].* = "\\x08".*,
            else => {
                out[o] = b;
                o += 1;
                continue;
            },
        }
        o += 4;
    }
    return out;
}

fn scanBannedPatterns(
    allocator: std.mem.Allocator,
    analysis: *const ast_scan.Analysis,
    banned_prefixes: []const []const u8,
    source: []const u8,
) !?[]const u8 {
    for (analysis.calls.items) |call| {
        const line = std.mem.count(u8, source[0..call.offset], "\n") + 1;
        if (std.mem.indexOfScalar(usize, analysis.allowed.items, call.offset) == null) {
            return allocFmt(allocator, "inline @import inside a type expression (line {d})", .{line}) orelse return error.OutOfMemory;
        }
        if (call.path) |path| {
            for (banned_prefixes) |prefix| {
                if (std.mem.startsWith(u8, path, prefix)) {
                    return allocFmt(allocator, "imports from '{s}' are not allowed (line {d})", .{ prefix, line }) orelse return error.OutOfMemory;
                }
            }
        }
    }
    return null;
}

pub fn hasBannedPatterns(
    allocator: std.mem.Allocator,
    source: []const u8,
    banned_prefixes: []const []const u8,
) !?[]const u8 {
    const dup = try allocator.dupeZ(u8, source);
    defer allocator.free(dup);
    var analysis = try ast_scan.analyze(allocator, dup);
    defer analysis.deinit(allocator);
    return scanBannedPatterns(allocator, &analysis, banned_prefixes, source);
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
    aliases: []const Import,
    block_end: usize,
    bottom: bool,
) ![]const u8 {
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
        trailing_comment_start = null;
        trailing_comments.clearRetainingCapacity();
        pos = le;
    }

    var all_imports: std.ArrayListUnmanaged(Import) = .empty;
    defer all_imports.deinit(allocator);
    try all_imports.appendSlice(allocator, sorted_imports);
    try all_imports.appendSlice(allocator, aliases);

    var imports_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer imports_buf.deinit(allocator);

    const nl = detectNewline(source);

    // A blank line separates classification bands (std/third-party/local)
    // and the alias band. Plain and member imports of the same class form
    // one band; `member` stays in the sort key but never triggers a blank.
    const Group = struct { alias: bool, class: u2 };
    var prev_group: ?Group = null;
    for (all_imports.items, 0..) |imp, idx| {
        const group: Group = if (idx >= sorted_imports.len)
            .{ .alias = true, .class = 0 }
        else
            .{ .alias = false, .class = imp.class };
        if (prev_group) |prev| {
            if (prev.alias != group.alias or prev.class != group.class) {
                try imports_buf.appendSlice(allocator, nl);
            }
        }
        prev_group = group;
        if (imp.comment_start) |cs| {
            try appendCommentBlock(allocator, &imports_buf, source[cs..imp.start]);
        }
        const text = source[imp.start..imp.end];
        const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed_import.len > 0) {
            try imports_buf.appendSlice(allocator, trimmed_import);
            try imports_buf.appendSlice(allocator, nl);
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    if (bottom) {
        // The comment run directly above the first import is attached to it
        // and travels with the block as its lead; everything above that run
        // (`//!` docs, detached headers, blanks) stays at the top of the
        // file, where processSource emits it. The first top-region span has
        // comment_start == null (its run reaches line 0), so this is the
        // only place its attached comments are emitted.
        var first_start: usize = source.len;
        for (sorted_imports) |imp| first_start = @min(first_start, imp.start);
        for (aliases) |a| first_start = @min(first_start, a.start);
        if (first_start < block_end) {
            const line_start = findLineStart(source, first_start);
            try buf.appendSlice(allocator, source[attachedCommentHeadStart(source, line_start)..line_start]);
        }
    } else {
        for (preamble_lines.items) |line| {
            try buf.appendSlice(allocator, line);
        }
        if (preamble_lines.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
            try buf.appendSlice(allocator, nl);
        }
    }

    try buf.appendSlice(allocator, imports_buf.items);

    // In bottom mode the trailing comments stay with the body (processSource
    // keeps them via the middle pass); only top mode attaches them to the
    // end of the block, where they sit above the first body decl.
    if (trailing_comments.items.len > 0 and !bottom) {
        try buf.appendSlice(allocator, nl);
        for (trailing_comments.items) |line| {
            try buf.appendSlice(allocator, line);
        }
    }

    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n') {
        try buf.appendSlice(allocator, nl);
    }

    return collapseBlankLines(allocator, buf.items, false);
}

/// Max one blank line between content lines; when `strip_trailing` is set,
/// trailing blank lines are removed. Keeps the first line of each blank run
/// verbatim so CRLF runs survive; blank detection ignores spaces, tabs, and
/// `\r`.
fn collapseBlankLines(allocator: std.mem.Allocator, text: []const u8, strip_trailing: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_blank_start: ?usize = null;
    var pos: usize = 0;
    while (pos < text.len) {
        const le = findLineEnd(text, pos);
        const line = text[pos..le];
        const is_blank = std.mem.trim(u8, line, " \t\r\n").len == 0;
        if (!is_blank or last_blank_start == null) {
            try out.appendSlice(allocator, line);
            last_blank_start = if (is_blank) out.items.len - (le - pos) else null;
        }
        pos = le;
    }
    if (strip_trailing) {
        if (last_blank_start) |start| out.shrinkRetainingCapacity(start);
    }
    return out.toOwnedSlice(allocator);
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
/// changed middle with up to two context lines around it. When `use_color` is
/// set, headers, hunks, and changed lines are ANSI-colored git-style.
pub fn formatUnifiedDiff(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old: []const u8,
    new: []const u8,
    use_color: bool,
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

    const red = ansi(use_color, ansi_red);
    const green = ansi(use_color, ansi_green);
    const cyan = ansi(use_color, ansi_cyan);
    const dim = ansi(use_color, ansi_dim);
    const reset = ansi(use_color, ansi_reset);

    const esc_path = try escapeTerm(allocator, file_path);
    defer if (esc_path.ptr != file_path.ptr) allocator.free(esc_path);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    errdefer buf = aw.toArrayList();
    const w = &aw.writer;

    if (old_mid.len == 0 and new_mid.len == 0) {
        try w.print("  {s}--- {s}{s}\n", .{ red, esc_path, reset });
        try w.print("  {s}+++ {s}{s}\n", .{ green, esc_path, reset });
        try w.print("  {s}(trailing newline only){s}\n", .{ dim, reset });
        try w.writeByte('\n');
        buf = aw.toArrayList();
        return buf.toOwnedSlice(allocator);
    }

    try w.print("  {s}--- {s}{s}\n", .{ red, esc_path, reset });
    try w.print("  {s}+++ {s}{s}\n", .{ green, esc_path, reset });
    try w.print("  {s}@@ -{d},{d} +{d},{d} @@{s}\n", .{ cyan, p + 1, old_mid.len, p + 1, new_mid.len, reset });
    for (old_lines.items[p -| 2..p]) |line| {
        const esc = try escapeTerm(allocator, line);
        defer if (esc.ptr != line.ptr) allocator.free(esc);
        try w.print("   {s}\n", .{esc});
    }
    for (old_mid) |line| {
        const esc = try escapeTerm(allocator, line);
        defer if (esc.ptr != line.ptr) allocator.free(esc);
        try w.print("  {s}- {s}{s}\n", .{ red, esc, reset });
    }
    for (new_mid) |line| {
        const esc = try escapeTerm(allocator, line);
        defer if (esc.ptr != line.ptr) allocator.free(esc);
        try w.print("  {s}+ {s}{s}\n", .{ green, esc, reset });
    }
    for (old_lines.items[after_start..after_end]) |line| {
        const esc = try escapeTerm(allocator, line);
        defer if (esc.ptr != line.ptr) allocator.free(esc);
        try w.print("   {s}\n", .{esc});
    }
    try w.writeByte('\n');
    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn showDiff(io: compat.Io, allocator: std.mem.Allocator, file_path: []const u8, old: []const u8, new: []const u8, use_color: bool) void {
    const diff = formatUnifiedDiff(allocator, file_path, old, new, use_color) catch return;
    writeStdout(io, diff);
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

/// Start of the first non-blank line at or after `start`, up to `limit`;
/// blank lines are skipped so a stray import's removal window starts at its
/// first comment line rather than the blank run above it.
fn firstNonBlankLineStart(source: []const u8, start: usize, limit: usize) usize {
    var pos = start;
    while (pos < limit) {
        const le = findLineEnd(source, pos);
        if (std.mem.trim(u8, source[pos..le], " \t\r\n").len == 0) {
            pos = le;
        } else {
            return pos;
        }
    }
    return limit;
}

/// True when `text`'s last line is blank (works for LF and CRLF endings).
fn endsWithBlankLine(text: []const u8) bool {
    if (text.len == 0 or text[text.len - 1] != '\n') return false;
    var end = text.len - 1;
    if (end > 0 and text[end - 1] == '\r') end -= 1;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') : (start -= 1) {}
    return start == end;
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

/// Start of the contiguous comment run directly above `line_start`: walks up
/// over `//` lines (excluding `//!`, which document the module and never
/// travel) and stops at the first blank or non-comment line. The returned
/// range is attached to the code below; everything above it is detached
/// header material. Only used by the `--bottom` layout.
fn attachedCommentHeadStart(source: []const u8, line_start: usize) usize {
    var pos = line_start;
    while (pos > 0) {
        const ls = findLineStart(source, pos - 1);
        const trimmed = std.mem.trim(u8, source[ls..pos], " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "//") and !std.mem.startsWith(u8, trimmed, "//!")) {
            pos = ls;
        } else {
            break;
        }
    }
    return pos;
}

/// Append the `//`-prefixed lines of `source[start..end]`, dropping blank
/// lines. Keeps the trailing comments of the import block with the body when
/// the block itself moves to the end of the file.
fn appendCommentLines(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), source: []const u8, start: usize, end: usize) !void {
    var pos = start;
    while (pos < end) {
        const le = findLineEnd(source, pos);
        const trimmed = std.mem.trimStart(u8, source[pos..le], " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "//")) {
            try buf.appendSlice(allocator, source[pos..le]);
        }
        pos = le;
    }
}

const SortByStart = struct {
    fn lt(_: void, a: Import, b: Import) bool {
        return a.start < b.start;
    }
};

/// Remove the stray spans from `source[block_end..]`, appending the gaps to
/// `buf`: each span's comment window (first non-blank line of its attached
/// comments) travels with it, while blank lines separating the import from
/// the code above survive the removal.
fn removeStrays(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), source: []const u8, block_end: usize, strays: []const Import) !void {
    var pos: usize = block_end;
    for (strays) |imp| {
        var raw_start = imp.start;
        if (imp.comment_start) |cs| raw_start = firstNonBlankLineStart(source, cs, imp.start);
        const removal_start = @max(raw_start, pos);
        if (imp.end <= pos) continue;
        try buf.appendSlice(allocator, source[pos..removal_start]);
        pos = imp.end;
    }
    try buf.appendSlice(allocator, source[pos..]);
}

const ProcessResult = struct {
    new_text: []const u8,
    new_block: []const u8,
    block_end: usize,
    changed: bool,
    banned: bool,
    banned_msg: ?[]const u8,
    /// The change is not confined to the block region, so check mode must
    /// diff the full text (block moved, strays hoisted, seam blank inserted,
    /// or body blanks normalized).
    full_diff: bool = false,
};

pub fn processSource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    banned_prefixes: []const []const u8,
    bottom: bool,
) !ProcessResult {
    if (hasSkipComment(source)) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = 0,
            .changed = false,
            .banned = false,
            .banned_msg = null,
        };
    }

    var analysis = try ast_scan.analyze(allocator, source);
    defer analysis.deinit(allocator);

    const block_end = analysis.block_end;
    const imports = analysis.imports.items;
    const aliases = analysis.aliases.items;

    const banned_msg = try scanBannedPatterns(allocator, &analysis, banned_prefixes, source);
    errdefer if (banned_msg) |msg| allocator.free(msg);

    if (imports.len == 0) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = block_end,
            .changed = false,
            .banned = banned_msg != null,
            .banned_msg = banned_msg,
        };
    }

    var stray_imports = std.ArrayListUnmanaged(Import).empty;
    defer stray_imports.deinit(allocator);
    for (imports) |imp| {
        if (imp.stray) {
            try stray_imports.append(allocator, imp);
        }
    }
    for (aliases) |alias| {
        if (alias.stray) {
            try stray_imports.append(allocator, alias);
        }
    }
    if (stray_imports.items.len > 0) {
        std.sort.pdq(Import, stray_imports.items, {}, SortByStart.lt);
    }

    const nl = detectNewline(source);

    var rest: []const u8 = source[block_end..];
    var rest_owned: ?[]const u8 = null;
    errdefer if (rest_owned) |owned| allocator.free(owned);
    var top_cut: usize = block_end;
    if (bottom) {
        var first_span_line_start: usize = source.len;
        for (imports) |imp| first_span_line_start = @min(first_span_line_start, findLineStart(source, imp.start));
        for (aliases) |alias| first_span_line_start = @min(first_span_line_start, findLineStart(source, alias.start));

        // The preamble (//! docs, detached headers, blanks) stays at the top
        // of the file; the comment run directly above the first import is
        // attached to it and travels with the block. Trailing blank lines of
        // the preamble are trimmed — the seam below re-inserts one.
        top_cut = @min(block_end, attachedCommentHeadStart(source, first_span_line_start));
        while (top_cut > 0) {
            const ls = findLineStart(source, top_cut - 1);
            if (std.mem.trim(u8, source[ls..top_cut], " \t\r\n").len == 0) {
                top_cut = ls;
            } else {
                break;
            }
        }

        var rest_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer rest_buf.deinit(allocator);

        // Drop the top-region spans (with their attached comments), keeping
        // only comment lines: inter-span blanks were the block's internal
        // band separation and are rebuilt by the block, while comments after
        // the last span stay attached to the body decl below them.
        var top_spans: std.ArrayListUnmanaged(Import) = .empty;
        defer top_spans.deinit(allocator);
        for (imports) |imp| {
            if (imp.start < block_end) try top_spans.append(allocator, imp);
        }
        for (aliases) |alias| {
            if (alias.start < block_end) try top_spans.append(allocator, alias);
        }
        if (top_spans.items.len > 0) {
            std.sort.pdq(Import, top_spans.items, {}, SortByStart.lt);
            var pos = first_span_line_start;
            for (top_spans.items) |imp| {
                var raw_start = imp.start;
                if (imp.comment_start) |cs| raw_start = firstNonBlankLineStart(source, cs, imp.start);
                const removal_start = @max(raw_start, pos);
                if (imp.end <= pos) continue;
                try appendCommentLines(allocator, &rest_buf, source, pos, removal_start);
                pos = imp.end;
            }
            try appendCommentLines(allocator, &rest_buf, source, pos, block_end);
        }
        try removeStrays(allocator, &rest_buf, source, block_end, stray_imports.items);
        const owned_rest = try rest_buf.toOwnedSlice(allocator);
        rest_owned = owned_rest;
        rest = owned_rest;
    } else if (stray_imports.items.len > 0) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try removeStrays(allocator, &buf, source, block_end, stray_imports.items);
        const owned_rest = try buf.toOwnedSlice(allocator);
        rest_owned = owned_rest;
        rest = owned_rest;
    }

    const new_imports = try buildSortedImportText(allocator, source, imports, aliases, block_end, bottom);
    errdefer allocator.free(new_imports);

    if (bottom) {
        // File layout: preamble, body, blank, import block. Exactly one blank
        // line separates the preamble from the body and the body from the
        // block; already-blank boundaries are not doubled.
        var full_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer full_buf.deinit(allocator);
        try full_buf.appendSlice(allocator, source[0..top_cut]);
        if (top_cut > 0 and rest.len > 0) try full_buf.appendSlice(allocator, nl);
        try full_buf.appendSlice(allocator, rest);
        if (full_buf.items.len > 0 and !endsWithBlankLine(full_buf.items)) {
            // One newline terminates the body's last line, a second one
            // turns it into the separating blank line.
            try full_buf.appendSlice(allocator, nl);
            if (!endsWithBlankLine(full_buf.items)) try full_buf.appendSlice(allocator, nl);
        }
        try full_buf.appendSlice(allocator, new_imports);
        const owned = try collapseBlankLines(allocator, full_buf.items, true);
        if (rest_owned) |owned_rest| allocator.free(owned_rest);
        return .{
            .new_text = owned,
            .new_block = new_imports,
            .block_end = top_cut,
            .changed = !std.mem.eql(u8, source, owned),
            .banned = banned_msg != null,
            .banned_msg = banned_msg,
            .full_diff = true,
        };
    }

    // The sorted block is separated from the body by a blank line unless the
    // block already ends with a blank line or a trailing comment (which stays
    // attached to the decl it documents).
    var last_span_end: usize = 0;
    for (imports) |imp| last_span_end = @max(last_span_end, imp.end);
    for (aliases) |alias| last_span_end = @max(last_span_end, alias.end);
    var has_trailing_comment = false;
    var scan_pos = last_span_end;
    while (scan_pos < block_end) {
        const le = findLineEnd(source, scan_pos);
        const line = std.mem.trim(u8, source[scan_pos..le], " \t\r\n");
        if (std.mem.startsWith(u8, line, "//")) {
            has_trailing_comment = true;
            break;
        }
        if (line.len != 0) break;
        scan_pos = le;
    }
    const junction_blank = !has_trailing_comment and !endsWithBlankLine(new_imports) and rest.len > 0 and rest[0] != '\n' and rest[0] != '\r';

    const full_new = if (junction_blank)
        try std.mem.concat(allocator, u8, &.{ new_imports, nl, rest })
    else
        try std.mem.concat(allocator, u8, &.{ new_imports, rest });
    if (rest_owned) |owned| allocator.free(owned);
    errdefer allocator.free(full_new);
    const collapsed = try collapseBlankLines(allocator, full_new, true);
    const normalized = !std.mem.eql(u8, full_new, collapsed);
    allocator.free(full_new);
    const changed = !std.mem.eql(u8, source, collapsed);

    return .{
        .new_text = collapsed,
        .new_block = new_imports,
        .block_end = block_end,
        .changed = changed,
        .banned = banned_msg != null,
        .banned_msg = banned_msg,
        .full_diff = stray_imports.items.len > 0 or junction_blank or normalized,
    };
}

const CliMode = enum { check, fix };

const ParseError = error{ OutOfMemory, Usage, InvalidMode, MissingBanValue, UnexpectedArg };

pub const Args = struct {
    mode: CliMode,
    targets: std.ArrayListUnmanaged([]const u8),
    banned_prefixes: std.ArrayListUnmanaged([]const u8),
    bottom: bool = false,
    help: bool = false,
    version: bool = false,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.targets.deinit(allocator);
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
    var help = false;
    var show_version = false;
    var bottom = false;

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer targets.deinit(allocator);

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
            if (i + 1 >= args.len) {
                err_msg.* = allocFmt(allocator, "--ban-prefix requires a value", .{});
                return error.MissingBanValue;
            }
            i += 1;
            try banned_prefixes.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--bottom")) {
            bottom = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            err_msg.* = allocFmt(allocator, "Unknown option '{s}'", .{arg});
            return error.UnexpectedArg;
        } else if (mode == null) {
            if (std.mem.eql(u8, arg, "check")) {
                mode = .check;
            } else if (std.mem.eql(u8, arg, "fix")) {
                mode = .fix;
            } else {
                err_msg.* = allocFmt(allocator, "Unknown mode '{s}'. Expected 'check' or 'fix'", .{arg});
                return error.InvalidMode;
            }
        } else {
            try targets.append(allocator, arg);
        }
    }

    if (help or show_version) {
        return .{
            .mode = mode orelse .check,
            .targets = targets,
            .banned_prefixes = banned_prefixes,
            .bottom = bottom,
            .help = help,
            .version = show_version,
        };
    }
    if (mode == null) {
        err_msg.* = allocFmt(allocator, "Missing mode and target", .{});
        return error.Usage;
    }
    if (targets.items.len == 0) {
        err_msg.* = allocFmt(allocator, "Missing target", .{});
        return error.Usage;
    }
    return .{
        .mode = mode.?,
        .targets = targets,
        .banned_prefixes = banned_prefixes,
        .bottom = bottom,
    };
}

const SummaryStats = struct {
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
    const yellow = ansi(use_color, ansi_yellow);
    const red = ansi(use_color, ansi_red);
    const magenta = ansi(use_color, ansi_magenta);
    const reset = ansi(use_color, ansi_reset);
    const file_word = if (stats.files == 1) "file" else "files";
    const ms = @divTrunc(stats.elapsed_ns, std.time.ns_per_ms);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const head = switch (mode) {
        .check => allocFmt(allocator, "  Found {s}{d}{s} of {s}{d}{s} {s} to fix", .{ yellow, stats.changed, reset, yellow, stats.files, reset, file_word }) orelse return null,
        .fix => allocFmt(allocator, "\n  Fixed {s}{d}{s} of {s}{d}{s} {s}", .{ yellow, stats.changed, reset, yellow, stats.files, reset, file_word }) orelse return null,
    };
    defer allocator.free(head);
    out.appendSlice(allocator, head) catch return null;

    if (stats.errors > 0) {
        const seg = allocFmt(allocator, ", {s}{d}{s} failed", .{ red, stats.errors, reset }) orelse return null;
        defer allocator.free(seg);
        out.appendSlice(allocator, seg) catch return null;
    }
    if (stats.banned > 0) {
        const seg = allocFmt(allocator, ", {s}{d}{s} banned", .{ magenta, stats.banned, reset }) orelse return null;
        defer allocator.free(seg);
        out.appendSlice(allocator, seg) catch return null;
    }

    const tail = allocFmt(allocator, " in {s}{d}{s}ms.\n", .{ yellow, ms, reset }) orelse return null;
    defer allocator.free(tail);
    out.appendSlice(allocator, tail) catch return null;
    const owned = out.toOwnedSlice(allocator) catch return null;
    return owned;
}

fn printHelp(io: compat.Io, use_color: bool) void {
    if (use_color) {
        const bold = ansi_bold;
        const yellow = ansi_yellow;
        const reset = ansi_reset;
        printStdout(io,
            \\Usage: zsort [check|fix] <dir|file>... [options]
            \\
            \\{[0]s}Modes:{[1]s}
            \\  {[2]s}check{[1]s}              Verify Zig import ordering; exit code 1 when changes are needed
            \\  {[2]s}fix{[1]s}                Rewrite files, sorting their imports
            \\
            \\{[0]s}Options:{[1]s}
            \\  {[2]s}--ban-prefix <p>{[1]s}   Reject import paths starting with this prefix (repeatable)
            \\  {[2]s}--bottom{[1]s}          Place the import block at the end of the file
            \\  {[2]s}-h, --help{[1]s}         Show this help message
            \\  {[2]s}--version{[1]s}          Print version and exit
            \\
            \\Multiple paths may be given; directories are scanned recursively.
            \\
        , .{ bold, reset, yellow });
    } else {
        printStdout(io,
            \\Usage: zsort [check|fix] <dir|file>... [options]
            \\
            \\Modes:
            \\  check              Verify Zig import ordering; exit code 1 when changes are needed
            \\  fix                Rewrite files, sorting their imports
            \\
            \\Options:
            \\  --ban-prefix <p>   Reject import paths starting with this prefix (repeatable)
            \\  --bottom          Place the import block at the end of the file
            \\  -h, --help         Show this help message
            \\  --version          Print version and exit
            \\
            \\Multiple paths may be given; directories are scanned recursively.
            \\
        , .{});
    }
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
    bottom: bool,
};

fn processFileJob(job: *const FileJob, io: compat.Io) void {
    const allocator = job.slot.arena.allocator();
    const source = compat.readFileAllocZ(io, compat.cwd(), job.path, allocator, 32 * 1024 * 1024) catch |err| {
        job.slot.read_err = @errorName(err);
        return;
    };
    job.slot.source = source;
    job.slot.result = processSource(allocator, source, job.banned, job.bottom) catch |err| {
        job.slot.proc_err = @errorName(err);
        return;
    };
}

pub const main = compat.entry(runMain).main;

/// Parse/usage failures: the reason (red, indented) followed by the usage
/// block (plain, flush left) so the reader gets the fix after the problem.
fn printParseError(io: compat.Io, use_color: bool, err_msg: []const u8) void {
    const red = ansi(use_color, ansi_red);
    const reset = ansi(use_color, ansi_reset);
    printStderr(io, "  {s}{s}{s}\n\n", .{ red, err_msg, reset });
    printStderr(io,
        \\Usage: zsort [check|fix] <dir|file>... [options]
        \\Run 'zsort --help' for details.
        \\
    , .{});
}

fn runMain(allocator: std.mem.Allocator, args: []const []const u8, io: compat.Io) !void {
    const color = compat.isTty(io);
    const color_err = compat.isStderrTty(io);

    const out_green = ansi(color, ansi_bold ++ ansi_green);
    const out_yellow = ansi(color, ansi_yellow);
    const out_reset = ansi(color, ansi_reset);

    const err_red = ansi(color_err, ansi_red);
    const err_yellow = ansi(color_err, ansi_yellow);
    const err_magenta = ansi(color_err, ansi_magenta);
    const err_reset = ansi(color_err, ansi_reset);

    var err_msg: ?[]const u8 = null;
    var parsed = parseArgs(allocator, args, &err_msg) catch |e| switch (e) {
        error.Usage, error.InvalidMode, error.MissingBanValue, error.UnexpectedArg => {
            printParseError(io, color_err, try escapeTerm(allocator, err_msg orelse "invalid arguments"));
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printHelp(io, color);
        return;
    }
    if (parsed.version) {
        printStdout(io, "zsort {s}\n", .{version});
        return;
    }

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var error_count: usize = 0;
    for (parsed.targets.items) |target| {
        const stat = compat.statFile(io, compat.cwd(), target) catch |err| {
            const esc = try escapeTerm(allocator, target);
            defer if (esc.ptr != target.ptr) allocator.free(esc);
            printStderr(io, "  {s}Cannot access '{s}': {s}{s}\n", .{ err_red, esc, @errorName(err), err_reset });
            error_count += 1;
            continue;
        };

        if (stat.kind == .directory) {
            var dir = compat.openDir(io, compat.cwd(), target, .{ .iterate = true }) catch |err| {
                const esc = try escapeTerm(allocator, target);
                defer if (esc.ptr != target.ptr) allocator.free(esc);
                printStderr(io, "  {s}Error opening{s} {s}{s}{s}: {s}{s}{s}\n", .{ err_red, err_reset, err_yellow, esc, err_reset, err_red, @errorName(err), err_reset });
                error_count += 1;
                continue;
            };
            defer compat.close(io, &dir);
            const ignores = try loadGitignore(io, allocator, dir);
            defer {
                for (ignores) |pattern| allocator.free(pattern);
                allocator.free(ignores);
            }
            walkDir(io, allocator, dir, target, &files, ignores) catch |err| {
                if (err == error.OutOfMemory) return err;
                const esc = try escapeTerm(allocator, target);
                defer if (esc.ptr != target.ptr) allocator.free(esc);
                printStderr(io, "  {s}Error scanning{s} {s}{s}{s}: {s}{s}{s}\n", .{ err_red, err_reset, err_yellow, esc, err_reset, err_red, @errorName(err), err_reset });
                error_count += 1;
                continue;
            };
        } else if (stat.kind == .file) {
            try files.append(allocator, target);
        } else {
            const esc = try escapeTerm(allocator, target);
            defer if (esc.ptr != target.ptr) allocator.free(esc);
            printStderr(io, "  {s}'{s}' is neither a file nor a directory{s}\n", .{ err_red, esc, err_reset });
            error_count += 1;
        }
    }

    if (files.items.len == 0) {
        if (error_count == 0) {
            const what: []const u8 = if (parsed.targets.items.len == 1) parsed.targets.items[0] else "the given targets";
            const esc = try escapeTerm(allocator, what);
            defer if (esc.ptr != what.ptr) allocator.free(esc);
            printStderr(io, "  {s}No .zig files found in '{s}'{s}\n", .{ err_red, esc, err_reset });
        }
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
            .bottom = parsed.bottom,
        };
    }

    try compat.runParallel(io, allocator, FileJob, processFileJob, jobs);

    var changed_count: usize = 0;
    var fixed_count: usize = 0;
    var banned_count: usize = 0;

    for (jobs) |*job| {
        const slot = job.slot;
        defer allocator.destroy(slot.arena);
        defer slot.arena.deinit();
        const file_path = job.path;
        const esc_path = try escapeTerm(allocator, file_path);
        defer if (esc_path.ptr != file_path.ptr) allocator.free(esc_path);

        if (slot.read_err) |msg| {
            const esc_msg = try escapeTerm(allocator, msg);
            defer if (esc_msg.ptr != msg.ptr) allocator.free(esc_msg);
            printStderr(io, "  {s}Error reading{s} {s}{s}{s}: {s}{s}{s}\n", .{ err_red, err_reset, err_yellow, esc_path, err_reset, err_red, esc_msg, err_reset });
            error_count += 1;
            continue;
        }
        if (slot.proc_err) |msg| {
            const esc_msg = try escapeTerm(allocator, msg);
            defer if (esc_msg.ptr != msg.ptr) allocator.free(esc_msg);
            printStderr(io, "  {s}Error processing{s} {s}{s}{s}: {s}{s}{s}\n", .{ err_red, err_reset, err_yellow, esc_path, err_reset, err_red, esc_msg, err_reset });
            error_count += 1;
            continue;
        }
        const result = slot.result orelse continue;
        if (result.banned_msg) |msg| {
            const esc_msg = try escapeTerm(allocator, msg);
            defer if (esc_msg.ptr != msg.ptr) allocator.free(esc_msg);
            printStderr(io, "  {s}{s}{s}: {s}banned{s}: {s}\n", .{ err_yellow, esc_path, err_reset, err_magenta, err_reset, esc_msg });
            banned_count += 1;
        }
        if (!result.changed) continue;

        changed_count += 1;

        if (parsed.mode == .fix) {
            fixFile: {
                compat.atomicWrite(io, compat.cwd(), file_path, result.new_text) catch |err| {
                    printStderr(io, "  {s}Error writing{s} {s}{s}{s}: {s}{s}{s}\n", .{ err_red, err_reset, err_yellow, esc_path, err_reset, err_red, @errorName(err), err_reset });
                    error_count += 1;
                    break :fixFile;
                };
                fixed_count += 1;
                printStdout(io, "  {s}Fixed:{s} {s}{s}{s}\n", .{ out_green, out_reset, out_yellow, esc_path, out_reset });
            }
        } else {
            // A block-only diff is only valid when the change is confined to
            // the block region; otherwise diff the full text.
            if (result.full_diff) {
                showDiff(io, allocator, file_path, slot.source, result.new_text, color);
            } else {
                showDiff(io, allocator, file_path, slot.source[0..result.block_end], result.new_block, color);
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
        if (formatSummary(allocator, stats, .check, color)) |summary| {
            printStdout(io, "{s}", .{summary});
        }
        if (changed_count > 0 or error_count > 0 or banned_count > 0) {
            std.process.exit(1);
        }
    } else {
        if (formatSummary(allocator, stats, .fix, color)) |summary| {
            printStdout(io, "{s}", .{summary});
        }
        if (error_count > 0 or banned_count > 0) std.process.exit(1);
    }
}
