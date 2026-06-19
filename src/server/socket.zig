const std = @import("std");
const testing = std.testing;

const c = std.c;

const SOCKET_PATH = "/tmp/zmux.sock";

fn mapErr(rc: c_int) !i32 {
    if (rc >= 0) return rc;
    return switch (std.posix.errno(rc)) {
        .AGAIN => error.WouldBlock,
        .ADDRINUSE => error.AddressInUse,
        .CONNRESET => error.ConnectionReset,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .NOTCONN => error.NotConnected,
        .PIPE => error.BrokenPipe,
        .TIMEDOUT => error.ConnectionTimedOut,
        else => error.Unexpected,
    };
}

pub fn createListener() !i32 {
    _ = c.unlink(SOCKET_PATH);
    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
    errdefer _ = c.close(fd);

    var addr: c.sockaddr.un = .{ .path = [_]u8{0} ** 104 };
    @memcpy(addr.path[0..SOCKET_PATH.len], SOCKET_PATH);

    _ = try mapErr(c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)));

    _ = try mapErr(c.listen(fd, 128));
    return fd;
}

pub fn acceptClient(listener_fd: i32) !i32 {
    var addr: c.sockaddr = undefined;
    var addr_len: c.socklen_t = @sizeOf(c.sockaddr);
    return try mapErr(c.accept(listener_fd, &addr, &addr_len));
}

pub fn closeAndUnlink(fd: i32) void {
    _ = c.close(fd);
    _ = c.unlink(SOCKET_PATH);
}

test "listener creates and closes" {
    const fd = try createListener();
    defer closeAndUnlink(fd);
    try testing.expect(fd >= 0);
}
