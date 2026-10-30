const std = @import("std");
const testing = std.testing;
const window = @import("window.zig");
const Window = window.Window;
const options_mod = @import("options.zig");

pub const Error = window.Error || options_mod.Error;

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: u32,
    name: []const u8,
    /// Inline storage backing `name` after the first rename. Mirrors
    /// Window.setName: renaming previously duped into the session arena on
    /// every call with no way to release the old slice (bug #385).
    name_buf: [256]u8 = undefined,
    windows: std.ArrayList(*Window) = .empty,
    active_window: ?*Window = null,
    last_window: ?*Window = null,
    width: u32,
    height: u32,
    options: options_mod.Options,
    window_options: options_mod.Options,
    next_win_id: u32 = 0,
    /// Incremented when pane-border-format changes. Used to invalidate
    /// per-pane border format caches (bug #304/#307).
    border_format_gen: u32 = 0,
    active_window_dirty: bool = false,

    pub fn init(self: *Session, backing: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32, global_options: ?*const options_mod.Options, global_window_options: ?*const options_mod.Options) Error!void {
        self.allocator = backing;
        const allocator = backing;

        var options = if (global_options) |go| try go.clone(allocator) else try options_mod.Options.init(allocator, options_mod.SESSION_OPTIONS);
        errdefer options.deinit();
        var window_options = if (global_window_options) |gwo| try gwo.clone(allocator) else try options_mod.Options.init(allocator, options_mod.WINDOW_OPTIONS);
        errdefer window_options.deinit();

        self.id = id;
        const name_len = @min(name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..name_len], name[0..name_len]);
        self.name = self.name_buf[0..name_len];
        self.width = width;
        self.height = height;
        self.options = options;
        self.window_options = window_options;
        self.windows = .empty;
        errdefer self.windows.deinit(allocator);
        self.active_window = null;
        self.last_window = null;
        self.next_win_id = 1;

        const initial_win = try allocator.create(Window);
        errdefer allocator.destroy(initial_win);
        initial_win.* = try Window.init(allocator, 0, name, width, height, &self.window_options, null);
        errdefer initial_win.deinit(allocator);
        initial_win.setName(name);
        // Window.init sets pane.window to a stack-local pointer; fixup to the
        // heap-allocated window so options lookups (remain-on-exit etc.) work.
        const hlimit: ?u32 = if (self.options.get("history-limit")) |hl| @intCast(hl.number) else null;
        for (initial_win.panes.items) |p| {
            p.window = initial_win;
            p.title_ctx = @ptrCast(initial_win);
            if (hlimit) |hl| p.screen.grid.setHistoryLimit(hl);
        }
        try self.windows.append(allocator, initial_win);
        self.active_window = initial_win;
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (self.windows.items) |win| {
            for (win.panes.items) |p| {
                p.valid = false;
            }
            win.deinit(self.allocator);
            self.allocator.destroy(win);
        }
        self.windows.deinit(self.allocator);
        self.options.deinit();
        self.window_options.deinit();
    }

    pub fn resize(self: *Session, new_width: u32, new_height: u32) Error!void {
        const old_width = self.width;
        const old_height = self.height;
        var i: usize = 0;
        errdefer {
            for (self.windows.items[0..i]) |win| {
                win.resize(old_width, old_height) catch |err| {
                    std.log.err("rollback of window resize failed: {t}", .{err});
                };
            }
            self.width = old_width;
            self.height = old_height;
        }
        for (self.windows.items) |win| {
            try win.resize(new_width, new_height);
            i += 1;
        }
        self.width = new_width;
        self.height = new_height;
    }

    pub fn newWindow(self: *Session, allocator: std.mem.Allocator, name: []const u8) Error!*Window {
        _ = allocator;
        const a = self.allocator;
        const win_id = self.next_win_id;
        const new_win = try a.create(Window);
        errdefer a.destroy(new_win);
        new_win.* = try Window.init(a, @intCast(win_id), name, self.width, self.height, &self.window_options, null);
        errdefer new_win.deinit(a);
        new_win.setName(name);
        const hlimit: ?u32 = if (self.options.get("history-limit")) |hl| @intCast(hl.number) else null;
        for (new_win.panes.items) |p| {
            p.window = new_win;
            p.title_ctx = @ptrCast(new_win);
            if (hlimit) |hl| p.screen.grid.setHistoryLimit(hl);
        }
        try self.windows.append(a, new_win);
        self.next_win_id += 1;
        if (self.active_window) |prev| {
            self.last_window = prev;
        }
        self.active_window = new_win;
        self.active_window_dirty = true;
        return new_win;
    }

    pub fn killWindow(self: *Session, allocator: std.mem.Allocator, win: *Window) void {
        _ = allocator;
        const idx = for (self.windows.items, 0..) |w, i| {
            if (w == win) break i;
        } else return;

        _ = self.windows.swapRemove(idx);
        for (win.panes.items) |p| {
            p.valid = false;
        }
        win.deinit(self.allocator);
        self.allocator.destroy(win);

        if (self.active_window == win) {
            self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
        }
        if (self.last_window == win) {
            self.last_window = null;
        }
        self.active_window_dirty = true;
    }

    pub fn setActiveWindow(self: *Session, win: *Window) void {
        if (self.active_window == win) return;
        if (self.active_window) |prev| {
            self.last_window = prev;
        }
        self.active_window = win;
        self.active_window_dirty = true;
    }

    pub fn rename(self: *Session, allocator: std.mem.Allocator, new_name: []const u8) void {
        _ = allocator;
        const len = @min(new_name.len, self.name_buf.len);
        const changed = (self.name.len != len or !std.mem.eql(u8, self.name, new_name[0..len]));
        @memcpy(self.name_buf[0..len], new_name[0..len]);
        self.name = self.name_buf[0..len];
        if (changed) {
            self.active_window_dirty = true;
        }
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

test "window IDs are unique after kills — bug #137" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "default", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    const w1 = try session.newWindow(testing.allocator, "one");
    const w1_id = w1.id;
    const w2 = try session.newWindow(testing.allocator, "two");
    _ = w2;

    session.killWindow(testing.allocator, w1);
    const w3 = try session.newWindow(testing.allocator, "three");
    try testing.expect(w3.id != w1_id);
    try testing.expect(w3.id > w1_id);
}

test "session arena allocator manages window and pane memory — bug #245" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "test-arena", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    const win = try session.newWindow(testing.allocator, "win2");
    _ = try win.addPane(testing.allocator);

    try testing.expectEqual(2, session.windows.items.len);
    try testing.expectEqual(2, win.panes.items.len);
}

test "session resize updates all windows — bug #412" {
    var session: Session = undefined;
    try session.init(testing.allocator, 1, "test-resize", 80, 24, null, null);
    defer session.deinit(testing.allocator);

    _ = try session.newWindow(testing.allocator, "win2");
    try session.resize(100, 30);
    try testing.expectEqual(@as(u32, 100), session.width);
    try testing.expectEqual(@as(u32, 30), session.height);
    for (session.windows.items) |w| {
        try testing.expectEqual(@as(u32, 100), w.width);
        try testing.expectEqual(@as(u32, 30), w.height);
    }
}

test "session reclaims memory across repeated reflow, alt-screen, option, and window-kill cycles — bug #542" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();

    var session: Session = undefined;
    try session.init(alloc, 1, "test-542", 80, 24, null, null);
    defer session.deinit(alloc);

    const main_win = session.active_window.?;
    const main_pane = main_win.active_pane.?;
    try main_pane.writeStr("hello world this is a long line of text that will wrap and reflow when resized\r\n");

    // Warm-up cycle to establish steady-state capacity.
    {
        const w = try session.newWindow(alloc, "temp");
        session.killWindow(alloc, w);
        try session.resize(40, 24);
        try session.resize(80, 24);
        try main_pane.screen.useAltScreen(true);
        try main_pane.screen.useAltScreen(false);
        try session.options.set("status-left", .{ .string = "[custom] " });
        try session.options.unset("status-left");
    }

    const live_after_warmup = failing.allocated_bytes - failing.freed_bytes;

    // 10 more cycles must not accumulate unreclaimed allocations.
    var iter: usize = 0;
    while (iter < 10) : (iter += 1) {
        const w = try session.newWindow(alloc, "temp");
        session.killWindow(alloc, w);
        try session.resize(40, 24);
        try session.resize(80, 24);
        try main_pane.screen.useAltScreen(true);
        try main_pane.screen.useAltScreen(false);
        try session.options.set("status-left", .{ .string = "[custom] " });
        try session.options.unset("status-left");
    }

    const live_after_loops = failing.allocated_bytes - failing.freed_bytes;
    try testing.expectEqual(live_after_warmup, live_after_loops);
}
