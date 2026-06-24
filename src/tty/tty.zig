const std = @import("std");
const testing = std.testing;
const colour = @import("../colour.zig");
const grid = @import("../grid.zig");
const screen = @import("../screen.zig");
const Colour = colour.Colour;
const Cell = grid.Cell;
const Attr = grid.Attr;
const CursorStyle = screen.CursorStyle;
const fd_writer = @import("fd_writer.zig");
const char_width = @import("../char_width.zig");
const Writer = std.Io.Writer;

pub const Error = fd_writer.Error;

const attrFields = blk: {
    const all = std.meta.fields(Attr);
    break :blk all[0 .. all.len - 1]; // exclude _padding
};
const attrCodes = [_][]const u8{ "1", "2", "3", "4", "5", "7", "8", "9", "53", "21", "4:3" };

comptime {
    // Guard against Attr field reordering: field count must match attrCodes
    std.debug.assert(attrFields.len == attrCodes.len);
}

pub const Term = struct {
    writer: Writer,
    sx: u32,
    sy: u32,

    cx: i64 = -1,
    cy: i64 = -1,
    fg: ?Colour = null,
    bg: ?Colour = null,
    attrs: Attr = .{},
    cursor_style: CursorStyle = .block,
    cursor_visible: bool = true,
    scroll_region: ?[2]u32 = null,

    pub fn init(writer: Writer, sx: u32, sy: u32) Term {
        return .{
            .writer = writer,
            .sx = sx,
            .sy = sy,
        };
    }

    pub fn invalidate(self: *Term) void {
        self.cx = -1;
        self.cy = -1;
        self.fg = null;
        self.bg = null;
        self.attrs = .{};
        self.cursor_style = .block;
        self.cursor_visible = true;
        self.scroll_region = null;
    }

    pub fn write(self: *Term, bytes: []const u8) Error!void {
        try self.writer.writeAll(bytes);
    }

    pub fn writeByte(self: *Term, byte: u8) Error!void {
        try self.writer.writeByte(byte);
    }

    fn print(self: *Term, comptime fmt: []const u8, args: anytype) Error!void {
        try self.writer.print(fmt, args);
    }

    // ── Cursor ──

    pub fn cursorMove(self: *Term, x: u32, y: u32) Error!void {
        if (self.cx == x and self.cy == y) return;
        self.cx = @intCast(x);
        self.cy = @intCast(y);
        try self.print("\x1b[{};{}H", .{ y + 1, x + 1 });
    }

    pub fn cursorUp(self: *Term, n: u32) Error!void {
        if (n == 0) return;
        if (self.cy >= 0) self.cy -= @min(@as(u64, @intCast(self.cy)), n);
        if (n == 1) {
            try self.write("\x1b[A");
        } else {
            try self.print("\x1b[{}A", .{n});
        }
    }

    pub fn cursorDown(self: *Term, n: u32) Error!void {
        if (n == 0) return;
        if (self.cy >= 0) {
            const max_down = (self.sy -| 1) -| @as(u32, @intCast(self.cy));
            self.cy += @min(max_down, n);
        }
        if (n == 1) {
            try self.write("\x1b[B");
        } else {
            try self.print("\x1b[{}B", .{n});
        }
    }

    pub fn cursorForward(self: *Term, n: u32) Error!void {
        if (n == 0) return;
        if (self.cx >= 0) {
            const max_forward = (self.sx -| 1) -| @as(u32, @intCast(self.cx));
            self.cx += @min(max_forward, n);
        }
        if (n == 1) {
            try self.write("\x1b[C");
        } else {
            try self.print("\x1b[{}C", .{n});
        }
    }

    pub fn cursorBack(self: *Term, n: u32) Error!void {
        if (n == 0) return;
        if (self.cx >= 0) self.cx -= @min(@as(u64, @intCast(self.cx)), n);
        if (n == 1) {
            try self.write("\x1b[D");
        } else {
            try self.print("\x1b[{}D", .{n});
        }
    }

    pub fn cursorHome(self: *Term) Error!void {
        try self.write("\x1b[H");
        self.cx = 0;
        self.cy = 0;
    }

    pub fn cursorHPA(self: *Term, x: u32) Error!void {
        self.cx = @intCast(x);
        try self.print("\x1b[{}G", .{x + 1});
    }

    pub fn cursorVPA(self: *Term, y: u32) Error!void {
        self.cy = @intCast(y);
        try self.print("\x1b[{}d", .{y + 1});
    }

    // ── Attributes ──

    pub fn setAttributes(self: *Term, attrs: Attr) Error!void {
        const changed = @as(u16, @bitCast(attrs)) ^ @as(u16, @bitCast(self.attrs));
        if (changed == 0) return;

        if (@as(u16, @bitCast(attrs)) == 0) {
            try self.resetAttributes();
            return;
        }

        if (@as(u16, @bitCast(self.attrs)) != 0 and (@as(u16, @bitCast(self.attrs)) & ~@as(u16, @bitCast(attrs))) != 0) {
            try self.write("\x1b[m");
            self.fg = null;
            self.bg = null;
        }

        self.attrs = attrs;

        try self.write("\x1b[");
        var first = true;
        inline for (attrFields, 0..) |field, i| {
            if (@field(attrs, field.name)) {
                if (!first) try self.writeByte(';');
                try self.write(attrCodes[i]);
                first = false;
            }
        }
        try self.writeByte('m');
    }

    pub fn resetAttributes(self: *Term) Error!void {
        try self.write("\x1b[m");
        self.attrs = .{};
        self.fg = null;
        self.bg = null;
    }

    pub fn sgr0(self: *Term) Error!void {
        try self.resetAttributes();
    }

    pub fn setForeground(self: *Term, fg: Colour) Error!void {
        if (self.fg != null and @as(u32, @bitCast(fg)) == @as(u32, @bitCast(self.fg.?))) return;
        self.fg = fg;
        switch (fg.tag) {
            .default_, .terminal => try self.write("\x1b[39m"),
            .indexed => try self.print("\x1b[38;5;{}m", .{@as(u8, @truncate(fg.value))}),
            .rgb => {
                const rgb = fg.toRgb().?;
                try self.print("\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] });
            },
        }
    }

    pub fn setBackground(self: *Term, bg: Colour) Error!void {
        if (self.bg != null and @as(u32, @bitCast(bg)) == @as(u32, @bitCast(self.bg.?))) return;
        self.bg = bg;
        switch (bg.tag) {
            .default_, .terminal => try self.write("\x1b[49m"),
            .indexed => try self.print("\x1b[48;5;{}m", .{@as(u8, @truncate(bg.value))}),
            .rgb => {
                const rgb = bg.toRgb().?;
                try self.print("\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] });
            },
        }
    }

    // ── Clearing ──

    pub fn clearToEOL(self: *Term) Error!void {
        try self.write("\x1b[K");
    }

    pub fn clearToSOL(self: *Term) Error!void {
        try self.write("\x1b[1K");
    }

    pub fn clearLine(self: *Term) Error!void {
        try self.write("\x1b[2K");
    }

    pub fn clearToEOS(self: *Term) Error!void {
        try self.write("\x1b[J");
    }

    pub fn clearToSOS(self: *Term) Error!void {
        try self.write("\x1b[1J");
    }

    pub fn clearScreen(self: *Term) Error!void {
        try self.write("\x1b[2J");
    }

    pub fn eraseChars(self: *Term, n: u32) Error!void {
        try self.print("\x1b[{}X", .{n});
    }

    // ── Scroll region ──

    pub fn setScrollRegion(self: *Term, top: u32, bottom: u32) Error!void {
        self.scroll_region = .{ top, bottom };
        try self.print("\x1b[{};{}r", .{ top + 1, bottom + 1 });
    }

    pub fn resetScrollRegion(self: *Term) Error!void {
        self.scroll_region = null;
        try self.write("\x1b[r");
    }

    // ── Alt screen ──

    pub fn enterAltScreen(self: *Term) Error!void {
        try self.write("\x1b[?1049h");
        self.invalidate();
    }

    pub fn exitAltScreen(self: *Term) Error!void {
        try self.write("\x1b[?1049l");
        self.invalidate();
    }

    // ── Insert / Delete ──

    pub fn insertChars(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[@");
        } else {
            try self.print("\x1b[{}@", .{n});
        }
    }

    pub fn deleteChars(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[P");
        } else {
            try self.print("\x1b[{}P", .{n});
        }
    }

    pub fn insertLines(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[L");
        } else {
            try self.print("\x1b[{}L", .{n});
        }
    }

    pub fn deleteLines(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[M");
        } else {
            try self.print("\x1b[{}M", .{n});
        }
    }

    pub fn reverseIndex(self: *Term) Error!void {
        try self.write("\x1bM");
        if (self.cy > 0) self.cy -= 1;
    }

    pub fn scrollUp(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[S");
        } else {
            try self.print("\x1b[{}S", .{n});
        }
    }

    pub fn scrollDown(self: *Term, n: u32) Error!void {
        if (n == 1) {
            try self.write("\x1b[T");
        } else {
            try self.print("\x1b[{}T", .{n});
        }
    }

    // ── Cursor style ──

    pub fn setCursorStyle(self: *Term, style: CursorStyle) Error!void {
        if (style == self.cursor_style and self.cursor_visible) return;
        self.cursor_style = style;
        const n: u8 = switch (style) {
            .block => if (self.cursor_visible) 1 else 2,
            .underline => if (self.cursor_visible) 3 else 4,
            .bar => if (self.cursor_visible) 5 else 6,
        };
        try self.print("\x1b[{} q", .{n});
    }

    pub fn showCursor(self: *Term, show: bool) Error!void {
        if (show == self.cursor_visible) return;
        self.cursor_visible = show;
        if (show) {
            try self.write("\x1b[?25h");
        } else {
            try self.write("\x1b[?25l");
        }
    }

    // ── Sync ──

    pub fn syncBegin(self: *Term) Error!void {
        try self.write("\x1b[?2026h");
    }

    pub fn syncEnd(self: *Term) Error!void {
        try self.write("\x1b[?2026l");
    }

    // ── Mouse ──

    pub fn setMouseSGR(self: *Term, enable: bool) Error!void {
        if (enable) {
            try self.write("\x1b[?1000h\x1b[?1002h\x1b[?1006h");
        } else {
            try self.write("\x1b[?1006l\x1b[?1002l\x1b[?1000l");
        }
    }

    // ── Mode ──

    // ── Drawing ──

    pub fn writeCell(self: *Term, cell: Cell) Error!void {
        // Skip padding cells — they belong to the previous wide character
        if (cell.is_padding) return;

        try self.setAttributes(cell.attr);
        try self.setForeground(cell.fg);
        try self.setBackground(cell.bg);

        var buf: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(cell.char, &buf) catch {
            try self.write("?");
        if (self.cx >= 0) self.cx += char_width.charWidth(cell.char);
            return;
        };
        try self.write(buf[0..encoded_len]);

        if (cell.comb1 != 0) {
            const cp = char_width.combiningCodepoint(cell.comb1);
            if (cp != 0) {
                const clen = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (clen > 0) {
                    try self.write(buf[0..clen]);
                } else {
                    try self.write("?");
                }
            }
        }
        if (cell.comb2 != 0) {
            const cp = char_width.combiningCodepoint(cell.comb2);
            if (cp != 0) {
                const clen = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (clen > 0) {
                    try self.write(buf[0..clen]);
                } else {
                    try self.write("?");
                }
            }
        }

        if (self.cx >= 0) self.cx += 1;
    }

    pub fn drawCell(self: *Term, _x: u32, _y: u32, cell: Cell) Error!void {
        try self.cursorMove(_x, _y);
        try self.writeCell(cell);
    }

    // ── Line drawing ──

    pub fn drawLine(self: *Term, s: *screen.Screen, ly: u32) Error!void {
        const width = s.grid.width;
        var col: u32 = 0;
        var last_was_space: bool = true;

        while (col < width) {
            const cell = s.grid.getCell(col, ly);
            if (cell.char == ' ' and last_was_space) {
                col += 1;
                continue;
            }
            if (self.cx < 0 or self.cy < 0 or col != @as(u32, @intCast(self.cx)) or ly != @as(u32, @intCast(self.cy))) {
                try self.cursorMove(col, ly);
            }
            try self.writeCell(cell);
            last_was_space = (cell.char == ' ');
            col += 1;
        }

        // Clear trailing spaces
        if (last_was_space) {
            try self.cursorMove(width -| 1, ly);
            try self.clearToEOL();
        }
    }

    pub fn drawScreen(self: *Term, s: *screen.Screen) Error!void {
        var y: u32 = 0;
        while (y < s.grid.height) : (y += 1) {
            try self.drawLine(s, y);
        }
    }
};

// ── Tests ──

fn written(w: *const Writer) []const u8 {
    return w.buffer[0..w.end];
}

test "init term" {
    var buf: [64]u8 = undefined;
    const term = Term.init(Writer.fixed(&buf), 80, 24);
    try testing.expectEqual(@as(u32, 80), term.sx);
    try testing.expectEqual(@as(u32, 24), term.sy);
}

test "cursor move CUP" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.cursorMove(5, 10);
    try testing.expectEqualSlices(u8, "\x1b[11;6H", written(&term.writer));
}

test "cursor home" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.cursorHome();
    try testing.expectEqualSlices(u8, "\x1b[H", written(&term.writer));
}

test "cursor up" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cy = 10;
    try term.cursorUp(3);
    try testing.expectEqualSlices(u8, "\x1b[3A", written(&term.writer));
}

test "cursor down" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cy = 10;
    try term.cursorDown(3);
    try testing.expectEqualSlices(u8, "\x1b[3B", written(&term.writer));
}

test "cursor forward" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cx = 10;
    try term.cursorForward(5);
    try testing.expectEqualSlices(u8, "\x1b[5C", written(&term.writer));
}

test "cursor back" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cx = 10;
    try term.cursorBack(3);
    try testing.expectEqualSlices(u8, "\x1b[3D", written(&term.writer));
}

test "cursor HPA" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.cursorHPA(15);
    try testing.expectEqualSlices(u8, "\x1b[16G", written(&term.writer));
}

test "cursor VPA" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.cursorVPA(20);
    try testing.expectEqualSlices(u8, "\x1b[21d", written(&term.writer));
}

test "cursor single step uses short form" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.cursorUp(1);
    try testing.expectEqualSlices(u8, "\x1b[A", written(&term.writer));
}

test "cursor already at position is no-op" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cx = 5;
    term.cy = 10;
    try term.cursorMove(5, 10);
    try testing.expectEqual(@as(usize, 0), written(&term.writer).len);
}

test "set foreground RGB colour" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setForeground(Colour.fromRgb(255, 128, 0));
    try testing.expectEqualSlices(u8, "\x1b[38;2;255;128;0m", written(&term.writer));
}

test "set foreground indexed colour" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setForeground(Colour.fromIndexed(42));
    try testing.expectEqualSlices(u8, "\x1b[38;5;42m", written(&term.writer));
}

test "set foreground default colour" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setForeground(Colour.default_());
    try testing.expectEqualSlices(u8, "\x1b[39m", written(&term.writer));
}

test "set background RGB colour" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setBackground(Colour.fromRgb(0, 100, 200));
    try testing.expectEqualSlices(u8, "\x1b[48;2;0;100;200m", written(&term.writer));
}

test "set background default colour" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setBackground(Colour.default_());
    try testing.expectEqualSlices(u8, "\x1b[49m", written(&term.writer));
}

test "same colour is no-op" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setForeground(Colour.fromRgb(255, 0, 0));
    term.writer.end = 0;
    try term.setForeground(Colour.fromRgb(255, 0, 0));
    try testing.expectEqual(@as(usize, 0), written(&term.writer).len);
}

test "reset attributes" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.resetAttributes();
    try testing.expectEqualSlices(u8, "\x1b[m", written(&term.writer));
    try testing.expectEqual(@as(?Colour, null), term.fg);
    try testing.expectEqual(@as(?Colour, null), term.bg);
}

test "clear to end of line" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.clearToEOL();
    try testing.expectEqualSlices(u8, "\x1b[K", written(&term.writer));
}

test "clear to start of line" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.clearToSOL();
    try testing.expectEqualSlices(u8, "\x1b[1K", written(&term.writer));
}

test "clear entire line" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.clearLine();
    try testing.expectEqualSlices(u8, "\x1b[2K", written(&term.writer));
}

test "clear to end of screen" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.clearToEOS();
    try testing.expectEqualSlices(u8, "\x1b[J", written(&term.writer));
}

test "clear screen" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.clearScreen();
    try testing.expectEqualSlices(u8, "\x1b[2J", written(&term.writer));
}

test "erase characters" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.eraseChars(10);
    try testing.expectEqualSlices(u8, "\x1b[10X", written(&term.writer));
}

test "set scroll region" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setScrollRegion(2, 20);
    try testing.expectEqualSlices(u8, "\x1b[3;21r", written(&term.writer));
}

test "reset scroll region" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setScrollRegion(2, 20);
    term.writer.end = 0;
    try term.resetScrollRegion();
    try testing.expectEqualSlices(u8, "\x1b[r", written(&term.writer));
    try testing.expectEqual(@as(?[2]u32, null), term.scroll_region);
}

test "alt screen enter/exit" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.enterAltScreen();
    try testing.expectEqualSlices(u8, "\x1b[?1049h", written(&term.writer));
    term.writer.end = 0;
    try term.exitAltScreen();
    try testing.expectEqualSlices(u8, "\x1b[?1049l", written(&term.writer));
}

test "insert/delete lines" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.insertLines(1);
    try testing.expectEqualSlices(u8, "\x1b[L", written(&term.writer));
    term.writer.end = 0;
    try term.deleteLines(3);
    try testing.expectEqualSlices(u8, "\x1b[3M", written(&term.writer));
}

test "insert/delete characters" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.insertChars(1);
    try testing.expectEqualSlices(u8, "\x1b[@", written(&term.writer));
    term.writer.end = 0;
    try term.deleteChars(5);
    try testing.expectEqualSlices(u8, "\x1b[5P", written(&term.writer));
}

test "reverse index" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.reverseIndex();
    try testing.expectEqualSlices(u8, "\x1bM", written(&term.writer));
}

test "scroll up/down" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.scrollUp(1);
    try testing.expectEqualSlices(u8, "\x1b[S", written(&term.writer));
    term.writer.end = 0;
    try term.scrollDown(4);
    try testing.expectEqualSlices(u8, "\x1b[4T", written(&term.writer));
}

test "set cursor style" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    // cursor_visible defaults to true → should emit blinking variant
    try term.setCursorStyle(.bar);
    try testing.expectEqualSlices(u8, "\x1b[5 q", written(&term.writer));
}

test "show/hide cursor" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.showCursor(false);
    try testing.expectEqualSlices(u8, "\x1b[?25l", written(&term.writer));
    term.writer.end = 0;
    try term.showCursor(true);
    try testing.expectEqualSlices(u8, "\x1b[?25h", written(&term.writer));
}

test "sync begin/end" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.syncBegin();
    try testing.expectEqualSlices(u8, "\x1b[?2026h", written(&term.writer));
    term.writer.end = 0;
    try term.syncEnd();
    try testing.expectEqualSlices(u8, "\x1b[?2026l", written(&term.writer));
}

test "write cell writes char with attributes" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    const cell = Cell{
        .char = 'X',
        .attr = .{ .bold = true },
        .fg = Colour.fromRgb(255, 0, 0),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;0m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[49m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
}

test "writeCell increments cx for combining chars — bug #130" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    term.cx = 0;

    // Write a cell with a combining character
    var cell = Cell.withChar('e');
    cell.comb1 = 0x0301;
    try term.writeCell(cell);
    // cx should be incremented even with combining char present
    try testing.expectEqual(@as(i64, 1), term.cx);
}

test "draw cell positions and writes" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    const cell = Cell.withChar('Z');
    try term.drawCell(10, 5, cell);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[6;11H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Z") != null);
}

test "draw line skips leading spaces" {
    var buf: [256]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    var s = try screen.Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    try s.writeStr("Hello");

    try term.drawLine(&s, 0);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

test "draw line clears trailing spaces" {
    var buf: [512]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    var s = try screen.Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    try s.writeStr("Hello");

    try term.drawLine(&s, 0);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[K") != null);
}

test "invalidate resets cached state" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    term.cx = 10;
    term.cy = 5;
    term.fg = Colour.fromRgb(255, 0, 0);
    term.invalidate();

    try testing.expectEqual(@as(i64, -1), term.cx);
    try testing.expectEqual(@as(i64, -1), term.cy);
    try testing.expectEqual(@as(?Colour, null), term.fg);
}

test "drawLine handles invalidated cursor without panic — bug #83" {
    var buf: [512]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    var s = try screen.Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    try s.writeStr("Hello");

    // Force cx >= 0 but cy = -1 so the second expression in the
    // drawLine cursor check is evaluated.
    term.cx = 0;
    term.cy = -1;

    // Should not panic on @intCast(-1)
    try term.drawLine(&s, 0);
    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

test "mouse SGR mode" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);
    try term.setMouseSGR(true);
    const out1 = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out1, "\x1b[?1000h") != null);
    try testing.expect(std.mem.indexOf(u8, out1, "\x1b[?1006h") != null);
    term.writer.end = 0;
    try term.setMouseSGR(false);
    const out2 = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out2, "\x1b[?1000l") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "\x1b[?1006l") != null);
}

test "double underline emits SGR 21 — C2 fix" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    const cell = Cell{
        .char = 'X',
        .attr = .{ .double_underline = true },
        .fg = Colour.default_(),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[21m") != null);
}

test "curly underline emits SGR 4:3 — C2 fix" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    const cell = Cell{
        .char = 'X',
        .attr = .{ .curly_underline = true },
        .fg = Colour.default_(),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[4:3m") != null);
}

test "setAttributes turns off removed attrs — bold to italic" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    var cell = Cell{
        .char = 'A',
        .attr = .{ .bold = true },
        .fg = Colour.default_(),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);
    term.writer.end = 0;

    cell.attr = .{ .italic = true };
    try term.writeCell(cell);

    const out = written(&term.writer);
    // Must contain reset, then italic
    const reset_pos = std.mem.indexOf(u8, out, "\x1b[m") orelse return error.TestFailed;
    const italic_pos = std.mem.indexOf(u8, out, "\x1b[3m") orelse return error.TestFailed;
    try testing.expect(reset_pos < italic_pos);
    try testing.expect(std.mem.indexOf(u8, out, "A") != null);
}

test "setAttributes adds attrs without reset when no bits removed" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    var cell = Cell{
        .char = 'A',
        .attr = .{ .bold = true },
        .fg = Colour.default_(),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);
    term.writer.end = 0;

    cell.attr = .{ .bold = true, .italic = true };
    try term.writeCell(cell);

    const out = written(&term.writer);
    // Should NOT contain reset — only combined attr sequence
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[m") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;3m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "A") != null);
}

test "setAttributes reset does not clobber colors — C3 fix" {
    var buf: [128]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 80, 24);

    // First set some attrs + color
    var cell = Cell{
        .char = 'A',
        .attr = .{ .bold = true, .italic = true },
        .fg = Colour.fromRgb(255, 0, 0),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);
    term.writer.end = 0;

    // Now write a cell with fewer attrs — triggers reset path
    cell = Cell{
        .char = 'B',
        .attr = .{ .bold = true },
        .fg = Colour.fromRgb(0, 255, 0),
        .bg = Colour.default_(),
    };
    try term.writeCell(cell);

    const out = written(&term.writer);
    // The reset (\x1b[m) must be followed by color sequences,
    // not preceded by orphaned color escapes
    const reset_pos = std.mem.indexOf(u8, out, "\x1b[m") orelse return error.TestFailed;
    const fg_pos = std.mem.indexOf(u8, out, "\x1b[38;2;0;255;0m") orelse return error.TestFailed;
    try testing.expect(reset_pos < fg_pos);
    try testing.expect(std.mem.indexOf(u8, out, "B") != null);
}

test "draw screen draws all lines" {
    var buf: [1024]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 5, 3);

    var s = try screen.Screen.init(testing.allocator, 5, 3);
    defer s.deinit();
    try s.writeStr("AB");
    try s.writeStr("\n");
    try s.writeStr("CD");
    try s.writeStr("\n");
    try s.writeStr("EF");

    try term.drawScreen(&s);

    const out = written(&term.writer);
    try testing.expect(std.mem.indexOf(u8, out, "AB") != null);
    try testing.expect(std.mem.indexOf(u8, out, "CD") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EF") != null);
}

test "cursorDown/cursorForward with zero dimensions — bug #128" {
    var buf: [64]u8 = undefined;
    var term = Term.init(Writer.fixed(&buf), 0, 0);
    try term.cursorDown(1);
    try term.cursorForward(1);
}
