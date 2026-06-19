const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const Colour = colour.Colour;

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
    char: u24,
    attr: Attr,
    fg: Colour,
    bg: Colour,
    _padding: u6 = 0,
    _pad2: u18 = 0,

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
        cell.char = @intCast(c);
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

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Grid {
        var grid = Grid{
            .allocator = allocator,
            .width = width,
            .height = height,
        };
        try grid.lines.ensureTotalCapacity(allocator, height);
        try grid.resize(height);
        return grid;
    }

    pub fn deinit(self: *Grid) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        for (self.history.items) |*line| line.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    pub fn resize(self: *Grid, new_height: u32) !void {
        while (self.lines.items.len < new_height) {
            try self.lines.append(self.allocator, .{});
        }
        while (self.lines.items.len > new_height) {
            var line = self.lines.pop().?;
            line.deinit(self.allocator);
        }
        self.height = new_height;
    }

    pub fn setCell(self: *Grid, x: u32, y: u32, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const line = &self.lines.items[y];
        if (x >= line.cells.items.len) {
            line.cells.resize(self.allocator, @as(usize, x) + 1) catch return;
            // Fill new cells with empty
            for (line.cells.items[0..]) |*c| {
                if (c.char == 0) c.* = Cell.empty();
            }
        }
        line.cells.items[x] = cell;
        line.dirty = true;
    }

    pub fn getCell(self: *const Grid, x: u32, y: u32) Cell {
        if (x >= self.width or y >= self.height) return Cell.empty();
        const line = &self.lines.items[y];
        if (x >= line.cells.items.len) return Cell.empty();
        return line.cells.items[x];
    }

    pub fn writeChar(self: *Grid, x: u32, y: u32, char: u21) void {
        self.setCell(x, y, Cell.withChar(char));
    }

    pub fn scrollUp(self: *Grid) !void {
        if (self.lines.items.len == 0) return;
        var line = self.lines.orderedRemove(0);
        line.dirty = false;

        try self.history.append(self.allocator, line);
        if (self.history.items.len > self.history_limit) {
            var old = self.history.orderedRemove(0);
            old.deinit(self.allocator);
        }

        try self.lines.append(self.allocator, .{});
    }

    pub fn scrollDown(self: *Grid) !void {
        if (self.history.items.len == 0) return;
        const line = self.history.pop().?;
        try self.lines.insert(self.allocator, 0, line);
        if (self.lines.pop()) |_| {}
    }

    pub fn clearLine(self: *Grid, y: u32) void {
        if (y >= self.height) return;
        var line = &self.lines.items[y];
        line.cells.clearRetainingCapacity();
        line.dirty = true;
    }

    pub fn clearArea(self: *Grid, sx: u32, sy: u32, ex: u32, ey: u32) void {
        var y = sy;
        while (y <= ey and y < self.height) : (y += 1) {
            var x = if (y == sy) sx else 0;
            const max_x = if (y == ey) @min(ex, self.width - 1) else self.width - 1;
            while (x <= max_x) : (x += 1) {
                self.setCell(x, y, Cell.empty());
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

test "write string across grid" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const text = "Hello, zmux!";
    for (text, 0..) |c, i| {
        grid.writeChar(@intCast(i), 0, c);
    }

    for (text, 0..) |c, i| {
        const cell = grid.getCell(@intCast(i), 0);
        try testing.expectEqual(@as(u21, c), cell.char);
    }
}
