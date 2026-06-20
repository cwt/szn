const std = @import("std");
const testing = std.testing;
const window = @import("window.zig");
const Window = window.Window;

pub const Session = struct {
    id: u32,
    name: []const u8,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    active_window: ?*Window = null,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32) !Session {
        var session = Session{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .width = width,
            .height = height,
        };
        // Create initial window
        const initial_win = try allocator.create(Window);
        initial_win.* = try Window.init(allocator, 0, name, width, height);
        try session.windows.append(allocator, initial_win);
        session.active_window = initial_win;
        return session;
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.windows.items) |win| {
            win.deinit(allocator);
            allocator.destroy(win);
        }
        self.windows.deinit(allocator);
    }

    pub fn resize(self: *Session, new_width: u32, new_height: u32) !void {
        self.width = new_width;
        self.height = new_height;
        for (self.windows.items) |win| {
            try win.resize(new_width, new_height);
        }
    }

    pub fn newWindow(self: *Session, allocator: std.mem.Allocator, name: []const u8) !*Window {
        const win_id = self.windows.items.len;
        const new_win = try allocator.create(Window);
        new_win.* = try Window.init(allocator, @intCast(win_id), name, self.width, self.height);
        try self.windows.append(allocator, new_win);
        self.active_window = new_win;
        return new_win;
    }

    pub fn killWindow(self: *Session, allocator: std.mem.Allocator, win: *Window) void {
        const idx = for (self.windows.items, 0..) |w, i| {
            if (w == win) break i;
        } else return;

        _ = self.windows.swapRemove(idx);
        win.deinit(allocator);
        allocator.destroy(win);

        if (self.active_window == win) {
            self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
        }
    }

    pub fn setActiveWindow(self: *Session, win: *Window) void {
        self.active_window = win;
    }

    pub fn rename(self: *Session, allocator: std.mem.Allocator, new_name: []const u8) void {
        allocator.free(self.name);
        self.name = allocator.dupe(u8, new_name) catch self.name;
    }
};

// ── Tests ──

test "create session with initial window" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), session.id);
    try testing.expectEqualStrings("default", session.name);
    try testing.expectEqual(@as(usize, 1), session.windows.items.len);
    try testing.expect(session.active_window != null);
}

test "create new window" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    const new_win = try session.newWindow(testing.allocator, "edit");
    try testing.expectEqualStrings("edit", new_win.name);
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);
    try testing.expectEqual(new_win, session.active_window);
}

test "kill window" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    _ = try session.newWindow(testing.allocator, "edit");
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);

    // Kill the first window (index 0)
    const first = session.windows.items[0];
    const first_id = first.id;
    session.killWindow(testing.allocator, first);

    try testing.expectEqual(@as(usize, 1), session.windows.items.len);
    try testing.expect(session.active_window != null);
    _ = first_id;
}

test "set active window" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    const sw = try session.newWindow(testing.allocator, "edit");
    session.setActiveWindow(sw);
    try testing.expectEqual(sw, session.active_window);
}

test "rename session" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    session.rename(testing.allocator, "newname");
    try testing.expectEqualStrings("newname", session.name);
}

test "session active window persists after kill" {
    var session = try Session.init(testing.allocator, 1, "default", 80, 24);
    defer session.deinit(testing.allocator);

    const nw = try session.newWindow(testing.allocator, "edit");
    session.setActiveWindow(nw);

    // Killing a non-active window shouldn't change active
    const first = session.windows.items[0];
    session.killWindow(testing.allocator, first);

    try testing.expectEqual(nw, session.active_window);
}
