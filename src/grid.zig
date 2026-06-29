const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const char_width = @import("char_width.zig");
const thai = @import("thai.zig");
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
    comb1: u13 = 0,
    comb2: u13 = 0,
    attr: Attr,
    fg: Colour,
    bg: Colour,
    is_padding: bool = false,

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
    /// True when this line is a soft-wrap continuation from the previous line.
    /// Used by reflow to reconstruct logical lines.
    wrapped: bool = false,

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

    pub fn clone(self: *const Grid, allocator: std.mem.Allocator) Error!Grid {
        var copy = Grid{
            .allocator = allocator,
            .width = self.width,
            .height = self.height,
            .history_limit = self.history_limit,
            .start_index = self.start_index,
        };
        try copy.lines.ensureTotalCapacity(allocator, self.lines.items.len);
        errdefer {
            for (copy.lines.items) |*l| l.deinit(allocator);
            copy.lines.deinit(allocator);
        }
        for (self.lines.items) |line| {
            var new_line = GridLine{ .dirty = line.dirty, .wrapped = line.wrapped };
            try new_line.cells.appendSlice(allocator, line.cells.items);
            try copy.lines.append(allocator, new_line);
        }
        try copy.history.ensureTotalCapacity(allocator, self.history.items.len);
        errdefer {
            for (copy.history.items) |*l| l.deinit(allocator);
            copy.history.deinit(allocator);
        }
        for (self.history.items) |line| {
            var new_line = GridLine{ .dirty = line.dirty, .wrapped = line.wrapped };
            try new_line.cells.appendSlice(allocator, line.cells.items);
            try copy.history.append(allocator, new_line);
        }
        return copy;
    }

    pub fn resize(self: *Grid, new_height: u32) Error!void {
        if (new_height == 0) return;
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
        if (new_width != self.width) {
            try self.reflow(new_width);
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
        if (self.height == 0 or self.history.items.len == 0) return;
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
        line.wrapped = false;
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
        self.getLineMut(y).wrapped = false;
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
        self.getLineMut(self.height - 1).wrapped = false;
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

    /// Returns the index after the last cell in the visual cluster at `start`.
    /// Handles Thai clusters (leading vowel + base + following vowel + attaching),
    /// CJK wide char + padding pairs, and regular single cells.
    fn findClusterEnd(cells: []const Cell, start: usize) usize {
        const cp = cells[start].char;
        if (cp == ' ' and cells[start].is_padding) return start + 1;
        if (thai.isThai(cp)) return thai.findThaiClusterEnd(cells, start);
        if (char_width.charWidth(cp) == 2) return @min(start + 2, cells.len);
        return start + 1;
    }

    /// Returns the display width of a cluster spanning `cells[0..end)`.
    fn clusterWidth(cells: []const Cell) u32 {
        var w: u32 = 0;
        for (cells) |c| {
            if (c.is_padding) continue;
            w += if (c.char == ' ') 1 else char_width.charWidth(c.char);
        }
        return w;
    }

    /// Rewrap a flat cell sequence (one logical line) to `new_width`.
    /// Returns owned slice of GridLine. Lines that wrap to the next physical
    /// line have wrapped=true; the last line of each rewrapped group is false.
    fn rewrap(cells: []const Cell, new_width: u32, allocator: std.mem.Allocator) ![]GridLine {
        var lines: std.ArrayListUnmanaged(GridLine) = .empty;
        errdefer {
            for (lines.items) |*l| l.deinit(allocator);
            lines.deinit(allocator);
        }

        if (cells.len == 0) {
            var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
            try line_cells.resize(allocator, new_width);
            @memset(line_cells.items, Cell.empty());
            var gl = GridLine{ .dirty = true, .wrapped = false };
            gl.cells = line_cells;
            try lines.append(allocator, gl);
            return lines.toOwnedSlice(allocator);
        }

        var i: usize = 0;
        while (i < cells.len) {
            var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
            defer line_cells.deinit(allocator);
            var line_width: u32 = 0;
            var did_break = false;

            while (i < cells.len) {
                const cluster_end = findClusterEnd(cells, i);
                const cw = clusterWidth(cells[i..cluster_end]);
                if (line_width > 0 and line_width + cw > new_width) {
                    did_break = true;
                    break;
                }
                try line_cells.appendSlice(allocator, cells[i..cluster_end]);
                line_width += cw;
                i = cluster_end;
            }

            // Pad to new_width
            while (line_cells.items.len < new_width) {
                try line_cells.append(allocator, Cell.empty());
            }

            var gl = GridLine{ .dirty = true, .wrapped = did_break };
            try gl.cells.appendSlice(allocator, line_cells.items);
            try lines.append(allocator, gl);
        }

        return lines.toOwnedSlice(allocator);
    }

    /// Reflow the grid content to `new_width`, respecting Thai cluster, CJK
    /// wide-char, and soft-wrap boundaries. All content (visible + history)
    /// is reflowed.
    pub fn reflow(self: *Grid, new_width: u32) !void {
        if (new_width == self.width) return;
        if (new_width == 0) return;

        try self.normalize();

        // ── Flatten all lines into logical lines ──
        var flat_buf: std.ArrayListUnmanaged(Cell) = .empty;
        defer flat_buf.deinit(self.allocator);

        var logical_flat: std.ArrayListUnmanaged([]Cell) = .empty;
        defer {
            for (logical_flat.items) |s| self.allocator.free(s);
            logical_flat.deinit(self.allocator);
        }

        const allocator = self.allocator;
        const total = self.history.items.len + self.lines.items.len;
        var idx: usize = 0;
        while (idx < total) {
            flat_buf.clearRetainingCapacity();
            var line_idx = idx;
            while (line_idx < total) : (line_idx += 1) {
                const line = if (line_idx < self.history.items.len)
                    &self.history.items[line_idx]
                else
                    &self.lines.items[line_idx - self.history.items.len];

                var cells_to_add = line.cells.items;
                // Trim trailing empties from the last line of a logical line
                if (!line.wrapped) {
                    while (cells_to_add.len > 0) {
                        const last = cells_to_add[cells_to_add.len - 1];
                        if (last.char == ' ' and !last.is_padding and last.comb1 == 0 and last.comb2 == 0) {
                            cells_to_add = cells_to_add[0 .. cells_to_add.len - 1];
                        } else break;
                    }
                }
                try flat_buf.appendSlice(allocator, cells_to_add);
                if (!line.wrapped) {
                    line_idx += 1;
                    break;
                }
            }
            idx = line_idx;

            // Final trim of trailing empties
            while (flat_buf.items.len > 0) {
                const last = flat_buf.items[flat_buf.items.len - 1];
                if (last.char == ' ' and !last.is_padding and last.comb1 == 0 and last.comb2 == 0) {
                    _ = flat_buf.pop();
                } else break;
            }

            const copy = try allocator.dupe(Cell, flat_buf.items);
            try logical_flat.append(allocator, copy);
        }

        // ── Save and replace old lines ──
        var old_lines = self.lines;
        var old_history = self.history;
        self.lines = .empty;
        self.history = .empty;

        // ── Rewrap each logical line and build new line set ──
        var new_lines: std.ArrayListUnmanaged(GridLine) = .empty;
        errdefer {
            for (new_lines.items) |*l| l.deinit(allocator);
            new_lines.deinit(allocator);
        }

        for (logical_flat.items) |flat| {
            const rewrapped = try rewrap(flat, new_width, allocator);
            // Cells inside rewrapped are owned by the returned GridLines.
            // We copy the GridLine structs into new_lines — the Cell data
            // pointers are shared, which is fine because we free only the
            // outer []GridLine array, not each GridLine's cells.
            try new_lines.ensureUnusedCapacity(allocator, rewrapped.len);
            for (rewrapped) |rl| {
                new_lines.appendAssumeCapacity(rl);
            }
            allocator.free(rewrapped);
        }

        // ── Deinit old lines ──
        for (old_lines.items) |*l| l.deinit(allocator);
        old_lines.deinit(allocator);
        for (old_history.items) |*l| l.deinit(allocator);
        old_history.deinit(allocator);

        // ── Split result into visible + history ──
        self.width = new_width;

        const total_len = new_lines.items.len;
        const height = self.height;
        if (total_len <= height) {
            self.lines = new_lines;
            new_lines = .empty;
            // Pad self.lines with empty lines to match self.height
            while (self.lines.items.len < height) {
                var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
                try line_cells.resize(allocator, new_width);
                @memset(line_cells.items, Cell.empty());
                try self.lines.append(allocator, GridLine{
                    .cells = line_cells,
                    .dirty = true,
                    .wrapped = false,
                });
            }
        } else {
            const h_count = total_len - height;

            // Allocate visible portion (last `height` lines)
            self.lines.items = try allocator.dupe(GridLine, new_lines.items[h_count..]);
            self.lines.capacity = @intCast(height);
            errdefer self.lines.deinit(allocator);

            // Allocate history portion (first `h_count` lines)
            self.history.items = try allocator.dupe(GridLine, new_lines.items[0..h_count]);
            self.history.capacity = @intCast(h_count);
            errdefer self.history.deinit(allocator);

            // Free new_lines backing array.
            // ArrayListUnmanaged.deinit only frees the []GridLine array, NOT
            // each GridLine's cell data. Cell data is now owned by
            // self.lines / self.history via the shallow dupe above.
            new_lines.deinit(allocator);
            new_lines = .empty;
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

test "resize to zero is no-op" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.resize(0);
    try testing.expectEqual(@as(u32, 24), grid.height);
    try testing.expectEqual(@as(usize, 24), grid.lines.items.len);
}

test "scrollDown with zero height does not crash" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);

    try grid.resize(0);
    try testing.expectEqual(@as(u32, 24), grid.height);

    try grid.scrollDown();
    // Should not crash — scrollDown should be no-op after resize(0) guard
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

test "setSize reflows content" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }
    for (0..3) |_| try grid.scrollUp();

    try testing.expectEqual(@as(usize, 3), grid.history.items.len);

    // Resize width to 40 — content should be reflowed, not truncated
    try grid.setSize(40, 5);
    try testing.expectEqual(@as(u32, 40), grid.width);

    // Content is reflowed: all lines (history + visible) are rewrapped.
    // History A,B,C should remain in history; visible D,E should remain on screen.
    try testing.expectEqual(@as(u21, 'D'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'E'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 3).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 4).char);
    try testing.expectEqual(@as(usize, 3), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.history.items[0].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'B'), grid.history.items[1].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'C'), grid.history.items[2].cells.items[0].char);
}

test "Grid clone" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    // Fill grid and scroll some lines into history
    grid.writeChar(0, 0, 'A');
    try grid.scrollUp();
    grid.writeChar(0, 0, 'B');

    try testing.expectEqual(@as(usize, 1), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.history.items[0].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 0).char);

    var copy = try grid.clone(testing.allocator);
    defer copy.deinit();

    try testing.expectEqual(@as(u32, 80), copy.width);
    try testing.expectEqual(@as(u32, 5), copy.height);
    try testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), copy.history.items[0].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'B'), copy.getCell(0, 0).char);

    // Modify clone, verify original is untouched
    copy.writeChar(0, 0, 'C');
    try testing.expectEqual(@as(u21, 'C'), copy.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 0).char);
}

test "setSize reflow narrow-to-wide unwraps content" {
    var grid = try Grid.init(testing.allocator, 10, 24);
    defer grid.deinit();

    // Write text at width=10, simulating screen wrapping.
    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }
    // Second logical line
    for ("123456789012345\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=10: 4 physical lines (2 logical, each wrapping once)
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'K'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 3).char);

    // Widen to 80
    try grid.setSize(80, 24);
    try testing.expectEqual(@as(u32, 80), grid.width);

    // Each logical line now fits on one physical line
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'Z'), grid.getCell(25, 0).char);
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '5'), grid.getCell(14, 1).char);

    // Each fits on one line — neither should be wrapped
    try testing.expect(!grid.lines.items[0].wrapped);
    try testing.expect(!grid.lines.items[1].wrapped);
}

test "setSize reflow wider preserves wrapped flags on multi-line logical groups" {
    var grid = try Grid.init(testing.allocator, 5, 24);
    defer grid.deinit();

    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=5: 6 physical lines, 1 logical line
    // Widen to 15: 2 physical lines
    try grid.setSize(15, 24);

    // Line 0 (first 15 chars): should wrap to line 1
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'O'), grid.getCell(14, 0).char);
    try testing.expect(grid.lines.items[0].wrapped);

    // Line 1 (remaining 11 chars): end of logical line
    try testing.expectEqual(@as(u21, 'P'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'Z'), grid.getCell(10, 1).char);
    try testing.expect(!grid.lines.items[1].wrapped);
}

test "setSize reflow wider with multiple logical lines preserves wrapped flags" {
    var grid = try Grid.init(testing.allocator, 5, 24);
    defer grid.deinit();

    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n12345678901234567890\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=5: 10 physical lines, 2 logical lines
    // Widen to 12: each logical wraps to 3 physical lines
    try grid.setSize(12, 24);

    // First logical line: ABCDEFGHIJKLMNOPQRSTUVWXYZ (26 chars)
    // At width=12: ABCDEFGHIJKL (wrapped), MNOPQRSTUVWX (wrapped), YZ (not)
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expect(grid.lines.items[0].wrapped);
    try testing.expectEqual(@as(u21, 'M'), grid.getCell(0, 1).char);
    try testing.expect(grid.lines.items[1].wrapped);
    try testing.expectEqual(@as(u21, 'Y'), grid.getCell(0, 2).char);
    try testing.expect(!grid.lines.items[2].wrapped);

    // Second logical line: 12345678901234567890 (20 chars)
    // At width=12: 123456789012 (wrapped), 34567890 (not wrapped, fits)
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 3).char);
    try testing.expect(grid.lines.items[3].wrapped);
    try testing.expectEqual(@as(u21, '3'), grid.getCell(0, 4).char);
    try testing.expect(!grid.lines.items[4].wrapped);
}

test "setSize reflow preserves empty lines" {
    var grid = try Grid.init(testing.allocator, 10, 5);
    defer grid.deinit();

    // Line 0: text
    grid.writeChar(0, 0, 'A');
    // Line 1: empty
    // Line 2: text
    grid.writeChar(0, 2, 'B');
    // Line 3: empty
    // Line 4: empty

    try grid.setSize(20, 5);

    // Verify empty lines are preserved between paragraphs and at the end
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 3).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(0, 4).char);

    // Verify the grid size invariant is preserved
    try testing.expectEqual(@as(usize, 5), grid.lines.items.len);
}

