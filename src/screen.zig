const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const grid = @import("grid.zig");
const Cell = grid.Cell;
const Grid = grid.Grid;

pub const Cursor = struct {
    x: u32 = 0,
    y: u32 = 0,
    visible: bool = true,
    style: CursorStyle = .block,
    blink: bool = true,
};

pub const CursorStyle = enum(u8) {
    block,
    underline,
    bar,
};

pub const Mode = packed struct(u32) {
    insert: bool = false,
    keypad: bool = false,
    line_wrap: bool = true,
    mouse_standard: bool = false,
    mouse_button: bool = false,
    mouse_utf8: bool = false,
    mouse_sgr: bool = false,
    focus: bool = false,
    paste: bool = false,
    alt_screen: bool = false,
    cursor: bool = true,
    origin: bool = false,
    _padding: u20 = 0,
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    grid: Grid,
    alt_grid: ?Grid = null,
    cursor: Cursor = .{},
    mode: Mode = .{},
    scroll_region: ?[2]u32 = null,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Screen {
        return Screen{
            .allocator = allocator,
            .grid = try Grid.init(allocator, width, height),
        };
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        if (self.alt_grid) |*g| g.deinit();
    }

    pub fn resize(self: *Screen, width: u32, height: u32) !void {
        self.grid.width = width;
        try self.grid.resize(height);
        if (self.alt_grid) |*g| {
            g.width = width;
            try g.resize(height);
        }
        self.cursor.x = @min(self.cursor.x, width -| 1);
        self.cursor.y = @min(self.cursor.y, height -| 1);
    }

    pub fn writeChar(self: *Screen, char: u21) !void {
        if (char == '\n') {
            self.cursor.x = 0;
            if (self.cursor.y + 1 >= self.grid.height) {
                try self.grid.scrollUp();
            } else {
                self.cursor.y += 1;
            }
            self.dirty = true;
            return;
        }
        if (char == '\r') {
            self.cursor.x = 0;
            self.dirty = true;
            return;
        }
        if (char == '\t') {
            const tab_stop: u32 = 8;
            self.cursor.x = ((self.cursor.x / tab_stop) + 1) * tab_stop;
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = self.grid.width - 1;
            }
            self.dirty = true;
            return;
        }
        if (char < 0x20 and char != '\x1b') return;

        if (self.mode.insert) {
            var x = self.grid.width - 1;
            while (x > self.cursor.x) : (x -= 1) {
                const prev = self.grid.getCell(x - 1, self.cursor.y);
                self.grid.setCell(x, self.cursor.y, prev);
            }
        }

        self.grid.setCell(self.cursor.x, self.cursor.y, Cell.withChar(char));
        self.dirty = true;

        if (self.mode.line_wrap) {
            self.cursor.x += 1;
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                } else {
                    self.cursor.y += 1;
                }
            }
        } else {
            self.cursor.x = @min(self.cursor.x + 1, self.grid.width - 1);
        }
    }

    pub fn writeStr(self: *Screen, s: []const u8) !void {
        for (s) |c| {
            try self.writeChar(c);
        }
    }

    pub fn setCursor(self: *Screen, x: u32, y: u32) void {
        self.cursor.x = @min(x, self.grid.width -| 1);
        self.cursor.y = @min(y, self.grid.height -| 1);
        self.dirty = true;
    }

    pub fn clearLine(self: *Screen, y: u32) void {
        self.grid.clearLine(y);
        self.dirty = true;
    }

    pub fn clearScreen(self: *Screen) void {
        self.grid.clear();
        self.dirty = true;
    }

    pub fn useAltScreen(self: *Screen, enable: bool) !void {
        if (enable and self.alt_grid == null) {
            var new_alt = try Grid.init(self.allocator, self.grid.width, self.grid.height);
            std.mem.swap(Grid, &self.grid, &new_alt);
            self.alt_grid = new_alt;
        } else if (!enable and self.alt_grid != null) {
            var saved = self.alt_grid.?;
            std.mem.swap(Grid, &self.grid, &saved);
            saved.deinit();
            self.alt_grid = null;
        }
        self.mode.alt_screen = enable;
        self.cursor = .{};
        self.dirty = true;
    }
};

// ── Tests ──

test "create screen" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    try testing.expectEqual(@as(u32, 80), screen.grid.width);
    try testing.expectEqual(@as(u32, 24), screen.grid.height);
}

test "write char advances cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar('A');
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
}

test "write string" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("Hello");
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
    try testing.expectEqual(@as(u21, 'H'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'o'), screen.grid.getCell(4, 0).char);
}

test "newline moves to next line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("abc\ndef");
    try testing.expectEqual(@as(u32, 3), screen.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'a'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'd'), screen.grid.getCell(0, 1).char);
}

test "carriage return resets x" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello\rX");
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(0, 0).char);
}

test "line wrapping" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("123456789A");
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
    try testing.expectEqual(@as(u21, '1'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(9, 0).char);
}

test "scrolling when full" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("line1\nline2\nline3\nline4\n");
    try testing.expectEqual(@as(u21, 'e'), screen.grid.getCell(3, 0).char);
}

test "cursor positioning" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursor(40, 12);
    try testing.expectEqual(@as(u32, 40), screen.cursor.x);
    try testing.expectEqual(@as(u32, 12), screen.cursor.y);
}

test "set cursor clamps to bounds" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursor(999, 999);
    try testing.expectEqual(@as(u32, 79), screen.cursor.x);
    try testing.expectEqual(@as(u32, 23), screen.cursor.y);
}

test "clear line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello");
    screen.clearLine(0);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
    try testing.expect(screen.dirty);
}

test "clear screen" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello");
    screen.clearScreen();
    try testing.expect(screen.grid.isEmpty());
}

test "alt screen swap" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("normal screen");
    try testing.expect(!screen.grid.isEmpty());

    try screen.useAltScreen(true);
    try testing.expect(screen.grid.isEmpty());
    try testing.expect(screen.mode.alt_screen);

    try screen.writeStr("alt content");
    try testing.expect(!screen.grid.isEmpty());

    try screen.useAltScreen(false);
    try testing.expect(!screen.mode.alt_screen);
    try testing.expect(!screen.grid.isEmpty());
    try testing.expectEqual(@as(u21, 'n'), screen.grid.getCell(0, 0).char);
}

test "insert mode shifts cells right" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("ABCDE");

    screen.mode.insert = true;
    screen.setCursor(2, 0);
    try screen.writeChar('X');

    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'C'), screen.grid.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(4, 0).char);
}

test "Tab moves to next tab stop" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar('\t');
    try testing.expectEqual(@as(u32, 8), screen.cursor.x);
}

test "control chars are ignored" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar(0x01);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
}
