const std = @import("std");
const c = std.c;

pub const FdWriter = struct {
    fd: i32,

    pub fn writeAll(self: FdWriter, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = c.write(self.fd, remaining.ptr, @intCast(remaining.len));
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteZero;
            remaining = remaining[@intCast(n)..];
        }
    }

    pub fn writeByte(self: FdWriter, byte: u8) !void {
        var b = byte;
        const n = c.write(self.fd, &b, 1);
        if (n < 0) return error.WriteFailed;
    }

    pub fn print(self: FdWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(formatted);
    }
};
