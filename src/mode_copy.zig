const std = @import("std");
const testing = std.testing;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;
const key_mod = @import("key.zig");
const Key = key_mod.Key;

pub const ModeKeys = enum(u8) {
    vi,
    emacs,
};

pub const Selection = struct {
    start_x: u32 = 0,
    start_y: u32 = 0,
    end_x: u32 = 0,
    end_y: u32 = 0,
    active: bool = false,
};

pub const KeyResult = enum { consumed, exit_mode, ignored };

pub const CopyMode = struct {
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    scroll_offset: u32 = 0,
    selection: Selection = .{},
    mode_keys: ModeKeys = .vi,
    search_direction: enum(u8) { forward, backward } = .forward,
    active: bool = false,

    pub fn init(mode_keys: ModeKeys) CopyMode {
        return .{ .mode_keys = mode_keys };
    }

    pub fn enter(self: *CopyMode, grid: *const Grid) void {
        self.active = true;
        self.cursor_x = 0;
        self.cursor_y = grid.height -| 1;
        self.scroll_offset = 0;
        self.selection = .{};
    }

    pub fn exit(self: *CopyMode) void {
        self.active = false;
        self.selection.active = false;
    }

    pub fn moveLeft(self: *CopyMode) void {
        if (self.cursor_x > 0) self.cursor_x -= 1;
    }

    pub fn moveRight(self: *CopyMode, grid: *const Grid) void {
        if (self.cursor_x < grid.width -| 1) self.cursor_x += 1;
    }

    pub fn moveUp(self: *CopyMode, grid: *const Grid) void {
        if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        } else if (self.scroll_offset < grid.history.items.len) {
            self.scroll_offset += 1;
        }
    }

    pub fn moveDown(self: *CopyMode, grid: *const Grid) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        } else if (self.cursor_y < grid.height -| 1) {
            self.cursor_y += 1;
        }
    }

    pub fn moveToLineStart(self: *CopyMode) void {
        self.cursor_x = 0;
    }

    pub fn moveToLineEnd(self: *CopyMode, grid: *const Grid) void {
        self.cursor_x = grid.width -| 1;
    }

    pub fn moveToTop(self: *CopyMode) void {
        self.cursor_y = 0;
        self.cursor_x = 0;
    }

    pub fn moveToBottom(self: *CopyMode, grid: *const Grid) void {
        self.cursor_y = grid.height -| 1;
        self.scroll_offset = 0;
    }

    pub fn pageUp(self: *CopyMode, grid: *const Grid) void {
        const page = grid.height;
        if (self.cursor_y >= page) {
            self.cursor_y -= page;
        } else {
            const remaining = page - self.cursor_y;
            self.cursor_y = 0;
            self.scroll_offset = @min(self.scroll_offset + remaining, @as(u32, @intCast(grid.history.items.len)));
        }
    }

    pub fn pageDown(self: *CopyMode, grid: *const Grid) void {
        const page = grid.height;
        if (self.scroll_offset >= page) {
            self.scroll_offset -= page;
        } else {
            const remaining = page - self.scroll_offset;
            self.scroll_offset = 0;
            self.cursor_y = @min(self.cursor_y + remaining, grid.height -| 1);
        }
    }

    pub fn halfPageUp(self: *CopyMode, grid: *const Grid) void {
        const half = grid.height / 2;
        if (self.cursor_y >= half) {
            self.cursor_y -= half;
        } else {
            const remaining = half - self.cursor_y;
            self.cursor_y = 0;
            self.scroll_offset = @min(self.scroll_offset + remaining, @as(u32, @intCast(grid.history.items.len)));
        }
    }

    pub fn halfPageDown(self: *CopyMode, grid: *const Grid) void {
        const half = grid.height / 2;
        if (self.scroll_offset >= half) {
            self.scroll_offset -= half;
        } else {
            const remaining = half - self.scroll_offset;
            self.scroll_offset = 0;
            self.cursor_y = @min(self.cursor_y + remaining, grid.height -| 1);
        }
    }

    pub fn startSelection(self: *CopyMode) void {
        self.selection = .{
            .start_x = self.cursor_x,
            .start_y = self.cursor_y,
            .end_x = self.cursor_x,
            .end_y = self.cursor_y,
            .active = true,
        };
    }

    pub fn updateSelection(self: *CopyMode) void {
        if (self.selection.active) {
            self.selection.end_x = self.cursor_x;
            self.selection.end_y = self.cursor_y;
        }
    }

    pub fn clearSelection(self: *CopyMode) void {
        self.selection.active = false;
    }

    pub fn isSelected(self: CopyMode, x: u32, y: u32) bool {
        if (!self.selection.active) return false;
        const sy = @min(self.selection.start_y, self.selection.end_y);
        const ey = @max(self.selection.start_y, self.selection.end_y);
        if (y < sy or y > ey) return false;

        const start_is_top = (sy == self.selection.start_y);
        const sx = if (start_is_top) self.selection.start_x else self.selection.end_x;
        const ex = if (start_is_top) self.selection.end_x else self.selection.start_x;

        if (sy == ey) {
            const min_x = @min(sx, ex);
            const max_x = @max(sx, ex);
            return x >= min_x and x <= max_x;
        }
        if (y == sy) {
            return x >= sx;
        }
        if (y == ey) {
            return x <= ex;
        }
        return true;
    }

    fn getCellAt(self: *const CopyMode, grid: *const Grid, x: u32, screen_y: u32) Cell {
        const hist_len = grid.history.items.len;
        const scroll = @as(usize, @intCast(self.scroll_offset));
        if (scroll > hist_len) return Cell.empty();

        const combined_idx = (hist_len - scroll) + @as(usize, @intCast(screen_y));

        if (combined_idx < hist_len) {
            const line = &grid.history.items[combined_idx];
            return if (x < line.cells.items.len) line.cells.items[x] else Cell.empty();
        }

        return grid.getCell(x, @as(u32, @intCast(combined_idx - hist_len)));
    }

    pub fn yankSelection(self: *const CopyMode, allocator: std.mem.Allocator, grid: *const Grid) ![]const u8 {
        if (!self.selection.active) return try allocator.dupe(u8, "");

        const sy = @min(self.selection.start_y, self.selection.end_y);
        const ey = @max(self.selection.start_y, self.selection.end_y);
        const sx = if (sy == self.selection.start_y) self.selection.start_x else 0;
        const ex = if (ey == self.selection.end_y) self.selection.end_x else grid.width -| 1;

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var screen_y = sy;
        while (screen_y <= ey) : (screen_y += 1) {
            const line_start = if (screen_y == sy) sx else 0;
            const line_end = if (screen_y == ey) @min(ex, grid.width -| 1) else grid.width -| 1;

            var x = line_start;
            while (x <= line_end) : (x += 1) {
                const cell = self.getCellAt(grid, x, screen_y);
                if (cell.char != 0 and cell.char != ' ') {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                        try result.append(allocator, '?');
                        continue;
                    };
                    try result.appendSlice(allocator, buf[0..len]);
                } else {
                    try result.append(allocator, ' ');
                }
            }

            if (screen_y < ey) {
                try result.append(allocator, '\n');
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn searchForward(self: *CopyMode, grid: *const Grid, needle: []const u8) bool {
        if (needle.len == 0) return false;

        var y = self.cursor_y;
        const x = self.cursor_x + 1;

        while (y < grid.height) : (y += 1) {
            const start_x = if (y == self.cursor_y) x else 0;
            if (searchLine(grid, y, start_x, needle)) |found_x| {
                self.cursor_x = found_x;
                self.cursor_y = y;
                return true;
            }
        }

        return false;
    }

    pub fn searchBackward(self: *CopyMode, grid: *const Grid, needle: []const u8) bool {
        if (needle.len == 0) return false;

        var y = self.cursor_y;
        while (true) {
            const start_x = if (y == self.cursor_y) self.cursor_x -| 1 else grid.width -| 1;
            if (searchLineBackward(grid, y, start_x, needle)) |found_x| {
                self.cursor_x = found_x;
                self.cursor_y = y;
                return true;
            }
            if (y == 0) break;
            y -= 1;
        }

        return false;
    }

    pub fn handleKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (!self.active) return .ignored;

        if (self.mode_keys == .vi) {
            return self.handleViKey(k, grid);
        }
        return self.handleEmacsKey(k, grid);
    }

    fn handleViKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (k == .char) {
            const c = k.char;
            if (c.mod.ctrl or c.mod.alt) return .ignored;
            switch (c.code) {
                'h' => {
                    self.moveLeft();
                    self.updateSelection();
                    return .consumed;
                },
                'j' => {
                    self.moveDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'k' => {
                    self.moveUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'l' => {
                    self.moveRight(grid);
                    self.updateSelection();
                    return .consumed;
                },
                '0' => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                '$' => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'g' => {
                    self.moveToTop();
                    self.updateSelection();
                    return .consumed;
                },
                'G' => {
                    self.moveToBottom(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'v' => {
                    if (self.selection.active) {
                        self.clearSelection();
                    } else {
                        self.startSelection();
                    }
                    return .consumed;
                },
                'y' => return .consumed,
                'q' => return .exit_mode,
                else => return .ignored,
            }
        }

        if (k == .arrow) {
            switch (k.arrow.key) {
                .left => {
                    self.moveLeft();
                    self.updateSelection();
                },
                .right => {
                    self.moveRight(grid);
                    self.updateSelection();
                },
                .up => {
                    self.moveUp(grid);
                    self.updateSelection();
                },
                .down => {
                    self.moveDown(grid);
                    self.updateSelection();
                },
            }
            return .consumed;
        }

        if (k == .special) {
            switch (k.special.key) {
                .page_up => {
                    self.pageUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .page_down => {
                    self.pageDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .home => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                .end => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .escape => return .exit_mode,
                else => return .ignored,
            }
        }

        return .ignored;
    }

    fn handleEmacsKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (k == .arrow) {
            switch (k.arrow.key) {
                .left => {
                    self.moveLeft();
                    self.updateSelection();
                },
                .right => {
                    self.moveRight(grid);
                    self.updateSelection();
                },
                .up => {
                    self.moveUp(grid);
                    self.updateSelection();
                },
                .down => {
                    self.moveDown(grid);
                    self.updateSelection();
                },
            }
            return .consumed;
        }

        if (k == .char) {
            const c = k.char;
            if (c.mod.ctrl) {
                switch (c.code) {
                    'P' => {
                        self.pageUp(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'N' => {
                        self.pageDown(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'A' => {
                        self.moveToLineStart();
                        self.updateSelection();
                        return .consumed;
                    },
                    'E' => {
                        self.moveToLineEnd(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'V' => {
                        self.pageDown(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    else => return .ignored,
                }
            }
            if (c.mod.alt) {
                switch (c.code) {
                    'V' => {
                        self.pageUp(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    '<' => {
                        self.moveToTop();
                        self.updateSelection();
                        return .consumed;
                    },
                    '>' => {
                        self.moveToBottom(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    else => return .ignored,
                }
            }
        }

        if (k == .special) {
            switch (k.special.key) {
                .page_up => {
                    self.pageUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .page_down => {
                    self.pageDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .home => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                .end => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .escape => return .exit_mode,
                else => return .ignored,
            }
        }

        return .ignored;
    }
};

fn searchLine(grid: *const Grid, y: u32, start_x: u32, needle: []const u8) ?u32 {
    if (needle.len == 0) return null;

    var x = start_x;
    while (x + needle.len <= grid.width) : (x += 1) {
        var match = true;
        for (needle, 0..) |nc, ni| {
            const cell = grid.getCell(@intCast(x + ni), y);
            if (cell.char != nc) {
                match = false;
                break;
            }
        }
        if (match) return x;
    }
    return null;
}

fn searchLineBackward(grid: *const Grid, y: u32, start_x: u32, needle: []const u8) ?u32 {
    if (needle.len == 0) return null;

    var x = start_x;
    while (true) {
        if (x + needle.len <= grid.width) {
            var match = true;
            for (needle, 0..) |nc, ni| {
                const cell = grid.getCell(@intCast(x + ni), y);
                if (cell.char != nc) {
                    match = false;
                    break;
                }
            }
            if (match) return x;
        }
        if (x == 0) break;
        x -= 1;
    }
    return null;
}

test "copy mode init" {
    const cm = CopyMode.init(.vi);
    try testing.expectEqual(ModeKeys.vi, cm.mode_keys);
    try testing.expect(!cm.active);
}

test "copy mode enter" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    try testing.expect(cm.active);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "copy mode exit" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.exit();
    try testing.expect(!cm.active);
}

test "move left" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    cm.moveLeft();
    try testing.expectEqual(@as(u32, 4), cm.cursor_x);
}

test "move left at column 0" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 0;
    cm.moveLeft();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "move right" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.moveRight(&g);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "move right at last column" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 79;
    cm.moveRight(&g);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "move up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    cm.moveUp(&g);
    try testing.expectEqual(@as(u32, 9), cm.cursor_y);
}

test "move up at top scrolls history" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 5);
    defer g.deinit();

    for (0..10) |_| try g.scrollUp();

    cm.enter(&g);
    cm.cursor_y = 0;
    cm.moveUp(&g);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
    try testing.expectEqual(@as(u32, 1), cm.scroll_offset);
}

test "move down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    cm.moveDown(&g);
    try testing.expectEqual(@as(u32, 11), cm.cursor_y);
}

test "move down at bottom" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 23;
    cm.moveDown(&g);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
}

test "move to line start" {
    var cm = CopyMode.init(.vi);
    cm.cursor_x = 42;
    cm.moveToLineStart();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "move to line end" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.moveToLineEnd(&g);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "move to top" {
    var cm = CopyMode.init(.vi);
    cm.cursor_x = 42;
    cm.cursor_y = 10;
    cm.moveToTop();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "move to bottom" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.cursor_y = 0;
    cm.moveToBottom(&g);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
}

test "page up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    cm.pageUp(&g);
    try testing.expect(cm.cursor_y < 20);
}

test "page down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.scroll_offset = 48;
    cm.cursor_y = 0;
    cm.pageDown(&g);
    try testing.expect(cm.scroll_offset < 48);
}

test "selection start and update" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    cm.cursor_y = 10;
    cm.startSelection();
    try testing.expect(cm.selection.active);
    try testing.expectEqual(@as(u32, 5), cm.selection.start_x);

    cm.cursor_x = 10;
    cm.updateSelection();
    try testing.expectEqual(@as(u32, 10), cm.selection.end_x);
}

test "selection clear" {
    var cm = CopyMode.init(.vi);
    cm.startSelection();
    cm.clearSelection();
    try testing.expect(!cm.selection.active);
}

test "yank selection single line" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'i');

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 1,
        .end_y = 0,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hi", result);
}

test "yank empty selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "search forward found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, "ello");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "search forward not found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, "xyz");
    try testing.expect(!found);
}

test "search backward found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');

    cm.cursor_x = 4;
    cm.cursor_y = 0;
    const found = cm.searchBackward(&g, "Hel");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "vi key h moves left" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    const result = cm.handleKey(Key{ .char = .{ .code = 'h', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 4), cm.cursor_x);
}

test "vi key j moves down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    const result = cm.handleKey(Key{ .char = .{ .code = 'j', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 11), cm.cursor_y);
}

test "vi key k moves up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    const result = cm.handleKey(Key{ .char = .{ .code = 'k', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 9), cm.cursor_y);
}

test "vi key l moves right" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'l', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "vi key q exits" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'q', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "vi key v toggles selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    _ = cm.handleKey(Key{ .char = .{ .code = 'v', .mod = .{} } }, &g);
    try testing.expect(cm.selection.active);

    _ = cm.handleKey(Key{ .char = .{ .code = 'v', .mod = .{} } }, &g);
    try testing.expect(!cm.selection.active);
}

test "vi key g moves to top" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    _ = cm.handleKey(Key{ .char = .{ .code = 'g', .mod = .{} } }, &g);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "vi key escape exits" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .special = .{ .key = .escape, .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "emacs key ctrl-a moves to line start" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 42;
    const result = cm.handleKey(Key{ .char = .{ .code = 'A', .mod = .{ .ctrl = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "emacs key ctrl-e moves to line end" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'E', .mod = .{ .ctrl = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "emacs key alt-v page up" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    const result = cm.handleKey(Key{ .char = .{ .code = 'V', .mod = .{ .alt = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expect(cm.cursor_y < 20);
}

test "emacs key alt-< moves to top" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 15;
    const result = cm.handleKey(Key{ .char = .{ .code = '<', .mod = .{ .alt = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "emacs key escape exits" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .special = .{ .key = .escape, .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "handle key when not active returns ignored" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    const result = cm.handleKey(Key{ .char = .{ .code = 'h', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .ignored), result);
}

test "half page up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    cm.halfPageUp(&g);
    try testing.expect(cm.cursor_y < 20);
}

test "half page down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.scroll_offset = 24;
    cm.cursor_y = 0;
    cm.halfPageDown(&g);
    try testing.expect(cm.scroll_offset < 24);
}

test "yank multi-line selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'A');
    g.writeChar(0, 1, 'B');

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 1,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "A") != null);
    try testing.expect(std.mem.indexOf(u8, result, "B") != null);
}

test "yank selection from scrolled-back history" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // Write content at top row that will scroll into history
    g.writeChar(0, 0, 'X');
    g.writeChar(1, 0, 'Y');
    g.writeChar(2, 0, 'Z');

    // Push that row into history, filling visible with empty lines
    _ = try g.scrollUp();

    // Write more content that also scrolls away
    g.writeChar(0, 0, '1');
    g.writeChar(1, 0, '2');
    _ = try g.scrollUp();
    g.writeChar(0, 0, '3');
    g.writeChar(1, 0, '4');
    _ = try g.scrollUp();

    // history now has 3 lines: [XYZ], [12], [34]
    // visible grid is empty
    try testing.expectEqual(@as(usize, 3), g.history.items.len);

    // Scroll back to see the first history line at screen_y=0
    cm.scroll_offset = 3; // show history[0] at screen_y=0
    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 2,
        .end_y = 0,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("XYZ", result);
}

test "search forward empty needle" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, "");
    try testing.expect(!found);
}

test "search backward empty needle" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchBackward(&g, "");
    try testing.expect(!found);
}
