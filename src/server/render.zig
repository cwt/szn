const std = @import("std");
const c = std.c;
const testing = std.testing;
const Screen = @import("../screen.zig").Screen;
const Cell = @import("../grid.zig").Cell;
const Colour = @import("../colour.zig").Colour;
const Attr = @import("../grid.zig").Attr;
const Window = @import("../window.zig").Window;
const tty = @import("../tty/tty.zig");

pub const Error = tty.Error || error{OutOfMemory};

pub const Display = struct {
    fd: i32,
    sx: u32,
    sy: u32,
    capture: ?*std.ArrayList(u8) = null,
    capture_allocator: ?std.mem.Allocator = null,

    fn writeBytes(self: Display, bytes: []const u8) Error!void {
        if (self.capture) |cap| {
            try cap.appendSlice(self.capture_allocator.?, bytes);
        } else {
            if (c.write(self.fd, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
        }
    }

    fn writeString(self: Display, str: []const u8) Error!void {
        try self.writeBytes(str);
    }

    fn writeStr(self2: Display, str: [*:0]const u8) Error!void {
        const len = std.mem.len(str);
        try self2.writeBytes(str[0..len]);
    }

    pub fn enterAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[?1049h");
        try self.writeBytes("\x1b[?1000h\x1b[?1006h");
        try self.writeBytes("\x1b[?25l");
    }

    pub fn exitAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[?1000l\x1b[?1006l");
        try self.writeBytes("\x1b[?25h");
        try self.writeBytes("\x1b[?1049l");
    }

    pub fn renderAll(self: Display, screen: *Screen, session_name: []const u8, windows: []const *Window, active_window: ?*Window) Error!void {
        try self.writeBytes("\x1b[?25l");

        try self.renderContent(screen);
        try self.renderStatusBar(session_name, windows, active_window);

        if (screen.cursor.visible) {
            if (screen.copy_mode) |cm| {
                try self.moveTo(cm.cursor_x, cm.cursor_y);
            } else {
                try self.moveTo(screen.cursor.x, screen.cursor.y);
            }
            try self.writeBytes("\x1b[?25h");
        }
    }

    fn renderContent(self: Display, screen: *Screen) Error!void {
        const h = @min(screen.grid.height, self.sy - 1);
        const w = @min(screen.grid.width, self.sx);

        var active_fg = Colour.default_();
        var active_bg = Colour.default_();
        var active_attr = Attr{};

        try self.writeBytes("\x1b[m");

        for (0..h) |y| {
            const combined_idx = (@as(isize, @intCast(screen.grid.history.items.len)) - @as(isize, @intCast(if (screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));
            const cells = if (combined_idx < 0)
                @as(?*const std.ArrayListUnmanaged(Cell), null)
            else if (combined_idx < screen.grid.history.items.len)
                &screen.grid.history.items[@intCast(combined_idx)].cells
            else blk: {
                const visible_y = combined_idx - @as(isize, @intCast(screen.grid.history.items.len));
                break :blk if (visible_y < screen.grid.lines.items.len)
                    &screen.grid.lines.items[@intCast(visible_y)].cells
                else
                    @as(?*const std.ArrayListUnmanaged(Cell), null);
            };

            try self.moveTo(0, @intCast(y));
            for (0..w) |x| {
                var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                if (screen.copy_mode) |cm| {
                    if (cm.isSelected(@intCast(x), @intCast(y))) {
                        cell.attr.reverse = !cell.attr.reverse;
                    }
                }

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
                        break :blk all[0 .. all.len - 1];
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

                    try self.writeBytes(sgr_buf[0..sgr_pos]);
                }

                const cp = cell.char;
                if (cp == 0 or cp == ' ') {
                    try self.writeBytes(" ");
                } else if (cp >= 0x20 and cp != 0x7F) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                        try self.writeBytes("?");
                        continue;
                    };
                    try self.writeBytes(buf[0..len]);
                } else {
                    try self.writeBytes("?");
                }
            }
        }

        try self.writeBytes("\x1b[m");
    }

    fn renderStatusBar(self: Display, session_name: []const u8, windows: []const *Window, active_window: ?*Window) Error!void {
        try self.moveTo(0, self.sy - 1);
        try self.writeBytes("\x1b[7m");

        var col: u32 = 0;

        var buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, " [{s}]", .{session_name}) catch " [default]";
        try self.writeBytes(prefix);
        col += @intCast(prefix.len);

        for (windows, 0..) |win, idx| {
            const is_active = (win == active_window);
            const suffix = if (is_active) "*" else "";
            const win_str = std.fmt.bufPrint(&buf, " {d}:{s}{s}", .{ idx, win.name, suffix }) catch " win";

            if (is_active) {
                try self.writeBytes("\x1b[4m");
            }
            try self.writeBytes(win_str);
            if (is_active) {
                try self.writeBytes("\x1b[24m");
            }
            col += @intCast(win_str.len);
        }

        const max_len = self.sx -| 1;
        while (col < max_len) : (col += 1) {
            try self.writeBytes(" ");
        }

        try self.writeBytes("\x1b[m");
    }

    fn moveTo(self: Display, x: u32, y: u32) Error!void {
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch unreachable;
        try self.writeBytes(seq);
    }
};
