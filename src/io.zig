const std = @import("std");

/// Result of a single `writeOnce` attempt.
pub const WriteOutcome = union(enum) {
    wrote: usize,
    would_block,
    closed,
    failed,
};

/// Perform one write(2) of `buf` to `fd`, retrying EINTR internally. The result
/// is classified so each caller can apply its own buffering policy — synchronous
/// inline-retry versus non-blocking stash-and-arm-POLLOUT — without re-deriving
/// the errno interpretation.
///
/// This is the fragment the five hand-rolled write loops in dispatch.zig,
/// server.zig and pty.zig used to copy independently. Copy-paste is exactly how
/// `sendRequestCellSize` drifted into bugs #262, #403 and #472 (bug #520): each
/// site re-implemented INTR/AGAIN/closed/fatal handling with subtly different
/// bugs. Centralising it here means there is one place to get it right.
pub fn writeOnce(fd: i32, buf: []const u8) WriteOutcome {
    if (buf.len == 0) return .{ .wrote = 0 };
    var res: isize = undefined;
    while (true) {
        res = std.c.write(fd, buf.ptr, buf.len);
        if (res >= 0) break;
        const err = std.c.errno(res);
        if (err == .INTR) continue;
        if (err == .AGAIN) return .would_block;
        return .failed;
    }
    if (res == 0) return .closed;
    return .{ .wrote = @as(usize, @intCast(res)) };
}

pub fn writeAll(fd: i32, buf: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < buf.len) {
        switch (writeOnce(fd, buf[off..])) {
            .wrote => |n| off += n,
            .would_block => {
                var req: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
                _ = std.c.nanosleep(&req, null);
            },
            .closed, .failed => return error.WriteFailed,
        }
    }
}

extern "c" fn gettimeofday(tv: *std.c.timeval, tz: ?*anyopaque) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const O_NONBLOCK: c_int = switch (@import("builtin").os.tag) {
    .linux => @as(c_int, 0o4000),
    else => @as(c_int, 0x0004),
};

pub fn currentMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divFloor(@as(i64, @intCast(tv.usec)), 1000);
}

pub fn setNonBlocking(fd: i32) void {
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

pub fn setBlocking(fd: i32) void {
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    }
}
