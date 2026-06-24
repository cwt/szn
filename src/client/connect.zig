const std = @import("std");
const testing = std.testing;
const c = std.c;
const socket_path = @import("../socket_path.zig");

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    BufferTooSmall,
    SocketNotFound,
    ConnectionRefused,
    Interrupted,
    WouldBlock,
    ConnectionTimedOut,
    Unexpected,
};

pub fn connectToServer() Error!i32 {
    var path_buf: [socket_path.MAX_PATH]u8 = undefined;
    const path = try socket_path.resolve(&path_buf);

    const sock_rc = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    const fd = try mapErr(sock_rc);
    errdefer _ = c.close(fd);

    var addr = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    if (@hasField(c.sockaddr.un, "len")) {
        addr.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len);
    }
    @memcpy(addr.path[0..path.len], path);

    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un));
    _ = try mapErr(rc);

    return fd;
}

fn mapErr(rc: c_int) Error!i32 {
    if (rc >= 0) return rc;
    // std.c.errno reads _errno().* when rc == -1, giving the actual error.
    // std.posix.errno(rc) derives errno from -rc which is always 1 for -1.
    return switch (c.errno(rc)) {
        .CONNREFUSED => error.ConnectionRefused,
        .NOENT => error.SocketNotFound,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .TIMEDOUT => error.ConnectionTimedOut,
        else => error.Unexpected,
    };
}

test "mapErr reads actual errno, not derived from rc" {
    // Bug #82: std.posix.errno(rc) derives errno from -rc, always 1 for rc == -1.
    // c.errno(rc) reads _errno().* directly. Verify correct errors map.
    std.c._errno().* = 2; // ENOENT
    try testing.expectEqual(error.SocketNotFound, mapErr(-1));

    std.c._errno().* = 61; // ECONNREFUSED
    try testing.expectEqual(error.ConnectionRefused, mapErr(-1));

    std.c._errno().* = 4; // EINTR
    try testing.expectEqual(error.Interrupted, mapErr(-1));
}

test "connectToServer fails gracefully when no server running" {
    // No server socket exists, so connectToServer should return
    // an error (SocketNotFound or ConnectionRefused) without UB.
    const result = connectToServer();
    try testing.expect(result == error.SocketNotFound or
        result == error.ConnectionRefused or
        result == error.Unexpected);
}
