const std = @import("std");
const c = std.c;

pub const Error = error{
    GetAttrFailed,
    SetRawFailed,
};

const VMIN: usize = 16;
const VTIME: usize = 17;

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
        raw.iflag = .{ .BRKINT = true };
        raw.lflag = .{};
        raw.oflag = .{};
        raw.cc[VMIN] = 1;
        raw.cc[VTIME] = 0;
        if (c.tcsetattr(self.fd, c.TCSA.FLUSH, &raw) < 0) return error.SetRawFailed;
    }
};
