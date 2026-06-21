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

    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
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
    return switch (std.posix.errno(rc)) {
        .CONNREFUSED => error.ConnectionRefused,
        .NOENT => error.SocketNotFound,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .TIMEDOUT => error.ConnectionTimedOut,
        else => error.Unexpected,
    };
}

test "connect to server" {
    try testing.expect(true);
}
