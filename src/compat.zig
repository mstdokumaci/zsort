//! Cross-version std shims for Zig 0.15 (std.fs Dir API) vs 0.16 (std.Io).
//! Every branch is comptime-known, so the dead version's code is never
//! semantically analyzed and both versions compile from this one file.
const builtin = @import("builtin");
const std = @import("std");

pub const is_v016 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

pub const Io = if (is_v016) std.Io else void;
pub const Dir = if (is_v016) std.Io.Dir else std.fs.Dir;
const Entry = if (is_v016) std.Io.Dir.Entry else std.fs.Dir.Entry;
pub const Iterator = if (is_v016) std.Io.Dir.Iterator else std.fs.Dir.Iterator;
const OpenOptions = if (is_v016) std.Io.Dir.OpenOptions else std.fs.Dir.OpenOptions;
const Stat = if (is_v016) std.Io.File.Stat else std.fs.File.Stat;

pub fn cwd() Dir {
    if (is_v016) return std.Io.Dir.cwd();
    return std.fs.cwd();
}

pub fn readFileAlloc(io: Io, dir: Dir, path: []const u8, allocator: std.mem.Allocator, max: usize) ![]u8 {
    if (is_v016) return std.Io.Dir.readFileAlloc(dir, io, path, allocator, .limited(max));
    return dir.readFileAlloc(allocator, path, max);
}

/// Sentinel-terminated read for `std.zig.Ast.parse`, which requires
/// `[:0]const u8`. Both 0.15 and 0.16 accept a sentinel in the options form.
pub fn readFileAllocZ(io: Io, dir: Dir, path: []const u8, allocator: std.mem.Allocator, max: usize) ![:0]u8 {
    if (is_v016) return std.Io.Dir.readFileAllocOptions(dir, io, path, allocator, .limited(max), .of(u8), 0);
    return dir.readFileAllocOptions(allocator, path, max, null, .of(u8), 0);
}

pub fn statFile(io: Io, dir: Dir, path: []const u8) !Stat {
    if (is_v016) return std.Io.Dir.statFile(dir, io, path, .{});
    return dir.statFile(path);
}

pub fn openDir(io: Io, dir: Dir, path: []const u8, options: OpenOptions) !Dir {
    if (is_v016) return std.Io.Dir.openDir(dir, io, path, options);
    return dir.openDir(path, options);
}

pub fn iterate(dir: Dir) Iterator {
    if (is_v016) return std.Io.Dir.iterate(dir);
    return dir.iterate();
}

pub fn next(io: Io, it: *Iterator) !?Entry {
    if (is_v016) return it.next(io);
    return it.next();
}

pub fn close(io: Io, dir: *Dir) void {
    if (is_v016) {
        dir.close(io);
    } else {
        dir.close();
    }
}

pub fn atomicWrite(io: Io, dir: Dir, path: []const u8, contents: []const u8) !void {
    if (is_v016) {
        var af = try std.Io.Dir.createFileAtomic(dir, io, path, .{ .replace = true });
        defer af.deinit(io);
        try std.Io.File.writeStreamingAll(af.file, io, contents);
        try af.replace(io);
        return;
    }
    var buf: [4096]u8 = undefined;
    var af = try dir.atomicFile(path, .{ .write_buffer = &buf });
    defer af.deinit();
    try af.file_writer.interface.writeAll(contents);
    try af.finish();
}

pub fn makePath(io: Io, dir: Dir, path: []const u8) !void {
    if (is_v016) return std.Io.Dir.createDirPath(dir, io, path);
    return dir.makePath(path);
}

pub fn writeFile(io: Io, dir: Dir, sub_path: []const u8, data: []const u8) !void {
    if (is_v016) return std.Io.Dir.writeFile(dir, io, .{ .sub_path = sub_path, .data = data });
    return dir.writeFile(.{ .sub_path = sub_path, .data = data });
}

pub const Timer = if (is_v016) struct {
    io: std.Io,
    started: std.Io.Timestamp,

    pub fn start(io: std.Io) !Timer {
        return .{ .io = io, .started = std.Io.Timestamp.now(io, .awake) };
    }

    pub fn read(self: *Timer) u64 {
        const end = std.Io.Timestamp.now(self.io, .awake);
        return @intCast(self.started.durationTo(end).toNanoseconds());
    }
} else struct {
    inner: std.time.Timer,

    pub fn start(_: void) !Timer {
        return .{ .inner = try std.time.Timer.start() };
    }

    pub fn read(self: *Timer) u64 {
        return self.inner.read();
    }
};

/// The `Io` instance tests should use (0.16 only; `void` on 0.15).
/// Only call this from test code: `std.testing.io` errors outside a test build.
pub fn testIo() Io {
    if (is_v016) return std.testing.io;
    return {};
}

const FileWriter = if (is_v016) std.Io.File.Writer else std.fs.File.Writer;

/// Streaming writer over stdout/stderr: callers create a fresh instance per
/// print call, so it must append at the current file offset. The positional
/// default starts every fresh instance at offset 0 (pwritev), which would
/// clobber earlier output.
pub fn stdoutWriter(io: Io, buffer: []u8) FileWriter {
    if (is_v016) return std.Io.File.stdout().writerStreaming(io, buffer);
    return std.fs.File.stdout().writerStreaming(buffer);
}

pub fn stderrWriter(io: Io, buffer: []u8) FileWriter {
    if (is_v016) return std.Io.File.stderr().writerStreaming(io, buffer);
    return std.fs.File.stderr().writerStreaming(buffer);
}

pub fn isTty(io: Io) bool {
    if (is_v016) {
        return std.Io.File.isTty(std.Io.File.stdout(), io) catch return false;
    }
    return std.posix.isatty(std.fs.File.stdout().handle);
}

pub fn isStderrTty(io: Io) bool {
    if (is_v016) {
        return std.Io.File.isTty(std.Io.File.stderr(), io) catch return false;
    }
    return std.posix.isatty(std.fs.File.stderr().handle);
}

/// Spawn `function` over `jobs` and wait for all of them. `function` must be
/// `fn (*const Job, Io) void`; on 0.15 the `Io` argument is `void`.
pub fn runParallel(io: Io, allocator: std.mem.Allocator, comptime Job: type, comptime function: anytype, jobs: []Job) !void {
    if (is_v016) {
        var g: std.Io.Group = .init;
        for (jobs) |*job| g.async(io, function, .{ job, io });
        try g.await(io);
    } else {
        // SAFETY: `pool` is only written by init() below, never read before it.
        var pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&pool, .{ .allocator = allocator, .n_jobs = null });
        defer pool.deinit();
        var wg: std.Thread.WaitGroup = .{};
        for (jobs) |*job| pool.spawnWg(&wg, function, .{ job, {} });
        pool.waitAndWork(&wg);
    }
}

/// Returns a type whose `main` has the correct signature for the active Zig
/// version; it wires up the arena, command line args, and `Io` and then
/// calls `run_main(allocator, args, io)`.
pub fn entry(comptime run_main: anytype) type {
    const run = run_main;
    return struct {
        fn mainV15() !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const args = try std.process.argsAlloc(allocator);
            try run(allocator, args, {});
        }

        fn mainV16(init: std.process.Init) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const args = try collectArgs(allocator, init.minimal.args);
            try run(allocator, args, init.io);
        }

        pub const main = if (is_v016) mainV16 else mainV15;
    };
}

/// Zig 0.16 has no `argsAlloc`; the args arrive via `Init` and must be
/// collected into a slice. Only reachable on 0.16.
fn collectArgs(allocator: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    while (it.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
    return list.toOwnedSlice(allocator);
}
