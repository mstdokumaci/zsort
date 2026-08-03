//! Cross-version std shims for Zig 0.15 (std.fs Dir API) vs 0.16 (std.Io).
//! Every branch is comptime-known, so the dead version's code is never
//! semantically analyzed and both versions compile from this one file.
const builtin = @import("builtin");
const std = @import("std");

pub const is_v016 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

pub const Io = if (is_v016) std.Io else void;
pub const Dir = if (is_v016) std.Io.Dir else std.fs.Dir;
pub const Entry = if (is_v016) std.Io.Dir.Entry else std.fs.Dir.Entry;
pub const Iterator = if (is_v016) std.Io.Dir.Iterator else std.fs.Dir.Iterator;
pub const OpenOptions = if (is_v016) std.Io.Dir.OpenOptions else std.fs.Dir.OpenOptions;
pub const Stat = if (is_v016) std.Io.File.Stat else std.fs.File.Stat;

pub fn cwd() Dir {
    if (is_v016) return std.Io.Dir.cwd();
    return std.fs.cwd();
}

pub fn readFileAlloc(io: Io, dir: Dir, path: []const u8, allocator: std.mem.Allocator, max: usize) ![]u8 {
    if (is_v016) return std.Io.Dir.readFileAlloc(dir, io, path, allocator, .limited(max));
    return dir.readFileAlloc(allocator, path, max);
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

/// Writer over an `ArrayListUnmanaged(u8)`. 0.15 writes into the list in
/// place; 0.16's `Io.Writer.Allocating` moves the list in and back out.
pub const ListWriter = if (is_v016) struct {
    inner: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) ListWriter {
        return .{ .inner = .fromArrayList(allocator, list) };
    }

    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.inner.writer.print(fmt, args);
    }

    pub fn writeByte(self: *ListWriter, byte: u8) !void {
        try self.inner.writer.writeByte(byte);
    }

    pub fn toArrayList(self: *ListWriter) std.ArrayListUnmanaged(u8) {
        return self.inner.toArrayList();
    }
} else struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) ListWriter {
        return .{ .list = list, .allocator = allocator };
    }

    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) !void {
        var w = self.list.writer(self.allocator);
        try w.print(fmt, args);
    }

    pub fn writeByte(self: *ListWriter, byte: u8) !void {
        var w = self.list.writer(self.allocator);
        try w.writeByte(byte);
    }

    pub fn toArrayList(self: *ListWriter) std.ArrayListUnmanaged(u8) {
        return self.list.*;
    }
};

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
