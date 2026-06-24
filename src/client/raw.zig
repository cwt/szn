const std = @import("std");
const c = std.c;

pub const Error = error{
    GetAttrFailed,
    SetRawFailed,
};

const VMIN: u6 = switch (@import("builtin").os.tag) {
    .linux => 6,
    .macos, .ios => 16,
    .freebsd => 4,
    else => 6,
};
const VTIME: u6 = switch (@import("builtin").os.tag) {
    .linux => 5,
    .macos, .ios => 17,
    .freebsd => 5,
    else => 5,
};

pub const RawTerminal = struct {
    fd: i32,
    original: std.c.termios = undefined,

    pub fn init(fd: i32) Error!RawTerminal {
        var original: std.c.termios = undefined;
        if (c.tcgetattr(fd, &original) < 0) return error.GetAttrFailed;
        return RawTerminal{ .fd = fd, .original = original };
    }

    pub fn deinit(self: *RawTerminal) void {
        _ = c.tcsetattr(self.fd, c.TCSA.FLUSH, &self.original);
    }

    pub fn setRaw(self: *RawTerminal) Error!void {
        var raw = self.original;
        raw.iflag = .{ .BRKINT = false };
        raw.lflag = .{};
        raw.oflag = .{};
        raw.cc[VMIN] = 1;
        raw.cc[VTIME] = 0;
        if (c.tcsetattr(self.fd, c.TCSA.FLUSH, &raw) < 0) return error.SetRawFailed;
    }
};

const testing = @import("std").testing;

test "VMIN and VTIME match the target platform" {
    switch (@import("builtin").os.tag) {
        .linux => {
            try testing.expectEqual(@as(u6, 6), VMIN);
            try testing.expectEqual(@as(u6, 5), VTIME);
        },
        .macos, .ios => {
            try testing.expectEqual(@as(u6, 16), VMIN);
            try testing.expectEqual(@as(u6, 17), VTIME);
        },
        .freebsd => {
            try testing.expectEqual(@as(u6, 4), VMIN);
            try testing.expectEqual(@as(u6, 5), VTIME);
        },
        else => {},
    }
}
