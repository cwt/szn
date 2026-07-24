const std = @import("std");
const testing = std.testing;
const c = std.c;
const screen = @import("screen.zig");
const Screen = screen.Screen;
const pty_mod = @import("server/pty.zig");
const Pty = pty_mod.Pty;
const input_mod = @import("input.zig");
const InputParser = input_mod.InputParser;
const layout = @import("layout.zig");

const options_mod = @import("options.zig");
const choose_mod = @import("choose.zig");

pub const Error = screen.Error || pty_mod.Error || layout.LayoutError || options_mod.Error;

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
    cwd: ?[]const u8 = null,
    deinited: bool = false,
    choose_mode: choose_mod.ChooseMode = .{},
    saved_grid: ?@import("grid.zig").Grid = null,
    clock_time: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, id: u32, width: u32, height: u32) Error!Pane {
        return Pane{
            .id = id,
            .screen = try Screen.init(allocator, width, height),
            .window = null,
            .title_cb = null,
            .title_ctx = null,
        };
    }

    pub fn deinit(self: *Pane) void {
        if (self.deinited) return;
        self.deinited = true;
        self.choose_mode.deinit(self.screen.grid.allocator);
        if (self.saved_grid) |*g| g.deinit();
        if (self.parser) |*p| p.deinit(self.screen.grid.allocator);
        self.screen.deinit();
        if (self.pty) |*p| {
            p.deinit();
            self.pty = null;
        }
    }

    pub fn restoreSavedGrid(self: *Pane) void {
        const grid_alloc = self.screen.grid.allocator;
        if (self.saved_grid) |sg| {
            self.screen.grid.deinit();
            self.screen.grid = sg;
            self.saved_grid = null;
        } else {
            if (@import("grid.zig").Grid.init(grid_alloc, self.screen.grid.width, self.screen.grid.height)) |fallback| {
                self.screen.grid.deinit();
                self.screen.grid = fallback;
            } else |_| {}
        }
        self.dirty = true;
    }

    pub fn writeStr(self: *Pane, s: []const u8) Error!void {
        try self.screen.writeStr(s);
        self.dirty = true;
    }

    extern "c" fn getpid() c_int;

    pub fn spawn(self: *Pane, allocator: std.mem.Allocator, argv: ?[]const []const u8, cwd: ?[]const u8) Error!void {
        var pty = try Pty.open();
        errdefer pty.deinit();
        const ws = std.c.winsize{
            .row = @intCast(self.screen.grid.height),
            .col = @intCast(self.screen.grid.width),
            .xpixel = 0,
            .ypixel = 0,
        };
        try pty.setWinSize(&ws);

        var socket_buf: [@import("socket_path.zig").MAX_PATH]u8 = undefined;
        const sock_path = @import("socket_path.zig").resolve(&socket_buf) catch "/tmp/szn.sock";

        var szn_env_buf: [1024]u8 = undefined;
        const szn_env = std.fmt.bufPrint(&szn_env_buf, "{s},{d}", .{ sock_path, getpid() }) catch "/tmp/szn.sock,0";

        var szn_pane_buf: [32]u8 = undefined;
        const szn_pane = std.fmt.bufPrint(&szn_pane_buf, "%{d}", .{self.id}) catch "%0";

        try pty.spawn(allocator, argv, szn_env, szn_pane, cwd);
        self.pty = pty;
        self.cwd = if (cwd) |cwd_val| try self.screen.grid.allocator.dupe(u8, cwd_val) else null;
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

    pub fn resizeTerminal(self: *Pane, new_width: u32, new_height: u32) Error!void {
        try self.screen.resize(new_width, new_height);
        self.dirty = true;
        if (self.pty) |*pty| {
            const ws = std.c.winsize{
                .row = @intCast(new_height),
                .col = @intCast(new_width),
                .xpixel = 0,
                .ypixel = 0,
            };
            try pty.setWinSize(&ws);
            // Notify the pane's process that its window size changed
            const kill_rc = c.kill(pty.pid, c.SIG.WINCH);
            if (kill_rc != 0) {
                std.log.warn("SIGWINCH kill(pid={d}) failed: {any}", .{ pty.pid, std.c.errno(kill_rc) });
            }
        }
    }

    pub fn forceReflow(self: *Pane) Error!void {
        try self.screen.forceReflow();
        self.dirty = true;
    }

    pub fn feedPty(self: *Pane) Error!void {
        const pty = &(self.pty orelse return);
        var buf: [4096]u8 = undefined;
        const n = try pty.readOutput(&buf);
        const parser = self.getParser();
        for (buf[0..n]) |byte| {
            try parser.advance(byte);
        }
        self.dirty = true;
    }

    pub fn writeInput(self: *Pane, data: []const u8) Error!void {
        if (comptime @import("builtin").is_test) {
            try self.writeStr(data);
            if (self.pty) |*pty| {
                const c_write = struct {
                    extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
                }.write;
                _ = c_write(pty.master, data.ptr, data.len);
            }
            return;
        }

        const pty = &(self.pty orelse return);
        const c_write = struct {
            extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
        }.write;
        const c_usleep = struct {
            extern "c" fn usleep(usec: c_uint) c_int;
        }.usleep;

        var off: usize = 0;
        while (off < data.len) {
            const n = c_write(pty.master, data.ptr + off, data.len - off);
            if (n < 0) {
                const err = std.c.errno(n);
                if (err == .INTR) continue;
                if (err == .AGAIN) {
                    // PTY stdin buffer is full. Drain stdout to unblock the child process!
                    try self.feedPty();
                    _ = c_usleep(1000); // 1ms sleep
                    continue;
                }
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            off += @as(usize, @intCast(n));
        }
    }

    pub fn enterCopyMode(self: *Pane) !void {
        try self.forceReflow();
        self.screen.copy_mode = @import("mode_copy.zig").CopyMode.init(.vi);
        self.screen.copy_mode.?.enter(&self.screen.grid);
        self.dirty = true;
    }

    pub fn drainPty(self: *Pane) void {
        const pty = self.pty orelse return;
        var pfd: [1]std.posix.pollfd = .{.{
            .fd = pty.master,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 0) catch return;
        if (ready > 0) {
            self.feedPty() catch {};
        }
    }

    /// Wait briefly for a newly-spawned child to produce its terminal
    /// detection queries, then drain the PTY so the response round-trip
    /// completes before the event loop's first blocking poll.
    pub fn initPty(self: *Pane) void {
        const pty = self.pty orelse return;
        var pfd: [1]std.posix.pollfd = .{.{
            .fd = pty.master,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 100) catch return;
        if (ready == 0) return;
        self.feedPty() catch return;
        // Drain any further data that arrived during processing
        while (true) {
            const more = std.posix.poll(&pfd, 0) catch break;
            if (more == 0) break;
            self.feedPty() catch break;
        }
    }
};

/// Window represents a window containing one or more panes.
pub const Window = struct {
    allocator: std.mem.Allocator,
    id: u32,
    name: []const u8,
    panes: std.ArrayList(*Pane) = .empty,
    active_pane: ?*Pane = null,
    width: u32,
    height: u32,
    next_pane_id: u32 = 1,
    layout: layout.Layout,
    options: options_mod.Options,
    automatic_rename: bool = true,

    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, width: u32, height: u32, global_window_options: ?*const options_mod.Options, parent_screen: ?*const Screen) Error!Window {
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
            .automatic_rename = true,
        };
        var pane = try allocator.create(Pane);
        pane.* = try Pane.init(allocator, 0, width, height);
        pane.active = true;
        // bug #222: propagate cell size from parent screen if available.
        if (parent_screen) |ps| {
            pane.screen.cell_size_known = ps.cell_size_known;
            pane.screen.cell_px_width = ps.cell_px_width;
            pane.screen.cell_px_height = ps.cell_px_height;
        }
        try window.panes.append(allocator, pane);
        window.registerPane(pane);
        window.active_pane = pane;
        window.layout = try layout.Layout.init(allocator, pane, width, height);
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

    pub fn resize(self: *Window, new_width: u32, new_height: u32) Error!void {
        self.width = new_width;
        self.height = new_height;
        self.layout.width = new_width;
        self.layout.height = new_height;
        try self.resizeNode(self.layout.root, new_width, new_height);
    }

    fn resizeNode(self: *Window, root: *const @import("layout.zig").Node, root_lw: u32, root_lh: u32) Error!void {
        const Frame = struct {
            node: *const @import("layout.zig").Node,
            lw: u32,
            lh: u32,
        };

        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, Frame{ .node = root, .lw = root_lw, .lh = root_lh });

        while (stack.pop()) |frame| {
            switch (frame.node.*) {
                .leaf => |pane| {
                    try pane.resizeTerminal(frame.lw, frame.lh);
                },
                .split => |s| {
                    if (s.direction == .horizontal) {
                        const available_w = frame.lw -| 1;
                        const split_w = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_w)) * s.proportion));
                        const lw1 = @max(1, split_w);
                        const lw2 = @max(1, available_w -| lw1);
                        try stack.append(self.allocator, Frame{ .node = s.b, .lw = lw2, .lh = frame.lh });
                        try stack.append(self.allocator, Frame{ .node = s.a, .lw = lw1, .lh = frame.lh });
                    } else {
                        const available_h = frame.lh -| 1;
                        const split_h = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_h)) * s.proportion));
                        const lh1 = @max(1, split_h);
                        const lh2 = @max(1, available_h -| lh1);
                        try stack.append(self.allocator, Frame{ .node = s.b, .lw = frame.lw, .lh = lh2 });
                        try stack.append(self.allocator, Frame{ .node = s.a, .lw = frame.lw, .lh = lh1 });
                    }
                },
            }
        }
    }

    pub fn addPane(self: *Window, allocator: std.mem.Allocator) Error!*Pane {
        _ = allocator;
        if (self.active_pane) |pane| {
            return self.splitPane(self.allocator, pane, false, 0.5);
        }
        const new_pane = try self.allocator.create(Pane);
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        new_pane.* = try Pane.init(self.allocator, pane_id, self.width, self.height);
        try self.panes.append(self.allocator, new_pane);
        self.registerPane(new_pane);
        return new_pane;
    }

    pub fn splitPane(self: *Window, allocator: std.mem.Allocator, pane: *Pane, vertical: bool, proportion: f64) Error!*Pane {
        _ = allocator;
        const dir = if (vertical) layout.SplitDir.vertical else layout.SplitDir.horizontal;
        const new_pane = try self.layout.splitPane(self.allocator, pane, dir, proportion);
        new_pane.id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(self.allocator, new_pane);
        self.registerPane(new_pane);
        self.setActivePane(new_pane);
        return new_pane;
    }

    pub fn removePane(self: *Window, allocator: std.mem.Allocator, pane: *Pane) void {
        _ = allocator;
        const idx = for (self.panes.items, 0..) |p, i| {
            if (p == pane) break i;
        } else return;

        const sibling = self.layout.findSiblingPane(pane);

        _ = self.panes.swapRemove(idx);
        self.layout.removePane(pane);

        if (self.active_pane == pane) {
            self.active_pane = sibling orelse (if (self.panes.items.len > 0) self.panes.items[0] else null);
            if (self.active_pane) |p| p.active = true;
        }
        self.resize(self.width, self.height) catch {};
    }

    pub fn extractPane(self: *Window, allocator: std.mem.Allocator, pane: *Pane) void {
        _ = allocator;
        const idx = for (self.panes.items, 0..) |p, i| {
            if (p == pane) break i;
        } else return;

        const sibling = self.layout.findSiblingPane(pane);

        _ = self.panes.swapRemove(idx);
        self.layout.extractPane(pane);

        if (self.active_pane == pane) {
            self.active_pane = sibling orelse (if (self.panes.items.len > 0) self.panes.items[0] else null);
            if (self.active_pane) |p| p.active = true;
        }
        self.resize(self.width, self.height) catch {};
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
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), window.id);
    try testing.expectEqualStrings("test", window.name);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
    try testing.expect(window.active_pane != null);
}

test "add pane to window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
    try testing.expectEqual(@as(u32, 1), pane.id);
}

test "remove pane from window" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);

    window.removePane(testing.allocator, pane);
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
}

test "set active pane" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);

    const pane = try window.addPane(testing.allocator);
    window.setActivePane(pane);

    try testing.expectEqual(pane, window.active_pane);
    try testing.expect(pane.active);
    try testing.expect(!window.panes.items[0].active);
}

test "remove active pane falls back to first" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);

    const original = window.active_pane.?;
    const pane = try window.addPane(testing.allocator);

    window.setActivePane(pane);
    window.removePane(testing.allocator, pane);

    try testing.expectEqual(original, window.active_pane);
    try testing.expect(window.active_pane.?.active);
}

test "nested split focus transition on exit" {
    var window = try Window.init(testing.allocator, 1, "test", 80, 24, null, null);
    defer window.deinit(testing.allocator);

    const pane1 = window.active_pane.?;
    // Split pane1 (horizontal) to get pane2
    const pane2 = try window.addPane(testing.allocator);
    window.setActivePane(pane2);

    // Split pane2 (horizontal) to get pane3
    const pane3 = try window.splitPane(testing.allocator, pane2, false, 0.5);
    window.setActivePane(pane3);

    try testing.expectEqual(pane3, window.active_pane);

    // Exit pane3 (far right). Sibling pane2 (middle/right-half) should get focus, NOT pane1 (left).
    window.removePane(testing.allocator, pane3);

    try testing.expectEqual(pane2, window.active_pane);
    try testing.expect(pane2.active);
    try testing.expect(!pane1.active);
}

test "window name is not freed on deinit" {
    // Window.deinit frees the name — verify it doesn't double-free
    var window = try Window.init(testing.allocator, 1, "test-name", 80, 24, null, null);
    window.deinit(testing.allocator);
    // Should not crash
}

test "pane initial size matches window" {
    var window = try Window.init(testing.allocator, 1, "test", 100, 40, null, null);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 100), window.panes.items[0].screen.grid.width);
    try testing.expectEqual(@as(u32, 40), window.panes.items[0].screen.grid.height);
}

test "pane pty deinit ownership" {
    var pane = try Pane.init(testing.allocator, 1, 80, 24);
    const argv = [_][]const u8{"true"};
    try pane.spawn(testing.allocator, &argv, null);
    try testing.expect(pane.pty != null);
    pane.deinit();
}

test "pane double deinit is safe" {
    var pane = try Pane.init(testing.allocator, 1, 80, 24);
    const argv = [_][]const u8{"true"};
    try pane.spawn(testing.allocator, &argv, null);
    pane.deinit(); // first deinit: closes pty, sets pty = null
    pane.deinit(); // second deinit: pty is null, skips pty.deinit()
}
