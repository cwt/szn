const std = @import("std");
const testing = std.testing;
const grid_mod = @import("grid.zig");
const Cell = grid_mod.Cell;
const Grid = grid_mod.Grid;
const key_mod = @import("key.zig");
const Key = key_mod.Key;

pub const ChooseTarget = enum {
    buffer,
    command,
};

pub const ChooseItem = struct {
    name: []const u8,
    data: []const u8,
};

pub const ChooseMode = struct {
    items: std.ArrayListUnmanaged(ChooseItem) = .empty,
    cursor: u32 = 0,
    scroll: u32 = 0,
    active: bool = false,
    target: ChooseTarget = .buffer,

    pub fn deinit(self: *ChooseMode, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            allocator.free(item.name);
            allocator.free(item.data);
        }
        self.items.deinit(allocator);
    }

    pub fn enter(self: *ChooseMode, allocator: std.mem.Allocator, items: []const ChooseItem) !void {
        for (self.items.items) |*item| {
            allocator.free(item.name);
            allocator.free(item.data);
        }
        self.items.clearRetainingCapacity();
        self.active = true;
        self.cursor = 0;
        self.scroll = 0;
        self.target = .buffer;
        for (items) |item| {
            const n = try allocator.dupe(u8, item.name);
            errdefer allocator.free(n);
            const d = try allocator.dupe(u8, item.data);
            errdefer allocator.free(d);
            try self.items.append(allocator, .{ .name = n, .data = d });
        }
    }

    pub fn renderIntoGrid(self: *ChooseMode, grid: *Grid) void {
        const header = if (self.target == .command) "-- commands --" else "-- buffers --";
        const hdr_y = 0;
        const start_y = hdr_y + 1;
        const max_visible = grid.height -| 1;

        if (max_visible > 0) {
            if (self.cursor < self.scroll) {
                self.scroll = self.cursor;
            } else if (self.cursor >= self.scroll + max_visible) {
                self.scroll = self.cursor - max_visible + 1;
            }
        }

        grid.clear();
        for (header, 0..) |ch, col| {
            grid.setCell(@intCast(col), hdr_y, .{ .char = ch, .attr = .{ .bold = true }, .fg = .default_(), .bg = .default_() });
        }

        const available = @min(max_visible, self.items.items.len -| self.scroll);
        var i: u32 = 0;
        while (i < available) : (i += 1) {
            const item_idx = self.scroll + i;
            const item = self.items.items[item_idx];
            const prefix = if (item_idx == self.cursor) "> " else "  ";
            var col: u32 = 0;
            for (prefix, 0..) |ch, ci| {
                const a: grid_mod.Attr = if (item_idx == self.cursor) .{ .bold = true, .reverse = true } else .{};
                grid.setCell(col + @as(u32, @intCast(ci)), start_y + i, .{ .char = ch, .attr = a, .fg = .default_(), .bg = .default_() });
            }
            col += @intCast(prefix.len);
            for (item.name, 0..) |ch, ci| {
                const a: grid_mod.Attr = if (item_idx == self.cursor) .{ .reverse = true } else .{};
                grid.setCell(col + @as(u32, @intCast(ci)), start_y + i, .{ .char = ch, .attr = a, .fg = .default_(), .bg = .default_() });
            }
        }
    }

    pub fn handleKey(self: *ChooseMode, k: Key, _: std.mem.Allocator) !enum { consumed, selected, cancelled } {
        if (!self.active) return .cancelled;
        if (k == .special) {
            if (k.special.key == .escape) {
                self.active = false;
                return .cancelled;
            }
            if (k.special.key == .enter) {
                if (self.cursor < self.items.items.len) {
                    return .selected;
                }
                return .cancelled;
            }
        }
        if (k == .arrow) {
            if (k.arrow.key == .up) {
                if (self.cursor > 0) self.cursor -= 1;
                return .consumed;
            }
            if (k.arrow.key == .down) {
                if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
                return .consumed;
            }
        }
        if (k == .char) {
            if (k.char.code == 'q') {
                self.active = false;
                return .cancelled;
            }
            if (k.char.code == '\r' or k.char.code == '\n') {
                if (self.cursor < self.items.items.len) {
                    return .selected;
                }
                return .cancelled;
            }
        }
        return .consumed;
    }

    pub fn selectedItem(self: *const ChooseMode) ?ChooseItem {
        if (self.cursor >= self.items.items.len) return null;
        return self.items.items[self.cursor];
    }
};

test "choose mode navigation" {
    var cm = ChooseMode{};
    defer cm.deinit(testing.allocator);

    const items = [_]ChooseItem{
        .{ .name = "a", .data = "1" },
        .{ .name = "b", .data = "2" },
        .{ .name = "c", .data = "3" },
    };
    try cm.enter(testing.allocator, &items);

    try testing.expectEqual(@as(u32, 0), cm.cursor);

    _ = try cm.handleKey(Key{ .arrow = .{ .key = .down } }, testing.allocator);
    try testing.expectEqual(@as(u32, 1), cm.cursor);

    _ = try cm.handleKey(Key{ .arrow = .{ .key = .up } }, testing.allocator);
    try testing.expectEqual(@as(u32, 0), cm.cursor);

    const result = try cm.handleKey(Key{ .char = .{ .code = '\r', .mod = .{} } }, testing.allocator);
    try testing.expectEqual(@as(@TypeOf(result), .selected), result);
    try testing.expectEqualStrings("a", cm.selectedItem().?.name);
}

test "choose mode cancel" {
    var cm = ChooseMode{};
    defer cm.deinit(testing.allocator);

    try cm.enter(testing.allocator, &.{
        .{ .name = "test", .data = "data" },
    });

    const result = try cm.handleKey(Key{ .char = .{ .code = 'q', .mod = .{} } }, testing.allocator);
    try testing.expectEqual(@as(@TypeOf(result), .cancelled), result);
    try testing.expect(!cm.active);
}

test "choose mode scrolling" {
    var cm = ChooseMode{};
    defer cm.deinit(testing.allocator);

    const items = [_]ChooseItem{
        .{ .name = "a", .data = "1" },
        .{ .name = "b", .data = "2" },
        .{ .name = "c", .data = "3" },
        .{ .name = "d", .data = "4" },
        .{ .name = "e", .data = "5" },
    };
    try cm.enter(testing.allocator, &items);

    var grid = try Grid.init(testing.allocator, 80, 3); // 3 rows -> 1 header + 2 visible items
    defer grid.deinit();

    // Render 1: cursor is at 0, scroll should be 0
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 0), cm.scroll);

    // Go down to index 1 (visible)
    _ = try cm.handleKey(Key{ .arrow = .{ .key = .down } }, testing.allocator);
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 0), cm.scroll);

    // Go down to index 2 (scrolls viewport)
    _ = try cm.handleKey(Key{ .arrow = .{ .key = .down } }, testing.allocator);
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 1), cm.scroll);

    // Go down to index 3 (scrolls viewport)
    _ = try cm.handleKey(Key{ .arrow = .{ .key = .down } }, testing.allocator);
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 2), cm.scroll);

    // Go up to index 2 (within viewport, scroll remains same)
    _ = try cm.handleKey(Key{ .arrow = .{ .key = .up } }, testing.allocator);
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 2), cm.scroll);

    // Go up to index 1 (scrolls viewport up)
    _ = try cm.handleKey(Key{ .arrow = .{ .key = .up } }, testing.allocator);
    cm.renderIntoGrid(&grid);
    try testing.expectEqual(@as(u32, 1), cm.scroll);
}
