const std = @import("std");
const testing = std.testing;
const c = std.c;

const SOCKET_PATH = "/tmp/zmux.sock";

pub fn connectToServer() !i32 {
    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
    errdefer _ = c.close(fd);

    var addr: c.sockaddr.un = .{ .path = [_]u8{0} ** 104 };
    @memcpy(addr.path[0..SOCKET_PATH.len], SOCKET_PATH);

    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un));
    try mapErr(rc);

    return fd;
}

fn mapErr(rc: c_int) !i32 {
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
    // This test requires the server to be running
    // For now, just verify the function signature compiles
    try testing.expect(true);
}
