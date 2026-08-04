// zlint-disable no-print

const std = @import("std");

const ast_scan = @import("ast_scan.zig");
const compat = @import("compat.zig");

pub const version = "0.2.0";

pub const class_std_builtin = ast_scan.class_std_builtin;
pub const class_third_party = ast_scan.class_third_party;
pub const class_local = ast_scan.class_local;
pub const Import = ast_scan.Import;
pub const classify = ast_scan.classify;
pub const analyze = ast_scan.analyze;

const findLineEnd = ast_scan.findLineEnd;

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

fn scanBannedPatterns(
    allocator: std.mem.Allocator,
    analysis: *const ast_scan.Analysis,
    banned_prefixes: []const []const u8,
) !?[]const u8 {
    for (analysis.calls.items) |call| {
        if (std.mem.indexOfScalar(usize, analysis.allowed.items, call.offset) == null) {
            return allocFmt(allocator, "inline @import in type expression", .{}) orelse return error.OutOfMemory;
        }
        if (call.path) |path| {
            for (banned_prefixes) |prefix| {
                if (std.mem.startsWith(u8, path, prefix)) {
                    return allocFmt(allocator, "import path starts with banned prefix '{s}'", .{prefix}) orelse return error.OutOfMemory;
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
    return scanBannedPatterns(allocator, &analysis, banned_prefixes);
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
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    errdefer buf = aw.toArrayList();
    const w = &aw.writer;

    if (old_mid.len == 0 and new_mid.len == 0) {
        try w.print("  --- {s}\n", .{file_path});
        try w.print("  +++ {s}\n", .{file_path});
        try w.print("  (trailing newline only)\n", .{});
        try w.writeByte('\n');
        buf = aw.toArrayList();
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
    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn showDiff(io: compat.Io, allocator: std.mem.Allocator, file_path: []const u8, old: []const u8, new: []const u8) void {
    const diff = formatUnifiedDiff(allocator, file_path, old, new) catch return;
    compat.writeStdout(io, diff);
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
    source: [:0]const u8,
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

    var analysis = try ast_scan.analyze(allocator, source);
    defer analysis.deinit(allocator);

    const block_end = analysis.block_end;
    const imports = analysis.imports.items;
    const aliases = analysis.aliases.items;

    const banned_msg = try scanBannedPatterns(allocator, &analysis, banned_prefixes);
    errdefer if (banned_msg) |msg| allocator.free(msg);

    if (imports.len == 0) {
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
    for (imports) |imp| {
        if (imp.stray) {
            try stray_imports.append(allocator, imp);
        }
    }

    var rest: []const u8 = source[block_end..];
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

    const new_imports = try buildSortedImportText(allocator, source, imports, aliases, block_end);
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
    compat.printStdout(io,
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
    const source = compat.readFileAllocZ(io, compat.cwd(), job.path, allocator, 10 * 1024 * 1024) catch |err| {
        job.slot.read_err = @errorName(err);
        return;
    };
    job.slot.source = source;
    job.slot.result = processSource(allocator, source, job.banned) catch |err| {
        job.slot.proc_err = @errorName(err);
        return;
    };
}

pub const main = compat.entry(runMain).main;

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
        compat.printStdout(io, "zsort {s}\n", .{version});
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

    try compat.runParallel(io, allocator, FileJob, processFileJob, jobs);

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
                compat.printStdout(io, "Fixed: {s}\n", .{file_path});
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
        if (formatSummary(allocator, stats, .check, compat.isTty(io))) |summary| {
            compat.printStdout(io, "{s}", .{summary});
        }
        if (changed_count > 0 or error_count > 0 or banned_count > 0) {
            std.process.exit(1);
        }
    } else {
        if (formatSummary(allocator, stats, .fix, compat.isTty(io))) |summary| {
            compat.printStdout(io, "{s}", .{summary});
        }
        if (error_count > 0 or banned_count > 0) std.process.exit(1);
    }
}
