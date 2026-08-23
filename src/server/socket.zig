const std = @import("std");
const testing = std.testing;

const c = std.c;
const socket_path = @import("../socket_path.zig");
const pty_mod = @import("pty.zig");

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    BufferTooSmall,
    WouldBlock,
    AddressInUse,
    ConnectionReset,
    Interrupted,
    InvalidArgument,
    SystemResources,
    NotConnected,
    BrokenPipe,
    ConnectionTimedOut,
    ListenerFailed,
    AcceptFailed,
    Unexpected,
};

fn mapErr(rc: c_int) Error!i32 {
    if (rc >= 0) return rc;
    return switch (std.c.errno(rc)) {
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

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

/// Try to connect to a (possibly live) unix socket at `path`. Success means
/// another szn server is serving it; failure means the path is free or the
/// socket is stale (bug #378).
fn connectProbeUnix(path: [*:0]const u8) Error!void {
    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
    defer _ = c.close(fd);
    var addr = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    const plen = std.mem.len(path);
    if (@hasField(c.sockaddr.un, "len")) {
        addr.len = @intCast(@offsetOf(c.sockaddr.un, "path") + plen);
    }
    @memcpy(addr.path[0..plen], path[0..plen]);
    _ = try mapErr(c.connect(fd, @ptrCast(&addr), @as(c.socklen_t, @intCast(@offsetOf(c.sockaddr.un, "path") + plen + 1))));
}

pub fn createListener() Error!i32 {
    var path_buf: [socket_path.MAX_PATH]u8 = undefined;
    const path = try socket_path.resolve(&path_buf);

    // Probe before unlinking: an existing live endpoint means another server
    // already owns this socket path. Blindly unlinking stole the endpoint and
    // orphaned the first server's clients (bug #378).
    if (connectProbeUnix(path)) |_| {
        std.log.err("socket {s} is served by an existing szn; refusing to steal it", .{path});
        return error.AddressInUse;
    } else |_| {
        // ECONNREFUSED etc. — stale socket from a dead server: safe to replace.
    }
    _ = c.unlink(path.ptr);

    const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
    errdefer _ = c.close(fd);

    var addr = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    if (@hasField(c.sockaddr.un, "len")) {
        addr.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len);
    }
    @memcpy(addr.path[0..path.len], path);

    _ = try mapErr(c.bind(fd, @ptrCast(&addr), @as(c.socklen_t, @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1))));
    // Owner-only access regardless of umask: the /tmp fallback in particular
    // would otherwise be world-connectable under umask 000 (bug #378).
    _ = c.chmod(path.ptr, 0o700);
    _ = try mapErr(c.listen(fd, 128));

    // Child processes must not inherit the listener socket
    pty_mod.setCloexec(fd);
    return fd;
}

pub fn acceptClient(listener_fd: i32) Error!i32 {
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
