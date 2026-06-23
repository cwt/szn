const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const grid = @import("grid.zig");
const Cell = grid.Cell;
const Grid = grid.Grid;
const GridLine = grid.GridLine;
const Colour = colour.Colour;

pub const Error = grid.Error || error{OutOfMemory};

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
    saved_cursor: ?Cursor = null,
    alt_cursor: Cursor = .{},
    alt_saved_cursor: ?Cursor = null,
    mode: Mode = .{},
    scroll_region: ?[2]u32 = null,
    cur_cell: Cell = Cell.empty(),
    dirty: bool = true,
    copy_mode: ?@import("mode_copy.zig").CopyMode = null,
    tab_stop: u32 = 8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Screen {
        return Screen{
            .allocator = allocator,
            .grid = try Grid.init(allocator, width, height),
            .copy_mode = null,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        if (self.alt_grid) |*g| g.deinit();
    }

    pub fn resize(self: *Screen, width: u32, height: u32) Error!void {
        try self.grid.setSize(width, height);
        if (self.alt_grid) |*g| {
            try g.setSize(width, height);
        }
        self.cursor.x = @min(self.cursor.x, width -| 1);
        self.cursor.y = @min(self.cursor.y, height -| 1);
    }

    fn scrollUpInRegion(self: *Screen) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        if (self.cursor.y != bottom) return;
        var y = top;
        while (y < bottom) : (y += 1) {
            const line = self.grid.getLineMut(y);
            const next = self.grid.getLineMut(y + 1);
            std.mem.swap(GridLine, line, next);
        }
        self.grid.clearLine(bottom);
    }

    fn scrollDownInRegion(self: *Screen) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        if (self.cursor.y != top) return;
        var y = bottom;
        while (y > top) : (y -= 1) {
            const line = self.grid.getLineMut(y);
            const prev = self.grid.getLineMut(y - 1);
            std.mem.swap(GridLine, line, prev);
        }
        self.grid.clearLine(top);
    }

    pub fn writeChar(self: *Screen, char: u21) Error!void {
        if (char == '\n') {
            self.cursor.x = 0;
            if (self.cursor.y + 1 >= self.grid.height) {
                try self.grid.scrollUp();
            } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                try self.scrollUpInRegion();
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
            self.cursor.x = ((self.cursor.x / self.tab_stop) + 1) * self.tab_stop;
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = self.grid.width - 1;
            }
            self.dirty = true;
            return;
        }
        if (char == 0x07) {
            // BEL — ignored for now
            return;
        }
        if (char == 0x08) {
            // BS
            if (self.cursor.x > 0) self.cursor.x -= 1;
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

        var cell = self.cur_cell;
        cell.char = char;
        self.grid.setCell(self.cursor.x, self.cursor.y, cell);
        self.dirty = true;

        if (self.mode.line_wrap) {
            self.cursor.x += 1;
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                    try self.scrollUpInRegion();
                } else {
                    self.cursor.y += 1;
                }
            }
        } else {
            self.cursor.x = @min(self.cursor.x + 1, self.grid.width - 1);
        }
    }

    pub fn writeStr(self: *Screen, s: []const u8) Error!void {
        for (s) |c| {
            try self.writeChar(c);
        }
    }

    pub fn setCursorAbs(self: *Screen, x: u32, y: u32) void {
        self.cursor.x = @min(x, self.grid.width -| 1);
        self.cursor.y = @min(y, self.grid.height -| 1);
        self.dirty = true;
    }

    pub fn cursorUp(self: *Screen, n: u32) void {
        const top = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[0] else 0;
        } else 0;
        const count = @min(n, self.cursor.y -| top);
        self.cursor.y -= count;
        self.dirty = true;
    }

    pub fn cursorDown(self: *Screen, n: u32) void {
        const bottom: u32 = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        } else self.grid.height - 1;
        const count = @min(n, bottom -| self.cursor.y);
        self.cursor.y += count;
        self.dirty = true;
    }

    pub fn cursorForward(self: *Screen, n: u32) void {
        self.cursor.x = @min(self.cursor.x + n, self.grid.width - 1);
        self.dirty = true;
    }

    pub fn cursorBack(self: *Screen, n: u32) void {
        self.cursor.x -|= n;
        self.dirty = true;
    }

    pub fn cursorColumn(self: *Screen, x: u32) void {
        self.cursor.x = @min(x, self.grid.width -| 1);
        self.dirty = true;
    }

    pub fn cursorLine(self: *Screen, y: u32) void {
        const origin_y = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[0] else 0;
        } else 0;
        const actual = @min(y +| origin_y, self.grid.height -| 1);
        self.cursor.y = actual;
        self.dirty = true;
    }

    pub fn cursorPosition(self: *Screen, col: u32, row: u32) void {
        const y: u32 = if (self.mode.origin) blk: {
            if (self.scroll_region) |r| {
                break :blk @min(row + r[0], r[1]);
            }
            break :blk @min(row, self.grid.height -| 1);
        } else @min(row, self.grid.height -| 1);
        self.cursor.y = y;
        self.cursor.x = @min(col, self.grid.width -| 1);
        self.dirty = true;
    }

    pub fn eraseLine(self: *Screen, mode: u8) void {
        switch (mode) {
            0 => {
                var x = self.cursor.x;
                while (x < self.grid.width) : (x += 1) {
                    self.grid.setCell(x, self.cursor.y, Cell.empty());
                }
            },
            1 => {
                var x: u32 = 0;
                while (x <= self.cursor.x) : (x += 1) {
                    self.grid.setCell(x, self.cursor.y, Cell.empty());
                }
            },
            2 => self.grid.clearLine(self.cursor.y),
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseDisplay(self: *Screen, mode: u8) void {
        switch (mode) {
            0 => {
                var y = self.cursor.y;
                while (y < self.grid.height) : (y += 1) {
                    if (y == self.cursor.y) {
                        self.eraseLine(0);
                    } else {
                        self.grid.clearLine(y);
                    }
                }
            },
            1 => {
                var y: u32 = 0;
                while (y <= self.cursor.y) : (y += 1) {
                    if (y == self.cursor.y) {
                        self.eraseLine(1);
                    } else {
                        self.grid.clearLine(y);
                    }
                }
            },
            2 => self.grid.clear(),
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseChars(self: *Screen, n: u32) void {
        self.grid.eraseChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn insertLines(self: *Screen, n: u32) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        const y = @max(self.cursor.y, top);
        if (y > bottom) return;
        const count = @min(n, bottom + 1 - y);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var row = bottom;
            const temp = self.grid.getLine(bottom).*;
            while (row > y) : (row -= 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row - 1).*;
            }
            self.grid.getLineMut(y).* = temp;
            self.grid.clearLine(y);
        }
        self.dirty = true;
    }

    pub fn deleteLines(self: *Screen, n: u32) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        const y = @max(self.cursor.y, top);
        if (y > bottom) return;
        const count = @min(n, bottom + 1 - y);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const temp = self.grid.getLine(y).*;
            var row = y;
            while (row < bottom) : (row += 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row + 1).*;
            }
            self.grid.getLineMut(bottom).* = temp;
            self.grid.clearLine(bottom);
        }
        self.dirty = true;
    }

    pub fn insertChars(self: *Screen, n: u32) void {
        self.grid.insertChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn deleteChars(self: *Screen, n: u32) void {
        self.grid.deleteChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn index(self: *Screen) Error!void {
        if (self.scroll_region) |r| {
            if (self.cursor.y == r[1]) {
                try self.scrollUpInRegion();
                return;
            }
        } else if (self.cursor.y + 1 >= self.grid.height) {
            try self.grid.scrollUp();
            return;
        }
        self.cursor.y += 1;
    }

    pub fn reverseIndex(self: *Screen) Error!void {
        if (self.scroll_region) |r| {
            if (self.cursor.y == r[0]) {
                try self.scrollDownInRegion();
                return;
            }
        } else if (self.cursor.y == 0) {
            try self.grid.scrollDown();
            return;
        }
        self.cursor.y -|= 1;
    }

    pub fn scrollUp(self: *Screen, n: u32) Error!void {
        if (self.scroll_region) |r| {
            const top = r[0];
            const bottom = r[1];
            const count = @min(n, bottom + 1 - top);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const temp = self.grid.getLine(top).*;
                var row = top;
                while (row < bottom) : (row += 1) {
                    self.grid.getLineMut(row).* = self.grid.getLine(row + 1).*;
                }
                self.grid.getLineMut(bottom).* = temp;
                self.grid.clearLine(bottom);
            }
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try self.grid.scrollUp();
            }
        }
    }

    pub fn scrollDown(self: *Screen, n: u32) Error!void {
        if (self.scroll_region) |r| {
            const top = r[0];
            const bottom = r[1];
            const count = @min(n, bottom + 1 - top);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var row = bottom;
                const temp = self.grid.getLine(bottom).*;
                while (row > top) : (row -= 1) {
                    self.grid.getLineMut(row).* = self.grid.getLine(row - 1).*;
                }
                self.grid.getLineMut(top).* = temp;
                self.grid.clearLine(top);
            }
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try self.grid.scrollDown();
            }
        }
    }

    pub fn setScrollRegion(self: *Screen, top: u32, bottom: u32) void {
        self.scroll_region = .{ @min(top, self.grid.height -| 1), @min(bottom, self.grid.height -| 1) };
        self.cursor.x = 0;
        self.cursor.y = if (self.mode.origin) self.scroll_region.?[0] else 0;
        self.dirty = true;
    }

    pub fn setOriginMode(self: *Screen, enable: bool) void {
        self.mode.origin = enable;
        self.cursor.x = 0;
        self.cursor.y = if (enable and self.scroll_region != null) self.scroll_region.?[0] else 0;
        self.dirty = true;
    }

    pub fn saveCursor(self: *Screen) void {
        self.saved_cursor = self.cursor;
    }

    pub fn restoreCursor(self: *Screen) void {
        if (self.saved_cursor) |saved| {
            self.cursor = saved;
            self.dirty = true;
        }
    }

    pub fn setSgr(self: *Screen, params: []const u32, sub_params: []const bool) void {
        if (params.len == 0) {
            self.cur_cell = Cell.empty();
            return;
        }
        var i: usize = 0;
        while (i < params.len) {
            const p = params[i];
            i += 1;
            switch (p) {
                0 => self.cur_cell = Cell.empty(),
                1 => self.cur_cell.attr.bold = true,
                2 => self.cur_cell.attr.dim = true,
                3 => self.cur_cell.attr.italic = true,
                4 => {
                    if (i < params.len and sub_params[i]) {
                        const sub = params[i];
                        i += 1;
                        switch (sub) {
                            0 => {
                                self.cur_cell.attr.underline = false;
                                self.cur_cell.attr.double_underline = false;
                                self.cur_cell.attr.curly_underline = false;
                            },
                            2 => self.cur_cell.attr.double_underline = true,
                            3 => self.cur_cell.attr.curly_underline = true,
                            else => self.cur_cell.attr.underline = true,
                        }
                    } else {
                        self.cur_cell.attr.underline = true;
                    }
                },
                5 => self.cur_cell.attr.blink = true,
                7 => self.cur_cell.attr.reverse = true,
                8 => self.cur_cell.attr.concealed = true,
                9 => self.cur_cell.attr.strikethrough = true,
                21 => self.cur_cell.attr.double_underline = true,
                22 => {
                    self.cur_cell.attr.bold = false;
                    self.cur_cell.attr.dim = false;
                },
                23 => self.cur_cell.attr.italic = false,
                24 => {
                    self.cur_cell.attr.underline = false;
                    self.cur_cell.attr.double_underline = false;
                    self.cur_cell.attr.curly_underline = false;
                },
                25 => self.cur_cell.attr.blink = false,
                27 => self.cur_cell.attr.reverse = false,
                28 => self.cur_cell.attr.concealed = false,
                29 => self.cur_cell.attr.strikethrough = false,
                30...37 => {
                    const idx = p - 30;
                    self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                },
                38 => {
                    if (i < params.len) {
                        const next = params[i];
                        i += 1;
                        if (next == 5) {
                            if (i < params.len) {
                                const idx = params[i];
                                i += 1;
                                self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                            }
                        } else if (next == 2) {
                            if (i + 2 < params.len) {
                                const r = params[i];
                                const g = params[i + 1];
                                const b = params[i + 2];
                                i += 3;
                                self.cur_cell.fg = Colour.fromRgb(@intCast(r), @intCast(g), @intCast(b));
                            }
                        }
                    }
                },
                39 => self.cur_cell.fg = Colour.default_(),
                40...47 => {
                    const idx = p - 40;
                    self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                },
                48 => {
                    if (i < params.len) {
                        const next = params[i];
                        i += 1;
                        if (next == 5) {
                            if (i < params.len) {
                                const idx = params[i];
                                i += 1;
                                self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                            }
                        } else if (next == 2) {
                            if (i + 2 < params.len) {
                                const r = params[i];
                                const g = params[i + 1];
                                const b = params[i + 2];
                                i += 3;
                                self.cur_cell.bg = Colour.fromRgb(@intCast(r), @intCast(g), @intCast(b));
                            }
                        }
                    }
                },
                49 => self.cur_cell.bg = Colour.default_(),
                90...97 => {
                    const idx = p - 90 + 8;
                    self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                },
                100...107 => {
                    const idx = p - 100 + 8;
                    self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                },
                else => {},
            }
        }
    }

    pub fn resetHard(self: *Screen) Error!void {
        self.cursor = .{};
        self.saved_cursor = null;
        self.mode = .{};
        self.scroll_region = null;
        self.cur_cell = Cell.empty();
        self.grid.clear();
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

    pub fn useAltScreen(self: *Screen, enable: bool) Error!void {
        if (enable and self.alt_grid == null) {
            var new_alt = try Grid.init(self.allocator, self.grid.width, self.grid.height);
            std.mem.swap(Grid, &self.grid, &new_alt);
            self.alt_grid = new_alt;

            std.mem.swap(Cursor, &self.cursor, &self.alt_cursor);
            var opt_saved = self.alt_saved_cursor;
            std.mem.swap(?Cursor, &self.saved_cursor, &opt_saved);
            self.alt_saved_cursor = opt_saved;
        } else if (!enable and self.alt_grid != null) {
            var saved = self.alt_grid.?;
            std.mem.swap(Grid, &self.grid, &saved);
            saved.deinit();
            self.alt_grid = null;

            std.mem.swap(Cursor, &self.cursor, &self.alt_cursor);
            var opt_saved = self.alt_saved_cursor;
            std.mem.swap(?Cursor, &self.saved_cursor, &opt_saved);
            self.alt_saved_cursor = opt_saved;

            self.alt_cursor = .{};
            self.alt_saved_cursor = null;
        }
        self.mode.alt_screen = enable;
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

    screen.setCursorAbs(40, 12);
    try testing.expectEqual(@as(u32, 40), screen.cursor.x);
    try testing.expectEqual(@as(u32, 12), screen.cursor.y);
}

test "set cursor clamps to bounds" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorAbs(999, 999);
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
    screen.setCursorAbs(2, 0);
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

test "cursorUp clamped to top" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 2;
    screen.cursorUp(10);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
}

test "cursorDown clamped to bottom" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 20;
    screen.cursorDown(10);
    try testing.expectEqual(@as(u32, 23), screen.cursor.y);
}

test "cursorForward clamped to right" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 75;
    screen.cursorForward(10);
    try testing.expectEqual(@as(u32, 79), screen.cursor.x);
}

test "cursorBack won't underflow" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursorBack(5);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "eraseLine mode 1 clears from start to cursor" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("ABCDE");
    screen.cursor.x = 2;
    screen.eraseLine(1);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(3, 0).char);
}

test "eraseLine mode 2 clears entire line" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("ABCDE");
    screen.eraseLine(2);
    try testing.expect(screen.grid.isEmpty());
}

test "eraseDisplay mode 2 clears all" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("line1\nline2\nline3");
    screen.eraseDisplay(2);
    try testing.expect(screen.grid.isEmpty());
}

test "cursor save and restore" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 10;
    screen.cursor.y = 5;
    screen.saveCursor();
    screen.cursor.x = 99;
    screen.cursor.y = 99;
    screen.restoreCursor();
    try testing.expectEqual(@as(u32, 10), screen.cursor.x);
    try testing.expectEqual(@as(u32, 5), screen.cursor.y);
}

test "setSgr bold + italic" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.setSgr(&[_]u32{ 1, 3 }, &[_]bool{ false, false });
    try screen.writeChar('X');
    try testing.expect(screen.grid.getCell(0, 0).attr.bold);
    try testing.expect(screen.grid.getCell(0, 0).attr.italic);
}

test "setSgr empty resets" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.setSgr(&[_]u32{1}, &[_]bool{false});
    screen.setSgr(&.{}, &.{});
    try testing.expect(!screen.cur_cell.attr.bold);
}

test "origin mode clamps cursor" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "scroll region with cursor up (origin mode)" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    screen.cursor.y = 2;
    screen.cursorUp(5);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "scroll region with cursor down (origin mode)" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    screen.cursor.y = 2;
    screen.cursorDown(5);
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "index within scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    try screen.writeStr("aaa\nbbb\nccc\nddd\neee");
    screen.cursor.y = 3;
    try screen.index();
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "reverse index within scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.cursor.y = 1;
    try screen.reverseIndex();
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "hard reset restores defaults" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.mode.line_wrap = false;
    screen.mode.insert = true;
    screen.setSgr(&[_]u32{ 1, 31 }, &[_]bool{ false, false });
    try screen.resetHard();
    try testing.expect(screen.mode.line_wrap);
    try testing.expect(!screen.mode.insert);
    try testing.expect(!screen.cur_cell.attr.bold);
    try testing.expect(screen.grid.isEmpty());
}

test "setCursorAbs absolute positioning" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.setCursorAbs(40, 12);
    try testing.expectEqual(@as(u32, 40), screen.cursor.x);
    try testing.expectEqual(@as(u32, 12), screen.cursor.y);
}

test "BEL is ignored" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeChar(0x07);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "BS moves cursor left" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.cursor.x = 5;
    try screen.writeChar(0x08);
    try testing.expectEqual(@as(u32, 4), screen.cursor.x);
}

test "BS at column 0 does nothing" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeChar(0x08);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "line wrapping with scroll region" {
    var screen = try Screen.init(testing.allocator, 5, 4);
    defer screen.deinit();

    // Scroll region: lines 1 to 2 inclusive (0-indexed: 0, 1, 2, 3)
    screen.setScrollRegion(1, 2);

    // Position cursor at r[1] (line 2), col 4 (last column)
    screen.cursor.x = 4;
    screen.cursor.y = 2;

    // Write a char to trigger line wrapping.
    try screen.writeChar('A');
    // It should wrap, so cursor x goes to 0.
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    // Since cursor.y was at r[1] (2), it should trigger scrollUpInRegion() and remain at y = 2.
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
}

test "line wrapping outside scroll region" {
    var screen = try Screen.init(testing.allocator, 5, 4);
    defer screen.deinit();

    // Scroll region: lines 1 to 2 inclusive (0-indexed: 0, 1, 2, 3)
    screen.setScrollRegion(1, 2);

    // Position cursor at line 3 (below scroll region), col 4 (last column)
    screen.cursor.x = 4;
    screen.cursor.y = 3;

    // Write a char to trigger line wrapping.
    try screen.writeChar('A');
    // It should wrap, and either scroll the full grid or clamp, but NOT go out of bounds (y should not be 4).
    try testing.expect(screen.cursor.y < 4);
}

test "useAltScreen saves and restores cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // Position cursor on main screen
    screen.cursor.x = 10;
    screen.cursor.y = 5;
    screen.saveCursor();

    // Enter alt screen
    try screen.useAltScreen(true);
    
    // Alt screen cursor should be reset to default (0, 0)
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expect(screen.saved_cursor == null);

    // Position cursor on alt screen
    screen.cursor.x = 20;
    screen.cursor.y = 12;

    // Leave alt screen
    try screen.useAltScreen(false);

    // Main screen cursor should be restored
    try testing.expectEqual(@as(u32, 10), screen.cursor.x);
    try testing.expectEqual(@as(u32, 5), screen.cursor.y);
    try testing.expect(screen.saved_cursor != null);
    try testing.expectEqual(@as(u32, 10), screen.saved_cursor.?.x);
    try testing.expectEqual(@as(u32, 5), screen.saved_cursor.?.y);
}

test "scrollUp and scrollDown respect scroll region" {
    var screen = try Screen.init(testing.allocator, 15, 5);
    defer screen.deinit();

    // Populate lines
    try screen.writeStr("0000000000\n1111111111\n2222222222\n3333333333\n4444444444");

    // Set scroll region to lines 1..3 inclusive (0-indexed: 1, 2, 3)
    screen.setScrollRegion(1, 3);

    // Scroll up by 1 line inside region
    try screen.scrollUp(1);

    // Line 0 and 4 should be untouched
    try testing.expectEqual(@as(u21, '0'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '4'), screen.grid.getCell(0, 4).char);

    // Region lines (1..3) should be scrolled:
    // old line 2 ("222...") moved to line 1
    // old line 3 ("333...") moved to line 2
    // line 3 cleared (all spaces)
    try testing.expectEqual(@as(u21, '2'), screen.grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '3'), screen.grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 3).char);

    // Scroll down by 1 line inside region
    try screen.scrollDown(1);

    // Line 0 and 4 should be untouched
    try testing.expectEqual(@as(u21, '0'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '4'), screen.grid.getCell(0, 4).char);

    // Region lines (1..3) should be scrolled down:
    // line 1 cleared
    // line 2 gets old line 1 ("222...")
    // line 3 gets old line 2 ("333...")
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '2'), screen.grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, '3'), screen.grid.getCell(0, 3).char);
}



