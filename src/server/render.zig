const std = @import("std");
const c = std.c;
const testing = std.testing;
const Screen = @import("../screen.zig").Screen;
const Cell = @import("../grid.zig").Cell;
const Colour = @import("../colour.zig").Colour;
const Attr = @import("../grid.zig").Attr;

pub const Display = struct {
    fd: i32,
    sx: u32,
    sy: u32,

    pub fn enterAltScreen(self: Display) !void {
        if (c.write(self.fd, "\x1b[?1049h", 8) < 0) return error.WriteFailed;
        if (c.write(self.fd, "\x1b[?1000h\x1b[?1006h", 16) < 0) return error.WriteFailed;
        if (c.write(self.fd, "\x1b[?25l", 6) < 0) return error.WriteFailed;
    }

    pub fn exitAltScreen(self: Display) !void {
        _ = c.write(self.fd, "\x1b[?1000l\x1b[?1006l", 16);
        _ = c.write(self.fd, "\x1b[?25h", 6);
        _ = c.write(self.fd, "\x1b[?1049l", 8);
    }

    pub fn renderAll(self: Display, screen: *Screen, session_name: []const u8, window_count: usize) !void {
        // Hide the cursor during rendering to prevent it from jumping/flickering around the screen
        _ = c.write(self.fd, "\x1b[?25l", 6);

        try self.renderContent(screen);
        try self.renderStatusBar(session_name, window_count);

        // Restore physical cursor to the pane's virtual cursor position
        if (screen.cursor.visible) {
            try self.moveTo(screen.cursor.x, screen.cursor.y);
            _ = c.write(self.fd, "\x1b[?25h", 6);
        }
    }

    fn renderContent(self: Display, screen: *Screen) !void {
        const h = @min(screen.grid.height, self.sy - 1);
        const w = @min(screen.grid.width, self.sx);
        const lines = screen.grid.lines;

        var active_fg = Colour.default_();
        var active_bg = Colour.default_();
        var active_attr = Attr{};

        // Reset attributes at the start
        if (c.write(self.fd, "\x1b[m", 3) < 0) return error.WriteFailed;

        for (0..h) |y| {
            const cells = lines.items[y].cells;
            try self.moveTo(0, @intCast(y));
            for (0..w) |x| {
                const cell = if (x < cells.items.len) cells.items[x] else Cell.empty();

                if (@as(u32, @bitCast(cell.fg)) != @as(u32, @bitCast(active_fg)) or
                    @as(u32, @bitCast(cell.bg)) != @as(u32, @bitCast(active_bg)) or
                    @as(u16, @bitCast(cell.attr)) != @as(u16, @bitCast(active_attr)))
                {
                    active_fg = cell.fg;
                    active_bg = cell.bg;
                    active_attr = cell.attr;

                    var sgr_buf: [128]u8 = undefined;
                    var sgr_pos: usize = 0;

                    sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[m", .{}) catch unreachable).len;

                    const attrFields = comptime blk: {
                        const all = std.meta.fields(Attr);
                        break :blk all[0 .. all.len - 1]; // exclude _padding
                    };
                    const attrCodes = [_]u8{ 1, 2, 3, 4, 5, 7, 8, 9, 53, 4, 4 };

                    inline for (attrFields, 0..) |field, idx| {
                        if (@field(active_attr, field.name)) {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[{}m", .{attrCodes[idx]}) catch unreachable).len;
                        }
                    }

                    switch (active_fg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;5;{}m", .{@as(u8, @truncate(active_fg.value))}) catch unreachable).len;
                        },
                        .rgb => {
                            const rgb = active_fg.toRgb().?;
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable).len;
                        },
                    }

                    switch (active_bg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;5;{}m", .{@as(u8, @truncate(active_bg.value))}) catch unreachable).len;
                        },
                        .rgb => {
                            const rgb = active_bg.toRgb().?;
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable).len;
                        },
                    }

                    if (c.write(self.fd, sgr_buf[0..sgr_pos].ptr, @intCast(sgr_pos)) < 0) return error.WriteFailed;
                }

                const cp = cell.char;
                if (cp == 0 or cp == ' ') {
                    if (c.write(self.fd, " ", 1) < 0) return error.WriteFailed;
                } else if (cp >= 0x20 and cp != 0x7F) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                        if (c.write(self.fd, "?", 1) < 0) return error.WriteFailed;
                        continue;
                    };
                    if (c.write(self.fd, &buf, len) < 0) return error.WriteFailed;
                } else {
                    if (c.write(self.fd, "?", 1) < 0) return error.WriteFailed;
                }
            }
        }

        // Reset attributes at the end
        if (c.write(self.fd, "\x1b[m", 3) < 0) return error.WriteFailed;
    }

    fn renderStatusBar(self: Display, session_name: []const u8, window_count: usize) !void {
        try self.moveTo(0, self.sy - 1);
        if (c.write(self.fd, "\x1b[7m", 4) < 0) return;

        var buf: [256]u8 = undefined;
        const status = try std.fmt.bufPrint(&buf, " zmux | {s} | {d} windows", .{ session_name, window_count });
        const max_len = self.sx -| 1;
        const write_len = @min(status.len, max_len);
        if (c.write(self.fd, status.ptr, @intCast(write_len)) < 0) return;

        var i: u32 = @intCast(write_len);
        while (i < max_len) : (i += 1) {
            if (c.write(self.fd, " ", 1) < 0) return;
        }

        if (c.write(self.fd, "\x1b[m", 3) < 0) return;
    }

    fn moveTo(self: Display, x: u32, y: u32) !void {
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch unreachable;
        if (c.write(self.fd, seq.ptr, @intCast(seq.len)) < 0) return error.WriteFailed;
    }
};
