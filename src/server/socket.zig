const std = @import("std");
const testing = std.testing;

const c = std.c;
const socket_path = @import("../socket_path.zig");
const pty_mod = @import("pty.zig");

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
    var path_buf: [socket_path.MAX_PATH]u8 = undefined;
    const path = try socket_path.resolve(&path_buf);
    _ = c.unlink(path.ptr);

    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
    errdefer _ = c.close(fd);

    var addr: c.sockaddr.un = .{ .path = [_]u8{0} ** 104 };
    @memcpy(addr.path[0..path.len], path);

    _ = try mapErr(c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)));
    _ = try mapErr(c.listen(fd, 128));

    // Child processes must not inherit the listener socket
    pty_mod.setCloexec(fd);
    return fd;
}

pub fn acceptClient(listener_fd: i32) !i32 {
    var addr: c.sockaddr = undefined;
    var addr_len: c.socklen_t = @sizeOf(c.sockaddr);
    const fd = try mapErr(c.accept(listener_fd, &addr, &addr_len));
    pty_mod.setCloexec(fd);
    return fd;
}

pub fn closeSocket(fd: i32) void {
    _ = c.close(fd);
}

pub fn shutdown() void {
    var path_buf: [socket_path.MAX_PATH]u8 = undefined;
    const path = socket_path.resolve(&path_buf) catch return;
    _ = c.unlink(path.ptr);
}

pub fn socketExists() bool {
    var path_buf: [socket_path.MAX_PATH]u8 = undefined;
    const path = socket_path.resolve(&path_buf) catch return false;
    return c.access(path.ptr, @as(c_int, 0)) == 0;
}

test "listener creates and closes" {
    const fd = try createListener();
    defer closeSocket(fd);
    defer shutdown();
    try testing.expect(fd >= 0);
}
