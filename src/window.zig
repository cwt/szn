const std = @import("std");
const testing = std.testing;
const screen = @import("screen.zig");
const Screen = screen.Screen;

/// Pane represents a single terminal pane within a window.
pub const Pane = struct {
    id: u32,
    screen: Screen,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32, width: u32, height: u32) !Pane {
        return Pane{
            .id = id,
            .screen = try Screen.init(allocator, width, height),
        };
    }

    pub fn deinit(self: *Pane) void {
        self.screen.deinit();
    }

    pub fn writeStr(self: *Pane, s: []const u8) !void {
        try self.screen.writeStr(s);
    }
};

/// Window represents a window containing one or more panes.
pub const Window = struct {
    id: u32,
    name: []const u8,
    panes: std.ArrayListUnmanaged(*Pane) = .empty,
    active_pane: ?*Pane = null,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32) !Window {
        var window = Window{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .width = width,
            .height = height,
        };
        // Create initial pane
        var pane = try allocator.create(Pane);
        pane.* = try Pane.init(allocator, 0, width, height);
        pane.active = true;
        try window.panes.append(allocator, pane);
        window.active_pane = pane;
        return window;
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.panes.items) |pane| {
            pane.deinit();
            allocator.destroy(pane);
        }
        self.panes.deinit(allocator);
    }

    pub fn addPane(self: *Window, allocator: std.mem.Allocator) !*Pane {
        const new_pane = try allocator.create(Pane);
        const pane_id = self.panes.items.len;
        new_pane.* = try Pane.init(allocator, @intCast(pane_id), self.width, self.height);
        try self.panes.append(allocator, new_pane);
        return new_pane;
    }

    pub fn removePane(self: *Window, allocator: std.mem.Allocator, pane: *Pane) void {
        const idx = for (self.panes.items, 0..) |p, i| {
            if (p == pane) break i;
        } else return;

        _ = self.panes.swapRemove(idx);
        pane.deinit();
        allocator.destroy(pane);

        // Fix active pane
        if (self.active_pane == pane) {
            self.active_pane = if (self.panes.items.len > 0) self.panes.items[0] else null;
            if (self.active_pane) |p| p.active = true;
        }
    }

    pub fn setActivePane(self: *Window, pane: *Pane) void {
        if (self.active_pane) |prev| prev.active = false;
        pane.active = true;
        self.active_pane = pane;
    }
};

// ── Tests ──

test "create pane" {
    var pane = try Pane.init(testing.allocator, 0, 80, 24);
    defer pane.deinit();
    try testing.expectEqual(@as(u32, 0), pane.id);
    try testing.expectEqual(@as(u32, 80), pane.screen.grid.width);
}

test "pane write string" {
    var pane = try Pane.init(testing.allocator, 0, 80, 24);
    defer pane.deinit();
    try pane.writeStr("hello");
    try testing.expectEqual(@as(u21, 'h'), pane.screen.grid.getCell(0, 0).char);
}

test "create window with initial pane" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24);
    defer window.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), window.id);
    try testing.expectEqualStrings("test", window.name);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
    try testing.expect(window.active_pane != null);
}

test "add pane to window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
    try testing.expectEqual(@as(u32, 1), pane.id);
}

test "remove pane from window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);

    window.removePane(testing.allocator, pane);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
}

test "set active pane" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    window.setActivePane(pane);

    try testing.expectEqual(pane, window.active_pane);
    try testing.expect(pane.active);
    try testing.expect(!window.panes.items[0].active);
}

test "remove active pane falls back to first" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24);
    defer window.deinit(testing.allocator);

    const original = window.active_pane.?;
    const pane = try window.addPane(testing.allocator);

    window.setActivePane(pane);
    window.removePane(testing.allocator, pane);

    try testing.expectEqual(original, window.active_pane);
    try testing.expect(window.active_pane.?.active);
}

test "window name is not freed on deinit" {
    // Window.deinit frees the name — verify it doesn't double-free
    var window = try Window.init(testing.allocator, 1, "test-name", 80, 24);
    window.deinit(testing.allocator);
    // Should not crash
}

test "pane initial size matches window" {
    var window = try Window.init(testing.allocator, 1, "test", 100, 40);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 100), window.panes.items[0].screen.grid.width);
    try testing.expectEqual(@as(u32, 40), window.panes.items[0].screen.grid.height);
}
