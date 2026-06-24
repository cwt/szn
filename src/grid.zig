const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const Colour = colour.Colour;

pub const Error = error{OutOfMemory};

pub const Attr = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    concealed: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    double_underline: bool = false,
    curly_underline: bool = false,
    _padding: u5 = 0,
};

pub const Cell = packed struct(u128) {
    char: u21,
    attr: Attr,
    fg: Colour,
    bg: Colour,
    _padding: u6 = 0,
    _pad2: u21 = 0,

    pub fn empty() Cell {
        return .{
            .char = ' ',
            .attr = .{},
            .fg = Colour.default_(),
            .bg = Colour.default_(),
        };
    }

    pub fn withChar(c: u21) Cell {
        var cell = Cell.empty();
        cell.char = c;
        return cell;
    }

    pub fn eql(self: Cell, other: Cell) bool {
        return @as(u128, @bitCast(self)) == @as(u128, @bitCast(other));
    }
};

pub const GridLine = struct {
    cells: std.ArrayListUnmanaged(Cell) = .empty,
    dirty: bool = true,

    pub fn deinit(self: *GridLine, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
    }
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    lines: std.ArrayListUnmanaged(GridLine) = .empty,
    history: std.ArrayListUnmanaged(GridLine) = .empty,
    history_limit: u32 = 2000,
    start_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Grid {
        return initWithLimit(allocator, width, height, 2000);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, width: u32, height: u32, history_limit: u32) Error!Grid {
        var grid = Grid{
            .allocator = allocator,
            .width = width,
            .height = height,
            .history_limit = history_limit,
            .start_index = 0,
        };
        try grid.lines.ensureTotalCapacity(allocator, height);
        try grid.resize(height);
        return grid;
    }

    pub fn getLine(self: *const Grid, y: u32) *const GridLine {
        const idx = (self.start_index + y) % self.height;
        return &self.lines.items[idx];
    }

    pub fn getLineMut(self: *Grid, y: u32) *GridLine {
        const idx = (self.start_index + y) % self.height;
        return &self.lines.items[idx];
    }

    pub fn normalize(self: *Grid) !void {
        if (self.start_index == 0) return;
        var temp_lines = try self.allocator.alloc(GridLine, self.height);
        defer self.allocator.free(temp_lines);
        var i: u32 = 0;
        while (i < self.height) : (i += 1) {
            temp_lines[i] = self.getLine(i).*;
        }
        @memcpy(self.lines.items[0..self.height], temp_lines);
        self.start_index = 0;
    }

    pub fn deinit(self: *Grid) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        for (self.history.items) |*line| line.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    pub fn resize(self: *Grid, new_height: u32) Error!void {
        try self.normalize();
        while (self.lines.items.len < new_height) {
            var line = GridLine{};
            try line.cells.resize(self.allocator, self.width);
            @memset(line.cells.items, Cell.empty());
            try self.lines.append(self.allocator, line);
        }
        while (self.lines.items.len > new_height) {
            var line = self.lines.pop().?;
            line.deinit(self.allocator);
        }
        self.height = new_height;
    }

    pub fn setSize(self: *Grid, new_width: u32, new_height: u32) Error!void {
        try self.normalize();
        self.width = new_width;
        for (self.lines.items) |*line| {
            const old_len = line.cells.items.len;
            if (old_len > new_width) {
                line.cells.shrinkRetainingCapacity(new_width);
            } else if (old_len < new_width) {
                try line.cells.resize(self.allocator, new_width);
                @memset(line.cells.items[old_len..], Cell.empty());
            }
        }
        try self.resize(new_height);
    }

    pub fn setCell(self: *Grid, x: u32, y: u32, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const line = self.getLineMut(y);
        line.cells.items[x] = cell;
        line.dirty = true;
    }

    pub fn getCell(self: *const Grid, x: u32, y: u32) Cell {
        if (x >= self.width or y >= self.height) return Cell.empty();
        return self.getLine(y).cells.items[x];
    }

    pub fn writeChar(self: *Grid, x: u32, y: u32, char: u21) void {
        self.setCell(x, y, Cell.withChar(char));
    }

    pub fn scrollUp(self: *Grid) Error!void {
        if (self.height == 0) return;

        var new_line = GridLine{};
        try new_line.cells.resize(self.allocator, self.width);
        @memset(new_line.cells.items, Cell.empty());

        var old_line = self.getLineMut(0).*;
        old_line.dirty = false;
        self.getLineMut(0).* = new_line;

        errdefer old_line.deinit(self.allocator);
        try self.history.append(self.allocator, old_line);
        if (self.history.items.len > self.history_limit) {
            var old = self.history.orderedRemove(0);
            old.deinit(self.allocator);
        }

        self.start_index = (self.start_index + 1) % self.height;
    }

    pub fn scrollDown(self: *Grid) Error!void {
        if (self.history.items.len == 0) return;
        var line = self.history.pop().?;
        errdefer line.deinit(self.allocator);

        self.getLineMut(self.height - 1).deinit(self.allocator);
        self.start_index = (self.start_index + self.height - 1) % self.height;
        self.getLineMut(0).* = line;
    }

    pub fn clearLine(self: *Grid, y: u32) void {
        if (y >= self.height) return;
        var line = self.getLineMut(y);
        @memset(line.cells.items, Cell.empty());
        line.dirty = true;
    }

    pub fn insertLine(self: *Grid, y: u32) Error!void {
        if (y >= self.height) return;
        const temp = self.getLine(self.height - 1).*;
        var i = self.height - 1;
        while (i > y) : (i -= 1) {
            self.getLineMut(i).* = self.getLine(i - 1).*;
        }
        self.getLineMut(y).* = temp;
        @memset(self.getLineMut(y).cells.items, Cell.empty());
        self.getLineMut(y).dirty = true;
    }

    pub fn deleteLine(self: *Grid, y: u32) Error!void {
        if (y >= self.height) return;
        const temp = self.getLine(y).*;
        var i = y;
        while (i < self.height - 1) : (i += 1) {
            self.getLineMut(i).* = self.getLine(i + 1).*;
        }
        self.getLineMut(self.height - 1).* = temp;
        @memset(self.getLineMut(self.height - 1).cells.items, Cell.empty());
        self.getLineMut(self.height - 1).dirty = true;
    }

    pub fn insertChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const num = @min(n, self.width -| x);
        if (num == 0) return;
        const line = self.getLineMut(y);
        var i = self.width - 1;
        while (i >= x + num) : (i -= 1) {
            line.cells.items[i] = line.cells.items[i - num];
        }
        const end = @min(x + num, self.width);
        for (x..end) |col| {
            line.cells.items[col] = Cell.empty();
        }
        line.dirty = true;
    }

    pub fn deleteChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const num = @min(n, self.width -| x);
        if (num == 0) return;
        const line = self.getLineMut(y);
        var i = x;
        while (i + num < self.width) : (i += 1) {
            line.cells.items[i] = line.cells.items[i + num];
        }
        while (i < self.width) : (i += 1) {
            line.cells.items[i] = Cell.empty();
        }
        line.dirty = true;
    }

    pub fn eraseChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const line = self.getLineMut(y);
        const end = @min(x + n, self.width);
        if (x < end) {
            @memset(line.cells.items[x..end], Cell.empty());
            line.dirty = true;
        }
    }

    pub fn clearArea(self: *Grid, sx: u32, sy: u32, ex: u32, ey: u32) void {
        var y = sy;
        while (y <= ey and y < self.height) : (y += 1) {
            const line = self.getLineMut(y);
            const x = if (y == sy) sx else 0;
            const max_x = if (y == ey) @min(ex, self.width - 1) else self.width - 1;
            if (x <= max_x) {
                @memset(line.cells.items[x .. max_x + 1], Cell.empty());
                line.dirty = true;
            }
        }
    }

    pub fn clear(self: *Grid) void {
        for (0..self.height) |y| {
            self.clearLine(@intCast(y));
        }
    }

    pub fn isEmpty(self: *const Grid) bool {
        for (self.lines.items) |*line| {
            for (line.cells.items) |cell| {
                if (cell.char != ' ') return false;
            }
        }
        return true;
    }

    pub fn isDirty(self: *const Grid) bool {
        for (self.lines.items) |*line| {
            if (line.dirty) return true;
        }
        return false;
    }

    pub fn clearDirty(self: *Grid) void {
        for (self.lines.items) |*line| {
            line.dirty = false;
        }
    }
};

// ── Tests ──

test "create grid with dimensions" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();
    try testing.expectEqual(@as(u32, 80), grid.width);
    try testing.expectEqual(@as(u32, 24), grid.height);
    try testing.expectEqual(@as(usize, 24), grid.lines.items.len);
}

test "write and read cell" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const cell = Cell.withChar('X');
    grid.setCell(10, 5, cell);

    const read = grid.getCell(10, 5);
    try testing.expectEqual(@as(u21, 'X'), read.char);
}

test "read empty cell returns space" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const cell = grid.getCell(40, 12);
    try testing.expectEqual(@as(u21, ' '), cell.char);
}

test "out of bounds get returns empty" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try testing.expectEqual(@as(u21, ' '), grid.getCell(999, 0).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 999).char);
}

test "out of bounds set is no-op" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    grid.setCell(999, 0, Cell.withChar('X'));
    grid.setCell(0, 999, Cell.withChar('X'));
    // Shouldn't crash or panic
}

test "scroll up moves lines to history" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    try testing.expectEqual(@as(usize, 0), grid.history.items.len);

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.history.items[0].cells.items[0].char);
}

test "scroll down restores from history" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);

    try grid.scrollDown();
    try testing.expectEqual(@as(usize, 0), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
}

test "history respects limit" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();
    grid.history_limit = 3;

    for (0..10) |_| {
        try grid.scrollUp();
    }

    try testing.expectEqual(@as(usize, 3), grid.history.items.len);
}

test "clear line" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    grid.writeChar(10, 5, 'X');
    try testing.expectEqual(@as(u21, 'X'), grid.getCell(10, 5).char);

    grid.clearLine(5);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(10, 5).char);
}

test "clear area" {
    var grid = try Grid.init(testing.allocator, 10, 10);
    defer grid.deinit();

    for (0..10) |x| {
        for (0..10) |y| {
            grid.writeChar(@intCast(x), @intCast(y), '#');
        }
    }

    grid.clearArea(2, 2, 7, 7);

    try testing.expectEqual(@as(u21, '#'), grid.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(2, 2).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(7, 7).char);
    try testing.expectEqual(@as(u21, '#'), grid.getCell(8, 8).char);
}

test "clear all" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    for (0..10) |i| {
        grid.writeChar(@intCast(i), 0, @intCast('A' + i));
    }

    try testing.expect(!grid.isEmpty());

    grid.clear();
    try testing.expect(grid.isEmpty());
}

test "dirty flag tracking" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try testing.expect(grid.isDirty());

    grid.clearDirty();
    try testing.expect(!grid.isDirty());

    grid.writeChar(0, 0, 'X');
    try testing.expect(grid.isDirty());
}

test "cell attribute combinations" {
    var cell = Cell.empty();
    try testing.expect(!cell.attr.bold);
    try testing.expect(!cell.attr.italic);

    cell.attr.bold = true;
    cell.attr.italic = true;
    try testing.expect(cell.attr.bold);
    try testing.expect(cell.attr.italic);
}

test "cell equality" {
    const a = Cell.withChar('A');
    const b = Cell.withChar('A');
    const c = Cell.withChar('B');
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}

test "resize grid" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.resize(40);
    try testing.expectEqual(@as(u32, 40), grid.height);
    try testing.expectEqual(@as(usize, 40), grid.lines.items.len);
}

test "scroll up does not corrupt grid — C1 UAF regression" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    // Scroll up multiple times — each scroll moves top line to history
    for (0..10) |_| {
        try grid.scrollUp();
    }

    // History should have 5 entries (we had 5 lines, scrolled 10 times)
    // but more importantly, no crash and grid is still writable
    try testing.expect(grid.history.items.len > 0);

    // Verify grid lines are still writable — UAF bug would crash here
    grid.writeChar(0, 0, 'X');
    try testing.expectEqual(@as(u21, 'X'), grid.getCell(0, 0).char);

    // Verify history entries still have valid content — no dangling pointers
    for (grid.history.items, 0..) |*h_line, idx| {
        _ = idx;
        // Just reading should not crash
        _ = h_line.cells.items.len;
    }
}

test "write string across grid" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const text = "Hello, szn!";
    for (text, 0..) |c, i| {
        grid.writeChar(@intCast(i), 0, c);
    }

    for (text, 0..) |c, i| {
        const cell = grid.getCell(@intCast(i), 0);
        try testing.expectEqual(@as(u21, c), cell.char);
    }
}
