const std = @import("std");

const compat = @import("compat.zig");

test "per-call writers append at the current offset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = compat.testIo();
    // Mirrors compat.stdoutWriter/stderrWriter: a fresh buffered writer per
    // call. The writer must be streaming; the positional default starts
    // every fresh instance at offset 0 (pwritev), so a second call would
    // clobber the first output.
    if (compat.is_v016) {
        var f = try tmp.dir.createFile(io, "t", .{ .read = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w1 = f.writerStreaming(io, &buf);
        try w1.interface.writeAll("aaa");
        try w1.flush();
        var w2 = f.writerStreaming(io, &buf);
        try w2.interface.writeAll("bbb");
        try w2.flush();
    } else {
        var f = try tmp.dir.createFile("t", .{ .read = true });
        defer f.close();
        var buf: [64]u8 = undefined;
        var w1 = f.writerStreaming(&buf);
        try w1.interface.writeAll("aaa");
        try w1.interface.flush();
        var w2 = f.writerStreaming(&buf);
        try w2.interface.writeAll("bbb");
        try w2.interface.flush();
    }
    const got = try compat.readFileAlloc(io, tmp.dir, "t", std.testing.allocator, 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("aaabbb", got);
}
