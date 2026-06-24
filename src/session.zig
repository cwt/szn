const std = @import("std");
const testing = std.testing;
const window = @import("window.zig");
const Window = window.Window;
const options_mod = @import("options.zig");

pub const Error = window.Error || options_mod.Error;

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    id: u32,
    name: []const u8,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    active_window: ?*Window = null,
    last_window: ?*Window = null,
    width: u32,
    height: u32,
    options: options_mod.Options,
    window_options: options_mod.Options,

    pub fn init(self: *Session, backing: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32, global_options: ?*const options_mod.Options, global_window_options: ?*const options_mod.Options) Error!void {
        self.arena = std.heap.ArenaAllocator.init(backing);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        const options = if (global_options) |go| try go.clone(allocator) else try options_mod.Options.init(allocator, options_mod.SESSION_OPTIONS);
        const window_options = if (global_window_options) |gwo| try gwo.clone(allocator) else try options_mod.Options.init(allocator, options_mod.WINDOW_OPTIONS);

        self.id = id;
        self.name = try allocator.dupe(u8, name);
        self.width = width;
        self.height = height;
        self.options = options;
        self.window_options = window_options;
        self.windows = .empty;
        self.active_window = null;
        self.last_window = null;

        const initial_win = try allocator.create(Window);
        initial_win.* = try Window.init(allocator, 0, name, width, height, &self.window_options);
        // Window.init sets pane.window to a stack-local pointer; fixup to the
        // heap-allocated window so options lookups (remain-on-exit etc.) work.
        for (initial_win.panes.items) |p| p.window = initial_win;
        try self.windows.append(allocator, initial_win);
        self.active_window = initial_win;
    }

    pub fn arenaAllocator(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (self.windows.items) |win| {
            for (win.panes.items) |p| {
                p.deinit();
            }
        }
        self.arena.deinit();
    }

    pub fn resize(self: *Session, new_width: u32, new_height: u32) Error!void {
        self.width = new_width;
        self.height = new_height;
        for (self.windows.items) |win| {
            try win.resize(new_width, new_height);
        }
    }

    pub fn newWindow(self: *Session, allocator: std.mem.Allocator, name: []const u8) Error!*Window {
        _ = allocator;
        const a = self.arenaAllocator();
        const win_id = self.windows.items.len;
        const new_win = try a.create(Window);
        new_win.* = try Window.init(a, @intCast(win_id), name, self.width, self.height, &self.window_options);
        for (new_win.panes.items) |p| p.window = new_win;
        try self.windows.append(a, new_win);
        if (self.active_window) |prev| {
            self.last_window = prev;
        }
        self.active_window = new_win;
        return new_win;
    }

    pub fn killWindow(self: *Session, allocator: std.mem.Allocator, win: *Window) void {
        _ = allocator;
        const idx = for (self.windows.items, 0..) |w, i| {
            if (w == win) break i;
        } else return;

        _ = self.windows.swapRemove(idx);
        for (win.panes.items) |p| {
            p.deinit();
        }

        if (self.active_window == win) {
            self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
        }
        if (self.last_window == win) {
            self.last_window = null;
        }
    }

    pub fn setActiveWindow(self: *Session, win: *Window) void {
        if (self.active_window) |prev| {
            if (prev != win) {
                self.last_window = prev;
            }
        }
        self.active_window = win;
    }

    pub fn rename(self: *Session, allocator: std.mem.Allocator, new_name: []const u8) void {
        _ = allocator;
        const a = self.arenaAllocator();
        self.name = a.dupe(u8, new_name) catch return;
    }
};

// ── Tests ──

test "create session with initial window" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), session.id);
    try testing.expectEqualStrings("default", session.name);
    try testing.expectEqual(@as(usize, 1), session.windows.items.len);
    try testing.expect(session.active_window != null);
}

test "create new window" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    const new_win = try session.newWindow(testing.allocator, "edit");
    try testing.expectEqualStrings("edit", new_win.name);
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);
    try testing.expectEqual(new_win, session.active_window);
}

test "kill window" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    _ = try session.newWindow(testing.allocator, "edit");
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);

    const first = session.windows.items[0];
    const first_id = first.id;
    session.killWindow(testing.allocator, first);

    try testing.expectEqual(@as(usize, 1), session.windows.items.len);
    try testing.expect(session.active_window != null);
    _ = first_id;
}

test "set active window" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    const sw = try session.newWindow(testing.allocator, "edit");
    session.setActiveWindow(sw);
    try testing.expectEqual(sw, session.active_window);
}

test "rename session" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    session.rename(testing.allocator, "newname");
    try testing.expectEqualStrings("newname", session.name);
}

test "session active window persists after kill" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    const nw = try session.newWindow(testing.allocator, "edit");
    session.setActiveWindow(nw);

    const first = session.windows.items[0];
    session.killWindow(testing.allocator, first);

    try testing.expectEqual(nw, session.active_window);
}
