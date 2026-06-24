const std = @import("std");
const c = std.c;

pub const Error = error{
    WriteFailed,
    WriteZero,
    NoSpaceLeft,
};

pub const FdWriter = struct {
    fd: i32,

    pub fn writeAll(self: FdWriter, bytes: []const u8) Error!void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = c.write(self.fd, remaining.ptr, @intCast(remaining.len));
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteZero;
            remaining = remaining[@intCast(n)..];
        }
    }

    pub fn writeByte(self: FdWriter, byte: u8) Error!void {
        var b = [1]u8{byte};
        while (true) {
            const n = c.write(self.fd, &b, 1);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteZero;
            break;
        }
    }

    pub fn print(self: FdWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [1024]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(formatted);
    }
};

const testing = @import("std").testing;

test "fd_writer writeAll writes through pipe" {
    var pipe_fds: [2]i32 = undefined;
    if (c.pipe(&pipe_fds) < 0) return error.Skip;
    defer _ = c.close(pipe_fds[0]);
    defer _ = c.close(pipe_fds[1]);

    const writer = FdWriter{ .fd = pipe_fds[1] };
    try writer.writeAll("hello");

    var buf: [16]u8 = undefined;
    const n = c.read(pipe_fds[0], &buf, buf.len);
    if (n < 0) return error.Skip;
    try testing.expectEqualStrings("hello", buf[0..@intCast(n)]);
}

test "fd_writer writeByte writes through pipe" {
    var pipe_fds: [2]i32 = undefined;
    if (c.pipe(&pipe_fds) < 0) return error.Skip;
    defer _ = c.close(pipe_fds[0]);
    defer _ = c.close(pipe_fds[1]);

    const writer = FdWriter{ .fd = pipe_fds[1] };
    try writer.writeByte('X');

    var buf: [1]u8 = undefined;
    const n = c.read(pipe_fds[0], &buf, buf.len);
    if (n < 0) return error.Skip;
    try testing.expectEqual('X', buf[0]);
}
