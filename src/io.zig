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
