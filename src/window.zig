const std = @import("std");
const testing = std.testing;
const c = std.c;
const screen = @import("screen.zig");
const Screen = screen.Screen;
const pty_mod = @import("server/pty.zig");
const Pty = pty_mod.Pty;
const input_mod = @import("input.zig");
const InputParser = input_mod.InputParser;

/// Pane represents a single terminal pane within a window.
pub const Pane = struct {
    id: u32,
    screen: Screen,
    active: bool = false,
    pty: ?Pty = null,
    parser: ?InputParser = null,
    dirty: bool = false,
    window: ?*Window = null,
    title_cb: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
    title_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, id: u32, width: u32, height: u32) !Pane {
        return Pane{
            .id = id,
            .screen = try Screen.init(allocator, width, height),
            .window = null,
            .title_cb = null,
            .title_ctx = null,
        };
    }

    pub fn deinit(self: *Pane) void {
        self.screen.deinit();
        if (self.pty) |*p| p.deinit();
    }

    pub fn writeStr(self: *Pane, s: []const u8) !void {
        try self.screen.writeStr(s);
        self.dirty = true;
    }

    pub fn spawn(self: *Pane, allocator: std.mem.Allocator, argv: ?[]const []const u8) !void {
        var pty = try Pty.open();
        errdefer pty.deinit();
        const ws = std.c.winsize{
            .row = @intCast(self.screen.grid.height),
            .col = @intCast(self.screen.grid.width),
            .xpixel = 0,
            .ypixel = 0,
        };
        try pty.setWinSize(&ws);
        try pty.spawn(allocator, argv);
        self.pty = pty;
    }

    pub fn getParser(self: *Pane) *InputParser {
        if (self.parser == null) {
            self.parser = InputParser.init(&self.screen);
            self.parser.?.title_cb = paneTitleCallback;
            self.parser.?.title_ctx = self;
        }
        if (self.pty) |*p| {
            self.parser.?.pty = p;
        } else {
            self.parser.?.pty = null;
        }
        return &(self.parser.?);
    }

    pub fn resizeTerminal(self: *Pane, new_width: u32, new_height: u32) !void {
        try self.screen.resize(new_width, new_height);
        if (self.pty) |*pty| {
            const ws = std.c.winsize{
                .row = @intCast(new_height),
                .col = @intCast(new_width),
                .xpixel = 0,
                .ypixel = 0,
            };
            try pty.setWinSize(&ws);
            // Notify the pane's process that its window size changed
            _ = c.kill(pty.pid, c.SIG.WINCH);
        }
    }

    pub fn feedPty(self: *Pane) !void {
        const pty = &(self.pty orelse return);
        var buf: [4096]u8 = undefined;
        const n = pty.readOutput(&buf) catch |err| {
            pty.deinit();
            self.pty = null;
            return err;
        };
        const parser = self.getParser();
        for (buf[0..n]) |byte| {
            try parser.advance(byte);
        }
        self.dirty = true;
    }
};

/// Window represents a window containing one or more panes.
pub const Window = struct {
    allocator: std.mem.Allocator,
    id: u32,
    name: []const u8,
    panes: std.ArrayListUnmanaged(*Pane) = .empty,
    active_pane: ?*Pane = null,
    width: u32,
    height: u32,
    next_pane_id: u32 = 1,
    layout: @import("layout.zig").Layout,
    options: @import("options.zig").Options,

    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32, global_window_options: ?*const @import("options.zig").Options) !Window {
        const options_mod = @import("options.zig");
        var options = if (global_window_options) |gwo| try gwo.clone(allocator) else try options_mod.Options.init(allocator, options_mod.WINDOW_OPTIONS);
        errdefer options.deinit();

        var window = Window{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
            .width = width,
            .height = height,
            .layout = undefined,
            .options = options,
        };
        var pane = try allocator.create(Pane);
        pane.* = try Pane.init(allocator, 0, width, height);
        pane.active = true;
        try window.panes.append(allocator, pane);
        window.registerPane(pane);
        window.active_pane = pane;
        window.layout = try @import("layout.zig").Layout.init(allocator, pane, width, height);
        return window;
    }

    pub fn registerPane(self: *Window, pane: *Pane) void {
        pane.window = self;
        pane.title_cb = windowTitleCallback;
        pane.title_ctx = self;
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.layout.deinit();
        self.panes.deinit(allocator);
        self.options.deinit();
    }

    pub fn resize(self: *Window, new_width: u32, new_height: u32) !void {
        self.width = new_width;
        self.height = new_height;
        for (self.panes.items) |pane| {
            try pane.resizeTerminal(new_width, new_height);
        }
    }

    pub fn addPane(self: *Window, allocator: std.mem.Allocator) !*Pane {
        if (self.active_pane) |pane| {
            return self.splitPane(allocator, pane, false, 0.5);
        }
        const new_pane = try allocator.create(Pane);
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        new_pane.* = try Pane.init(allocator, pane_id, self.width, self.height);
        try self.panes.append(allocator, new_pane);
        self.registerPane(new_pane);
        return new_pane;
    }

    pub fn splitPane(self: *Window, allocator: std.mem.Allocator, pane: *Pane, vertical: bool, proportion: f64) !*Pane {
        const dir = if (vertical) @import("layout.zig").SplitDir.vertical else @import("layout.zig").SplitDir.horizontal;
        const new_pane = try self.layout.splitPane(allocator, pane, dir, proportion);
        new_pane.id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(allocator, new_pane);
        self.registerPane(new_pane);
        self.setActivePane(new_pane);
        return new_pane;
    }

    pub fn removePane(self: *Window, allocator: std.mem.Allocator, pane: *Pane) void {
        _ = allocator;
        const idx = for (self.panes.items, 0..) |p, i| {
            if (p == pane) break i;
        } else return;

        _ = self.panes.swapRemove(idx);
        self.layout.removePane(pane);

        if (self.active_pane == pane) {
            self.active_pane = if (self.panes.items.len > 0) self.panes.items[0] else null;
            if (self.active_pane) |p| p.active = true;
        }
    }

    pub fn extractPane(self: *Window, allocator: std.mem.Allocator, pane: *Pane) void {
        _ = allocator;
        const idx = for (self.panes.items, 0..) |p, i| {
            if (p == pane) break i;
        } else return;

        _ = self.panes.swapRemove(idx);
        self.layout.extractPane(pane);

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

fn paneTitleCallback(ctx: ?*anyopaque, title: []const u8) void {
    const self: *Pane = @ptrCast(@alignCast(ctx orelse return));
    if (self.title_cb) |cb| {
        cb(self.title_ctx, title);
    }
}

fn windowTitleCallback(ctx: ?*anyopaque, title: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx orelse return));
    if (title.len == 0) return;
    if (std.mem.eql(u8, self.name, title)) return;

    const new_name = self.allocator.dupe(u8, title) catch return;
    self.allocator.free(self.name);
    self.name = new_name;
    for (self.panes.items) |p| {
        p.dirty = true;
    }
}

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
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null);
    defer window.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), window.id);
    try testing.expectEqualStrings("test", window.name);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
    try testing.expect(window.active_pane != null);
}

test "add pane to window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
    try testing.expectEqual(@as(u32, 1), pane.id);
}

test "remove pane from window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);

    window.removePane(testing.allocator, pane);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
}

test "set active pane" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    window.setActivePane(pane);

    try testing.expectEqual(pane, window.active_pane);
    try testing.expect(pane.active);
    try testing.expect(!window.panes.items[0].active);
}

test "remove active pane falls back to first" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null);
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
    var window = try Window.init(testing.allocator, 1, "test-name", 80, 24, null);
    window.deinit(testing.allocator);
    // Should not crash
}

test "pane initial size matches window" {
    var window = try Window.init(testing.allocator, 1, "test", 100, 40, null);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 100), window.panes.items[0].screen.grid.width);
    try testing.expectEqual(@as(u32, 40), window.panes.items[0].screen.grid.height);
}
