const std = @import("std");

pub const RawTerminal = struct {
    fd: i32,
    original: std.c.termios = undefined,

    pub fn init(fd: i32) !RawTerminal {
        var original: std.c.termios = undefined;
        if (std.c.tcgetattr(fd, &original) < 0) return error.GetAttrFailed;
        return RawTerminal{ .fd = fd, .original = original };
    }

    pub fn deinit(self: *RawTerminal) void {
        _ = std.c.tcsetattr(self.fd, std.c.TCSAFLUSH, &self.original);
    }
};
