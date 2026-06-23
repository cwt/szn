const std = @import("std");
const c = std.c;
const testing = std.testing;
const session_mod = @import("../session.zig");

var sigchldFlag = std.atomic.Value(bool).init(false);

pub export fn sigchld_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigchldFlag.store(true, .seq_cst);
}
const Session = session_mod.Session;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const Pane = window_mod.Pane;
const loop_mod = @import("loop.zig");
const Loop = loop_mod.Loop;
const socket_mod = @import("socket.zig");
const message_reader = @import("message_reader.zig");
const MessageReader = message_reader.MessageReader;
const protocol = @import("protocol.zig");
const render = @import("render.zig");
const Display = render.Display;
const key_binding_mod = @import("../key_binding.zig");
const pty_mod = @import("pty.zig");
const cfg = @import("../cfg.zig");
const options = @import("../options.zig");

extern "c" fn fopen(filename: [*c]const u8, modes: [*c]const u8) ?*anyopaque;
extern "c" fn fclose(stream: ?*anyopaque) c_int;
extern "c" fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: ?*anyopaque) c_long;
extern "c" fn fread(ptr: ?*anyopaque, size: usize, n: usize, stream: ?*anyopaque) usize;
extern "c" fn access(pathname: [*c]const u8, mode: c_int) c_int;

const passwd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: c.uid_t,
    pw_gid: c.gid_t,
    pw_change: c_long,
    pw_class: [*:0]const u8,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
    pw_expire: c_long,
};

extern "c" fn getuid() c.uid_t;
extern "c" fn getpwuid(uid: c.uid_t) ?*const passwd;

pub const Server = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(*Session) = .empty,
    next_session_id: u32 = 1,
    next_window_id: u32 = 1,
    next_pane_id: u32 = 1,
    listener_fd: ?i32 = null,
    client_fds: std.ArrayListUnmanaged(i32) = .empty,
    client_readers: std.AutoHashMap(i32, *MessageReader),
    input_reader: @import("../tty/tty_key.zig").InputReader = .{},
    dispatcher: @import("../key_binding.zig").KeyDispatcher,
    stdin_fd: ?i32 = null,
    loop: Loop = .{},
    global_options: @import("../options.zig").Options,
    global_window_options: @import("../options.zig").Options,
    response_buf: std.ArrayList(u8),
    display_client_fd: ?i32 = null,
    render_buf: std.ArrayList(u8),
    paste_buffer: ?[]const u8 = null,
    log_messages: std.ArrayListUnmanaged([]const u8) = .empty,
    display_sx: u32 = 80,
    display_sy: u32 = 24,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) ServerError!Server {
        const key_binding = @import("../key_binding.zig");
        const key_mod = @import("../key.zig");
        const options_mod = @import("../options.zig");
        var global_options = try options_mod.Options.init(allocator, options_mod.SESSION_OPTIONS);
        errdefer global_options.deinit();

        var global_window_options = try options_mod.Options.init(allocator, options_mod.WINDOW_OPTIONS);
        errdefer global_window_options.deinit();

        const prefix_val = global_options.get("prefix") orelse options_mod.OptionValue{ .key = key_mod.Key{ .char = .{ .code = 'b', .mod = .{ .ctrl = true } } } };
        const prefix = if (prefix_val == .key) prefix_val.key else key_mod.Key{ .char = .{ .code = 'b', .mod = .{ .ctrl = true } } };

        var dispatcher = key_binding.KeyDispatcher.init(allocator, prefix);
        errdefer dispatcher.deinit();
        try key_binding.loadDefaults(&dispatcher.prefix_table);

        var render_buf: std.ArrayList(u8) = .empty;
        errdefer render_buf.deinit(allocator);

        return Server{
            .allocator = allocator,
            .client_readers = std.AutoHashMap(i32, *MessageReader).init(allocator),
            .dispatcher = dispatcher,
            .global_options = global_options,
            .global_window_options = global_window_options,
            .response_buf = .empty,
            .render_buf = render_buf,
            .paste_buffer = null,
            .log_messages = .empty,
            .dirty = true,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.log_messages.items) |m| {
            self.allocator.free(m);
        }
        self.log_messages.deinit(self.allocator);
        if (self.paste_buffer) |pb| {
            self.allocator.free(pb);
        }
        self.render_buf.deinit(self.allocator);
        self.response_buf.deinit(self.allocator);
        self.loop.deinit(self.allocator);
        for (self.sessions.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.sessions.deinit(self.allocator);
        for (self.client_fds.items) |fd| {
            _ = c.close(fd);
        }
        self.client_fds.deinit(self.allocator);
        if (self.listener_fd) |fd| {
            socket_mod.closeSocket(fd);
        }
        var reader_it = self.client_readers.valueIterator();
        while (reader_it.next()) |r| {
            self.allocator.destroy(r.*);
        }
        self.client_readers.deinit();
        self.dispatcher.deinit();
        self.global_options.deinit();
        self.global_window_options.deinit();
    }

    pub fn shutdownServer(self: *Server) void {
        if (self.listener_fd) |fd| {
            socket_mod.closeSocket(fd);
            self.listener_fd = null;
        }
        socket_mod.shutdown();
    }

    pub fn addLogMessage(self: *Server, msg: []const u8) ServerError!void {
        const duped = try self.allocator.dupe(u8, msg);
        try self.log_messages.append(self.allocator, duped);
    }

    pub fn listen(self: *Server) ServerError!void {
        const fd = try socket_mod.createListener();
        self.listener_fd = fd;
        try self.loop.addFd(self.allocator, fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(self));
    }

    pub fn reapZombies() void {
        if (sigchldFlag.load(.seq_cst)) {
            sigchldFlag.store(false, .seq_cst);
            while (c.waitpid(-1, null, 1) > 0) {}
        }
    }

    pub fn run(self: *Server) ServerError!void {
        reapZombies();
        const events = try self.loop.pollOnce(self.allocator, 100);
        for (events) |ev| {
            if (self.handlePtyEvent(ev)) continue;

            const has_in = (ev.revents & @as(i16, @intCast(std.posix.POLL.IN))) != 0;
            const has_hup = (ev.revents & @as(i16, @intCast(std.posix.POLL.HUP))) != 0;
            const has_err = (ev.revents & @as(i16, @intCast(std.posix.POLL.ERR))) != 0;

            if (self.stdin_fd) |sfd| {
                if (ev.fd == sfd) {
                    if (has_in) {
                        self.handleStdin() catch |err| {
                            std.log.err("stdin error: {any}", .{err});
                        };
                    } else if (has_hup or has_err) {
                        self.loop.running = false;
                        self.loop.removeFd(ev.fd);
                    }
                    continue;
                }
            }

            if (self.listener_fd) |lfd| {
                if (ev.fd == lfd) {
                    if (has_in) {
                        self.handleAccept() catch |err| {
                            std.log.err("accept failed: {any}", .{err});
                        };
                    } else if (has_hup or has_err) {
                        self.loop.removeFd(ev.fd);
                    }
                    continue;
                }
            }

            var is_client = false;
            for (self.client_fds.items) |cfd| {
                if (ev.fd == cfd) {
                    is_client = true;
                    if (has_in) {
                        self.handleClient(cfd) catch |err| {
                            std.log.err("client {d} error: {any}", .{ cfd, err });
                            self.removeClient(cfd);
                        };
                    } else if (has_hup or has_err) {
                        self.removeClient(cfd);
                    }
                    break;
                }
            }
            if (is_client) continue;
        }
    }

    fn isPaneValid(self: *Server, pane: *Pane) bool {
        for (self.sessions.items) |session| {
            for (session.windows.items) |win| {
                for (win.panes.items) |p| {
                    if (p == pane) return true;
                }
            }
        }
        return false;
    }

    fn handlePtyEvent(self: *Server, ev: loop_mod.PollEvent) bool {
        if (ev.fd == self.listener_fd or ev.fd == self.stdin_fd) return false;
        for (self.client_fds.items) |cfd| {
            if (ev.fd == cfd) return false;
        }
        const pane: *Pane = @ptrCast(@alignCast(ev.udata orelse return false));
        if (!self.isPaneValid(pane)) {
            std.log.warn("handlePtyEvent: received event for invalid/stale pane pointer", .{});
            return true;
        }
        const has_in = (ev.revents & @as(i16, @intCast(std.posix.POLL.IN))) != 0;
        const has_hup = (ev.revents & @as(i16, @intCast(std.posix.POLL.HUP))) != 0;
        const has_err = (ev.revents & @as(i16, @intCast(std.posix.POLL.ERR))) != 0;

        var exited = false;
        if (has_in) {
            pane.feedPty() catch |err| {
                if (err == error.ProcessExited) {
                    std.log.info("pty process exited", .{});
                } else {
                    std.log.warn("pty feed error: {any}", .{err});
                }
                self.loop.removeFd(ev.fd);
                exited = true;
            };
        } else if (has_hup or has_err) {
            self.loop.removeFd(ev.fd);
            exited = true;
        }

        if (exited) {
            self.destroyPane(pane);
        }
        return true;
    }

    pub fn destroyPane(self: *Server, pane: *Pane) void {
        var found_session: ?*Session = null;
        var found_window: ?*Window = null;

        outer: for (self.sessions.items) |session| {
            for (session.windows.items) |win| {
                for (win.panes.items) |p| {
                    if (p == pane) {
                        found_session = session;
                        found_window = win;
                        break :outer;
                    }
                }
            }
        }

        if (found_session) |session| {
            const win = found_window.?;
            win.removePane(self.allocator, pane);

            if (win.panes.items.len == 0) {
                session.killWindow(self.allocator, win);
            }

            if (session.windows.items.len == 0) {
                self.killSession(session.name) catch {};
            }

            if (self.sessions.items.len == 0) {
                std.log.info("no sessions left, stopping server loop", .{});
                self.loop.running = false;
            } else {
                if (self.activeSession()) |s| {
                    if (s.active_window) |w| {
                        if (w.active_pane) |ap| {
                            ap.dirty = true;
                        }
                    }
                }
            }
            self.dirty = true;
        }
    }

    pub fn resolveShell(self: *Server, allocator: std.mem.Allocator, session: *Session) ServerError![]const u8 {
        _ = self;
        // 1. Check default-shell session option
        if (session.options.asString("default-shell")) |opt_shell| {
            if (opt_shell.len > 0) {
                return try allocator.dupe(u8, opt_shell);
            }
        }

        // 2. Check SHELL environment variable
        if (std.c.getenv("SHELL")) |env_shell_ptr| {
            const env_shell = std.mem.span(env_shell_ptr);
            if (env_shell.len > 0) {
                return try allocator.dupe(u8, env_shell);
            }
        }

        // 3. Query password database (getpwuid/getuid)
        if (getpwuid(getuid())) |pw| {
            const shell_span = std.mem.span(pw.pw_shell);
            if (shell_span.len > 0) {
                return try allocator.dupe(u8, shell_span);
            }
        }

        // 4. Fallback
        return try allocator.dupe(u8, "/bin/sh");
    }

    pub fn setupPane(self: *Server, session: *Session, pane: *Pane) ServerError!void {
        const shell = try self.resolveShell(self.allocator, session);
        defer self.allocator.free(shell);
        try pane.spawn(self.allocator, &[_][]const u8{shell});
        try self.watchPanePty(pane);
    }

    pub fn executeAction(self: *Server, action: @import("../key_binding.zig").Action) ServerError!void {
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;

        self.dirty = true;

        switch (action) {
            .new_window => {
                const win = try session.newWindow(self.allocator, "window");
                if (win.active_pane) |p| {
                    try self.setupPane(session, p);
                }
            },
            .split_horizontal => {
                const new_pane = try window.splitPane(self.allocator, pane, false, 0.5);
                try self.setupPane(session, new_pane);
            },
            .split_vertical => {
                const new_pane = try window.splitPane(self.allocator, pane, true, 0.5);
                try self.setupPane(session, new_pane);
            },
            .kill_pane => {
                if (window.panes.items.len > 1) {
                    window.removePane(self.allocator, pane);
                }
            },
            .next_window => {
                if (session.windows.items.len > 1) {
                    for (session.windows.items, 0..) |w, idx| {
                        if (w == window) {
                            const next = (idx + 1) % session.windows.items.len;
                            session.setActiveWindow(session.windows.items[next]);
                            break;
                        }
                    }
                }
            },
            .prev_window => {
                if (session.windows.items.len > 1) {
                    for (session.windows.items, 0..) |w, idx| {
                        if (w == window) {
                            const prev = if (idx == 0) session.windows.items.len - 1 else idx - 1;
                            session.setActiveWindow(session.windows.items[prev]);
                            break;
                        }
                    }
                }
            },
            .last_window => {
                if (session.last_window) |lw| {
                    session.setActiveWindow(lw);
                } else if (session.windows.items.len > 1) {
                    for (session.windows.items) |w| {
                        if (w != window) {
                            session.setActiveWindow(w);
                            break;
                        }
                    }
                }
            },
            .rotate_window => {
                if (window.panes.items.len > 1) {
                    const first = window.panes.items[0];
                    for (0..window.panes.items.len - 1) |i| {
                        window.panes.items[i] = window.panes.items[i + 1];
                    }
                    window.panes.items[window.panes.items.len - 1] = first;
                }
            },
            .select_pane_left => {
                if (window.panes.items.len > 1) {
                    if (try self.findDirectionalNeighbor(window, pane, .left)) |neighbor| {
                        window.setActivePane(neighbor);
                    }
                }
            },
            .select_pane_right => {
                if (window.panes.items.len > 1) {
                    if (try self.findDirectionalNeighbor(window, pane, .right)) |neighbor| {
                        window.setActivePane(neighbor);
                    }
                }
            },
            .select_pane_up => {
                if (window.panes.items.len > 1) {
                    if (try self.findDirectionalNeighbor(window, pane, .up)) |neighbor| {
                        window.setActivePane(neighbor);
                    }
                }
            },
            .select_pane_down => {
                if (window.panes.items.len > 1) {
                    if (try self.findDirectionalNeighbor(window, pane, .down)) |neighbor| {
                        window.setActivePane(neighbor);
                    }
                }
            },
            .detach => {
                if (self.display_client_fd) |cfd| {
                    const detach_pkt = protocol.Packet.make(.detach, "");
                    var buf: [128]u8 = undefined;
                    const ser = detach_pkt.serialize(&buf);
                    _ = c.write(cfd, ser.ptr, ser.len);
                    self.display_client_fd = null;
                } else {
                    self.loop.running = false;
                }
            },
            .select_window_0, .select_window_1, .select_window_2, .select_window_3, .select_window_4, .select_window_5, .select_window_6, .select_window_7, .select_window_8, .select_window_9 => {
                const idx = @intFromEnum(action) - @intFromEnum(@import("../key_binding.zig").Action.select_window_0);
                if (idx < session.windows.items.len) {
                    session.setActiveWindow(session.windows.items[idx]);
                }
            },
            .copy_mode => {
                pane.screen.copy_mode = @import("../mode_copy.zig").CopyMode.init(.vi);
                pane.screen.copy_mode.?.enter(&pane.screen.grid);
            },
            .paste_buffer => {
                if (self.paste_buffer) |pb| {
                    try pane.writeStr(pb);
                }
            },
            .swap_pane_up => {
                if (window.panes.items.len > 1) {
                    const active_idx = for (window.panes.items, 0..) |p, idx| {
                        if (p == pane) break idx;
                    } else return;
                    const dest_idx = if (active_idx == 0) window.panes.items.len - 1 else active_idx - 1;
                    const dest_pane = window.panes.items[dest_idx];

                    const node1 = window.layout.findLeafParent(window.layout.root, pane) orelse return;
                    const node2 = window.layout.findLeafParent(window.layout.root, dest_pane) orelse return;
                    node1.leaf = dest_pane;
                    node2.leaf = pane;

                    window.panes.items[active_idx] = dest_pane;
                    window.panes.items[dest_idx] = pane;
                }
            },
            .swap_pane_down => {
                if (window.panes.items.len > 1) {
                    const active_idx = for (window.panes.items, 0..) |p, idx| {
                        if (p == pane) break idx;
                    } else return;
                    const dest_idx = (active_idx + 1) % window.panes.items.len;
                    const dest_pane = window.panes.items[dest_idx];

                    const node1 = window.layout.findLeafParent(window.layout.root, pane) orelse return;
                    const node2 = window.layout.findLeafParent(window.layout.root, dest_pane) orelse return;
                    node1.leaf = dest_pane;
                    node2.leaf = pane;

                    window.panes.items[active_idx] = dest_pane;
                    window.panes.items[dest_idx] = pane;
                }
            },
            .resize_left => {
                const current_w = pane.screen.grid.width;
                const current_h = pane.screen.grid.height;
                const target_w = @as(u32, @intCast(@max(1, @as(i32, @intCast(current_w)) - 1)));
                pane.resizeTerminal(target_w, current_h) catch {};
            },
            .resize_right => {
                const current_w = pane.screen.grid.width;
                const current_h = pane.screen.grid.height;
                const target_w = current_w + 1;
                pane.resizeTerminal(target_w, current_h) catch {};
            },
            .resize_up => {
                const current_w = pane.screen.grid.width;
                const current_h = pane.screen.grid.height;
                const target_h = @as(u32, @intCast(@max(1, @as(i32, @intCast(current_h)) - 1)));
                pane.resizeTerminal(current_w, target_h) catch {};
            },
            .resize_down => {
                const current_w = pane.screen.grid.width;
                const current_h = pane.screen.grid.height;
                const target_h = current_h + 1;
                pane.resizeTerminal(current_w, target_h) catch {};
            },
            else => {},
        }

        if (session.active_window) |w| {
            if (w.active_pane) |ap| {
                ap.dirty = true;
            }
        }
    }

    fn handleStdin(self: *Server) ServerError!void {
        var buf: [4096]u8 = undefined;
        const n = c.read(std.c.STDIN_FILENO, &buf, buf.len);
        if (n <= 0) {
            self.loop.running = false;
            return;
        }
        try self.processInput(buf[0..@as(usize, @intCast(n))]);
    }

    pub fn processInput(self: *Server, buf: []const u8) ServerError!void {
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        const pty = &(pane.pty orelse return);

        var i: usize = 0;
        var esc_buf: std.ArrayList(u8) = .empty;
        defer esc_buf.deinit(self.allocator);

        while (i < buf.len) : (i += 1) {
            const byte = buf[i];

            if (pane.screen.copy_mode) |*cm| {
                if (self.input_reader.feed(byte)) |event| {
                    switch (event) {
                        .key => |k| {
                            if (self.dispatcher.prefix_state == .normal) {
                                if (@import("../key_binding.zig").keysEqual(k, self.dispatcher.prefix)) {
                                    self.dispatcher.prefix_state = .prefix_seen;
                                } else {
                                    var is_yank = false;
                                    if (k == .char and k.char.code == 'y' and !k.char.mod.ctrl and !k.char.mod.alt) {
                                        is_yank = true;
                                    } else if (k == .special and k.special.key == .enter) {
                                        is_yank = true;
                                    }

                                    if (is_yank and cm.selection.active) {
                                        if (self.paste_buffer) |pb| {
                                            self.allocator.free(pb);
                                        }
                                        self.paste_buffer = cm.yankSelection(self.allocator, &pane.screen.grid) catch null;
                                        pane.screen.copy_mode = null;
                                        pane.dirty = true;
                                    } else {
                                        const res = cm.handleKey(k, &pane.screen.grid);
                                        switch (res) {
                                            .consumed => {
                                                pane.dirty = true;
                                            },
                                            .exit_mode => {
                                                pane.screen.copy_mode = null;
                                                pane.dirty = true;
                                            },
                                            .ignored => {},
                                        }
                                    }
                                }
                            } else {
                                self.dispatcher.prefix_state = .normal;
                                if (self.dispatcher.prefix_table.lookup(k)) |action| {
                                    self.executeAction(action) catch {};
                                }
                            }
                        },
                        .mouse => |m| {
                            const mouse_opt = session.options.asFlag("mouse") orelse false;
                            if (mouse_opt) {
                                if (m.button == .left) {
                                    self.handleMouseFocus(m.x, m.y) catch {};
                                } else if (m.button == .scroll_up) {
                                    cm.scroll_offset = @min(cm.scroll_offset + 3, @as(u32, @intCast(pane.screen.grid.history.items.len)));
                                    pane.dirty = true;
                                } else if (m.button == .scroll_down) {
                                    if (cm.scroll_offset == 0) {
                                        pane.screen.copy_mode = null;
                                    } else {
                                        cm.scroll_offset = cm.scroll_offset -| 3;
                                    }
                                    pane.dirty = true;
                                }
                            }
                        },
                        else => {},
                    }
                }
            } else {
                if (self.input_reader.state != .ground or byte == 0x1b or byte < 0x20) {
                    if (esc_buf.items.len >= 1024) {
                        std.log.warn("processInput: esc_buf exceeded limit, resetting input reader", .{});
                        esc_buf.clearRetainingCapacity();
                        self.input_reader.state = .ground;
                    } else {
                        try esc_buf.append(self.allocator, byte);
                    }
                    if (self.input_reader.feed(byte)) |event| {
                        var handled = false;
                        switch (event) {
                            .key => |k| {
                                // Diagnostic logging of parsed keys
                                if (comptime @import("builtin").mode == .Debug) {
                                    var key_name_buf: [64]u8 = undefined;
                                    const key_str = @import("../key.zig").format(k, &key_name_buf);
                                    var log_msg_buf: [128]u8 = undefined;
                                    const log_msg = std.fmt.bufPrint(&log_msg_buf, "key (esc): {s} [prefix: {s}]", .{ key_str, @tagName(self.dispatcher.prefix_state) }) catch "log err";
                                    self.addLogMessage(log_msg) catch {};
                                }

                                if (self.dispatcher.prefix_state == .normal) {
                                    if (@import("../key_binding.zig").keysEqual(k, self.dispatcher.prefix)) {
                                        self.dispatcher.prefix_state = .prefix_seen;
                                        handled = true;
                                    }
                                } else {
                                    self.dispatcher.prefix_state = .normal;
                                    if (self.dispatcher.prefix_table.lookup(k)) |action| {
                                        self.executeAction(action) catch {};
                                    }
                                    handled = true;
                                }
                            },
                            .mouse => |m| {
                                const mouse_opt = session.options.asFlag("mouse") orelse false;
                                if (mouse_opt) {
                                    if (m.button == .left) {
                                        self.handleMouseFocus(m.x, m.y) catch {};
                                        handled = true;
                                    }
                                    const wants_mouse = pane.screen.mode.mouse_standard or
                                        pane.screen.mode.mouse_button or
                                        pane.screen.mode.mouse_sgr;
                                    if (!wants_mouse) {
                                        handled = true;
                                        if (m.button == .scroll_up) {
                                            pane.screen.copy_mode = @import("../mode_copy.zig").CopyMode.init(.vi);
                                            pane.screen.copy_mode.?.enter(&pane.screen.grid);
                                            pane.screen.copy_mode.?.scroll_offset = @min(3, @as(u32, @intCast(pane.screen.grid.history.items.len)));
                                            pane.dirty = true;
                                        }
                                    }
                                } else {
                                    handled = true;
                                }
                            },
                            else => {},
                        }

                        if (!handled) {
                            pty.writeInput(esc_buf.items) catch {};
                        }
                        esc_buf.clearRetainingCapacity();
                    } else if (self.input_reader.state == .ground) {
                        pty.writeInput(esc_buf.items) catch {};
                        esc_buf.clearRetainingCapacity();
                    }
                } else {
                    if (self.dispatcher.prefix_state == .normal) {
                        pty.writeInput(&[_]u8{byte}) catch {};
                    } else {
                        if (self.input_reader.feed(byte)) |event| {
                            self.dispatcher.prefix_state = .normal;
                            switch (event) {
                                .key => |k| {
                                    // Diagnostic logging of parsed keys
                                    if (comptime @import("builtin").mode == .Debug) {
                                        var key_name_buf: [64]u8 = undefined;
                                        const key_str = @import("../key.zig").format(k, &key_name_buf);
                                        var log_msg_buf: [128]u8 = undefined;
                                        const log_msg = std.fmt.bufPrint(&log_msg_buf, "key (ground): {s} [prefix: prefix_seen]", .{key_str}) catch "log err";
                                        self.addLogMessage(log_msg) catch {};
                                    }

                                    if (self.dispatcher.prefix_table.lookup(k)) |action| {
                                        self.executeAction(action) catch {};
                                    }
                                },
                                .mouse => |m| {
                                    const mouse_opt = session.options.asFlag("mouse") orelse false;
                                    if (mouse_opt and m.button == .left) {
                                        self.handleMouseFocus(m.x, m.y) catch {};
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn handleMouseFocus(self: *Server, x: u32, y: u32) ServerError!void {
        const session = self.activeSession() orelse return;

        if (y == session.height) {
            var col: u32 = 0;
            const prefix_len = 3 + @as(u32, @intCast(session.name.len));
            col += prefix_len;

            for (session.windows.items, 0..) |win, idx| {
                const is_active = (win == session.active_window);
                const suffix_len: u32 = if (is_active) 1 else 0;

                var idx_buf: [16]u8 = undefined;
                const idx_len = (std.fmt.bufPrint(&idx_buf, "{}", .{idx}) catch unreachable).len;
                const entry_len = 1 + @as(u32, @intCast(idx_len)) + 1 + @as(u32, @intCast(win.name.len)) + suffix_len;

                const start_x = col;
                const end_x = col + entry_len;

                if (x >= start_x and x < end_x) {
                    session.setActiveWindow(win);
                    if (win.active_pane) |pane| {
                        pane.dirty = true;
                    }
                    self.dirty = true;
                    return;
                }
                col += entry_len;
            }
            return;
        }

        const window = session.active_window orelse return;
        const layout = &window.layout;
        const found_pane = self.findPaneAtNode(layout.root, x, y, 0, 0, layout.width, layout.height) orelse return;
        // Safety: ensure the pane is still valid (not destroyed during handling)
        var pane_valid = false;
        for (window.panes.items) |p| {
            if (p == found_pane) {
                pane_valid = true;
                break;
            }
        }
        if (!pane_valid) return;
        const prev_active = window.active_pane;
        window.setActivePane(found_pane);
        if (prev_active != found_pane) {
            if (prev_active) |prev| prev.dirty = true;
            found_pane.dirty = true;
            self.dirty = true;
        }
    }

    fn collectPaneBounds(self: *Server, node: *const @import("../layout.zig").Node, lx: u32, ly: u32, lw: u32, lh: u32, result: *std.ArrayList(render.PaneBounds)) ServerError!void {
        switch (node.*) {
            .leaf => |pane| {
                try result.append(self.allocator, .{ .pane = pane, .x = lx, .y = ly, .w = lw, .h = lh });
            },
            .split => |s| {
                if (s.direction == .horizontal) {
                    const split_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lw)) * s.proportion)));
                    try self.collectPaneBounds(s.a, lx, ly, split_w -| 1, lh, result);
                    try self.collectPaneBounds(s.b, lx + split_w, ly, lw -| split_w, lh, result);
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    try self.collectPaneBounds(s.a, lx, ly, lw, split_h -| 1, result);
                    try self.collectPaneBounds(s.b, lx, ly + split_h, lw, lh -| split_h, result);
                }
            },
        }
    }

    fn findDirectionalNeighbor(self: *Server, window: *Window, current: *Pane, direction: enum { left, right, up, down }) ServerError!?*Pane {
        var bounds: std.ArrayList(render.PaneBounds) = .empty;
        defer bounds.deinit(self.allocator);

        try self.collectPaneBounds(window.layout.root, 0, 0, window.layout.width, window.layout.height, &bounds);

        var cur_x: u32 = 0;
        var cur_y: u32 = 0;
        var cur_w: u32 = 0;
        var cur_h: u32 = 0;
        for (bounds.items) |b| {
            if (b.pane == current) {
                cur_x = b.x;
                cur_y = b.y;
                cur_w = b.w;
                cur_h = b.h;
                break;
            }
        }

        var best: ?*Pane = null;
        var best_dist: u32 = std.math.maxInt(u32);
        var best_overlap: u32 = 0;

        for (bounds.items) |b| {
            if (b.pane == current) continue;

            switch (direction) {
                .left => {
                    if (b.x + b.w <= cur_x) {
                        const dist = cur_x -| (b.x + b.w);
                        const overlap = @min(cur_y + cur_h, b.y + b.h) -| @max(cur_y, b.y);
                        if (dist < best_dist or (dist == best_dist and overlap > best_overlap)) {
                            best = b.pane;
                            best_dist = dist;
                            best_overlap = overlap;
                        }
                    }
                },
                .right => {
                    if (b.x >= cur_x + cur_w) {
                        const dist = b.x -| (cur_x + cur_w);
                        const overlap = @min(cur_y + cur_h, b.y + b.h) -| @max(cur_y, b.y);
                        if (dist < best_dist or (dist == best_dist and overlap > best_overlap)) {
                            best = b.pane;
                            best_dist = dist;
                            best_overlap = overlap;
                        }
                    }
                },
                .up => {
                    if (b.y + b.h <= cur_y) {
                        const dist = cur_y -| (b.y + b.h);
                        const overlap = @min(cur_x + cur_w, b.x + b.w) -| @max(cur_x, b.x);
                        if (dist < best_dist or (dist == best_dist and overlap > best_overlap)) {
                            best = b.pane;
                            best_dist = dist;
                            best_overlap = overlap;
                        }
                    }
                },
                .down => {
                    if (b.y >= cur_y + cur_h) {
                        const dist = b.y -| (cur_y + cur_h);
                        const overlap = @min(cur_x + cur_w, b.x + b.w) -| @max(cur_x, b.x);
                        if (dist < best_dist or (dist == best_dist and overlap > best_overlap)) {
                            best = b.pane;
                            best_dist = dist;
                            best_overlap = overlap;
                        }
                    }
                },
            }
        }

        return best;
    }

    fn findPaneAtNode(self: *Server, node: *const @import("../layout.zig").Node, x: u32, y: u32, lx: u32, ly: u32, lw: u32, lh: u32) ?*Pane {
        switch (node.*) {
            .leaf => |pane| {
                if (x >= lx and x < lx + lw and y >= ly and y < ly + lh) {
                    return pane;
                }
                return null;
            },
            .split => |s| {
                if (s.direction == .horizontal) {
                    const split_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lw)) * s.proportion)));
                    if (x < lx + split_w) {
                        return self.findPaneAtNode(s.a, x, y, lx, ly, split_w, lh);
                    } else {
                        return self.findPaneAtNode(s.b, x, y, lx + split_w, ly, lw - split_w, lh);
                    }
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    if (y < ly + split_h) {
                        return self.findPaneAtNode(s.a, x, y, lx, ly, lw, split_h);
                    } else {
                        return self.findPaneAtNode(s.b, x, y, lx, ly + split_h, lw, lh - split_h);
                    }
                }
            },
        }
    }

    pub fn watchPanePty(self: *Server, pane: *Pane) ServerError!void {
        const pty = pane.pty orelse return;
        try self.loop.addFd(self.allocator, pty.master, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(pane));
    }

    fn handleAccept(self: *Server) ServerError!void {
        const fd = try socket_mod.acceptClient(self.listener_fd.?);
        try self.client_fds.append(self.allocator, fd);
        const reader = try self.allocator.create(MessageReader);
        reader.* = .{};
        try self.client_readers.put(fd, reader);
        try self.loop.addFd(self.allocator, fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(self));
    }

    fn handleClient(self: *Server, fd: i32) ServerError!void {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| {
            std.log.err("read from client fd {d} failed: {s}", .{ fd, @errorName(err) });
            return error.ReadFailed;
        };
        if (n == 0) {
            return error.ConnectionClosed;
        }

        const reader = self.client_readers.get(fd) orelse return;
        try reader.feed(buf[0..n]);

        while (try reader.tryParse()) |pkt| {
            defer reader.consume(pkt);
            const msg_type = @as(protocol.MessageType, @enumFromInt(pkt.header.msg_type));
            switch (msg_type) {
                .command => {
                    const dispatch = @import("dispatch.zig");
                    var result = dispatch.dispatchCommand(self.allocator, self, pkt.data);
                    self.dirty = true;
                    defer result.deinit();
                    try dispatch.sendResponse(fd, &result);
                },
                .identify_term => {
                    self.display_client_fd = fd;
                    const reply = protocol.Packet.make(.ready, "ok");
                    var reply_buf: [128]u8 = undefined;
                    const serialized = reply.serialize(&reply_buf);
                    const written = c.write(fd, serialized.ptr, serialized.len);
                    if (written < 0) {
                        return error.WriteFailed;
                    }
                    if (self.activeSession()) |s| {
                        if (s.active_window) |w| {
                            if (w.active_pane) |ap| {
                                ap.dirty = true;
                            }
                        }
                    }
                },
                .stdin_data => {
                    self.processInput(pkt.data) catch |err| {
                        std.log.err("stdin processing error: {any}", .{err});
                    };
                },
                .resize => {
                    if (pkt.data.len >= 8) {
                        const new_w = std.mem.readInt(u32, pkt.data[0..4], .little);
                        const new_h = std.mem.readInt(u32, pkt.data[4..8], .little);
                        self.display_sx = @max(new_w, 80);
                        self.display_sy = @max(new_h, 24);
                        if (self.activeSession()) |s| {
                            s.resize(self.display_sx, self.display_sy - 1) catch {};
                        }
                    }
                },
                .detach => {
                    self.display_client_fd = null;
                },
                else => {},
            }
        }
    }

    fn removeClient(self: *Server, fd: i32) void {
        self.loop.removeFd(fd);
        for (self.client_fds.items, 0..) |cfd, i| {
            if (cfd == fd) {
                _ = self.client_fds.swapRemove(i);
                break;
            }
        }
        if (self.client_readers.fetchRemove(fd)) |entry| {
            self.allocator.destroy(entry.value);
        }
        _ = c.close(fd);
        if (self.display_client_fd == fd) {
            self.display_client_fd = null;
        }
    }

    pub fn renderToDisplayClient(self: *Server) void {
        const display_fd = self.display_client_fd orelse return;
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;

        // Perform automatic window renaming
        for (session.windows.items) |win| {
            if (win.automatic_rename) {
                if (win.active_pane) |ap| {
                    if (ap.pty) |pty| {
                        var proc_buf: [128]u8 = undefined;
                        if (pty.getForegroundProcessName(&proc_buf)) |proc_name_val| {
                            if (proc_name_val.len > 0 and !std.mem.eql(u8, win.name, proc_name_val)) {
                                if (win.allocator.dupe(u8, proc_name_val)) |new_name| {
                                    win.name = new_name;
                                    ap.dirty = true;
                                    self.dirty = true;
                                } else |_| {}
                            }
                        } else |_| {}
                    }
                }
            }
        }

        var any_dirty = self.dirty;
        if (!any_dirty) {
            for (window.panes.items) |p| {
                if (p.dirty) {
                    any_dirty = true;
                    break;
                }
            }
        }
        if (!any_dirty) return;

        self.dirty = false;
        for (window.panes.items) |p| {
            p.dirty = false;
        }

        self.render_buf.clearRetainingCapacity();

        var display = Display{
            .fd = display_fd,
            .sx = self.display_sx,
            .sy = self.display_sy,
            .capture = &self.render_buf,
            .capture_allocator = self.allocator,
        };

        var bounds: std.ArrayList(render.PaneBounds) = .empty;
        defer bounds.deinit(self.allocator);
        self.collectPaneBounds(window.layout.root, 0, 0, self.display_sx, self.display_sy - 1, &bounds) catch |err| {
            std.log.warn("collectPaneBounds error: {any}", .{err});
            return;
        };

        display.renderAll(
            self.allocator,
            bounds.items,
            pane,
            session.name,
            session.windows.items,
            session.active_window,
            window.layout.root,
        ) catch |err| {
            std.log.warn("render error: {any}", .{err});
            return;
        };

        if (self.render_buf.items.len > 0) {
            const pkt = protocol.Packet.make(.output, self.render_buf.items);
            var hdr: [5]u8 = undefined;
            pkt.header.encode(&hdr);
            _ = c.write(display_fd, &hdr, 5);
            _ = c.write(display_fd, self.render_buf.items.ptr, self.render_buf.items.len);
        }
    }

    pub fn newSession(self: *Server, name: []const u8, width: u32, height: u32) ServerError!*Session {
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        try session.init(self.allocator, self.next_session_id, name, width, height, &self.global_options, &self.global_window_options);
        self.next_session_id += 1;
        try self.sessions.append(self.allocator, session);
        self.dirty = true;
        return session;
    }

    pub fn killSession(self: *Server, name: []const u8) ServerError!void {
        const idx = for (self.sessions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) break i;
        } else return error.SessionNotFound;
        var session = self.sessions.swapRemove(idx);
        session.deinit(self.allocator);
        self.allocator.destroy(session);
        self.dirty = true;
    }

    pub fn killAllSessions(self: *Server) void {
        for (self.sessions.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.sessions.clearRetainingCapacity();
    }

    pub fn activeSession(self: *Server) ?*Session {
        return if (self.sessions.items.len > 0) self.sessions.items[0] else null;
    }

    pub fn getSession(self: *Server, name: []const u8) ?*Session {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn applyDirectives(self: *Server, parsed: *const @import("../cfg.zig").ParseResult) ServerError!void {
        const key_binding = @import("../key_binding.zig");
        for (parsed.directives.items) |d| {
            switch (d) {
                .set => |s| {
                    self.global_options.set(s.option, s.value) catch |err| {
                        if (err == error.UnknownOption) {
                            self.global_window_options.set(s.option, s.value) catch |err2| {
                                if (err2 == error.UnknownOption) {
                                    std.log.warn("unknown option: {s}", .{s.option});
                                } else {
                                    return err2;
                                }
                            };
                        } else {
                            return err;
                        }
                    };
                    if (std.mem.eql(u8, s.option, "prefix")) {
                        if (s.value == .key) {
                            self.dispatcher.prefix = s.value.key;
                        }
                    }
                },
                .bind_key => |b| {
                    const action = key_binding.mapCommandToAction(b.command) orelse continue;
                    const table = if (b.flags.key_table) |kt| blk: {
                        if (std.mem.eql(u8, kt, "root")) {
                            break :blk &self.dispatcher.root_table;
                        } else {
                            break :blk &self.dispatcher.prefix_table;
                        }
                    } else &self.dispatcher.prefix_table;
                    try table.bind(b.key, action);
                },
                .unbind_key => |u| {
                    const table = if (u.flags.key_table) |kt| blk: {
                        if (std.mem.eql(u8, kt, "root")) {
                            break :blk &self.dispatcher.root_table;
                        } else {
                            break :blk &self.dispatcher.prefix_table;
                        }
                    } else &self.dispatcher.prefix_table;
                    table.unbind(u.key);
                },
                .set_environment => {
                    std.log.debug("set_environment: TODO", .{});
                },
                .source_file => |path| {
                    try self.loadConfigFile(path);
                },
                .if_shell => {
                    std.log.debug("if_shell: TODO", .{});
                },
            }
        }
    }

    pub fn loadConfigFile(self: *Server, path: []const u8) ServerError!void {
        var resolved_path: []const u8 = path;
        var free_path = false;
        if (std.mem.startsWith(u8, path, "~/")) {
            if (std.c.getenv("HOME")) |home_ptr| {
                const home = std.mem.span(home_ptr);
                resolved_path = try std.fs.path.join(self.allocator, &[_][]const u8{ home, path[2..] });
                free_path = true;
            }
        }
        defer if (free_path) self.allocator.free(resolved_path);

        const resolved_path_z = try self.allocator.dupeZ(u8, resolved_path);
        defer self.allocator.free(resolved_path_z);

        const f = fopen(resolved_path_z.ptr, "r") orelse return;
        defer _ = fclose(f);

        _ = fseek(f, 0, 2); // SEEK_END = 2
        const size = ftell(f);
        if (size < 0) return error.ReadFailed;
        _ = fseek(f, 0, 0); // SEEK_SET = 0

        const content = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(content);

        const read_bytes = fread(content.ptr, 1, content.len, f);
        if (read_bytes == 0 and content.len > 0) return error.ReadFailed;

        const cfg_mod = @import("../cfg.zig");
        var parsed = try cfg_mod.parseConfig(self.allocator, content[0..read_bytes]);
        defer parsed.deinit(self.allocator);

        try self.applyDirectives(&parsed);
    }

    pub fn loadDefaultConfig(self: *Server) ServerError!void {
        if (std.c.getenv("HOME")) |home_ptr| {
            const home = std.mem.span(home_ptr);

            const config_paths = &[_][]const u8{
                ".config/szn/szn.conf",
                ".szn.conf",
                ".config/tmux/tmux.conf",
                ".tmux.conf",
            };

            for (config_paths) |sub_path| {
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ home, sub_path });
                defer self.allocator.free(path);

                const path_z = try self.allocator.dupeZ(u8, path);
                defer self.allocator.free(path_z);

                if (access(path_z.ptr, 0) == 0) {
                    try self.loadConfigFile(path);
                    return;
                }
            }
        }
    }
};

pub const ServerError = session_mod.Error || window_mod.Error || render.Error || loop_mod.Error || pty_mod.Error || protocol.Error || socket_mod.Error || cfg.Error || options.Error || key_binding_mod.Error || message_reader.ReadError || error{ SessionNotFound, OutOfMemory };

test "create empty server" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "new session creates session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s = try server.newSession("test", 80, 24);
    try testing.expectEqualStrings("test", s.name);
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "kill session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("one", 80, 24);
    _ = try server.newSession("two", 80, 24);
    try testing.expectEqual(@as(usize, 2), server.sessions.items.len);
    try server.killSession("one");
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
    try testing.expectEqualStrings("two", server.sessions.items[0].name);
}

test "kill unknown session returns error" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expectError(error.SessionNotFound, server.killSession("nonexistent"));
}

test "active session returns first session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expect(server.activeSession() == null);
    _ = try server.newSession("first", 80, 24);
    const s = try server.newSession("second", 80, 24);
    _ = s;
    try testing.expectEqualStrings("first", server.activeSession().?.name);
}

test "get session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("alpha", 80, 24);
    _ = try server.newSession("beta", 80, 24);
    try testing.expect(server.getSession("alpha") != null);
    try testing.expect(server.getSession("beta") != null);
    try testing.expect(server.getSession("gamma") == null);
}

test "kill all sessions" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("a", 80, 24);
    _ = try server.newSession("b", 80, 24);
    _ = try server.newSession("c", 80, 24);
    try testing.expectEqual(@as(usize, 3), server.sessions.items.len);
    server.killAllSessions();
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "session windows have correct size" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s = try server.newSession("test", 80, 24);
    try testing.expectEqual(@as(u32, 80), s.windows.items[0].width);
    try testing.expectEqual(@as(u32, 24), s.windows.items[0].height);
}

test "new session increments id" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s1 = try server.newSession("a", 80, 24);
    const s2 = try server.newSession("b", 80, 24);
    try testing.expect(s1.id < s2.id);
}

test "server listen creates socket" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try server.listen();
    try testing.expect(server.listener_fd != null);
}

test "prefix interception and key dispatching" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;

    // Set up a mock pty so we don't try to spawn process/terminal in test.
    pane.pty = try @import("pty.zig").Pty.open();

    // Verify initial dispatcher state is normal.
    try testing.expectEqual(@import("../key_binding.zig").PrefixState.normal, server.dispatcher.prefix_state);

    // Feed Ctrl-B (0x02) - should change state to prefix_seen.
    try server.processInput(&[_]u8{0x02});
    try testing.expectEqual(@import("../key_binding.zig").PrefixState.prefix_seen, server.dispatcher.prefix_state);

    // Feed 'c' - should execute new-window action, returning state to normal, and creating a second window.
    try server.processInput("c");
    try testing.expectEqual(@import("../key_binding.zig").PrefixState.normal, server.dispatcher.prefix_state);
    try testing.expectEqual(@as(usize, 2), s.windows.items.len);

    const active_win = s.active_window.?;
    const active_pane = active_win.active_pane.?;
    active_pane.pty = try @import("pty.zig").Pty.open();

    // Test copy-mode activation
    try testing.expect(active_pane.screen.copy_mode == null);
    try server.processInput(&[_]u8{ 0x02, '[' }); // Ctrl-b + [
    try testing.expect(active_pane.screen.copy_mode != null);

    // Exit copy mode by sending 'q'
    try server.processInput("q");
    try testing.expect(active_pane.screen.copy_mode == null);

    // Test paste-buffer
    server.paste_buffer = try server.allocator.dupe(u8, "pasted-content");
    try server.processInput(&[_]u8{ 0x02, ']' }); // Ctrl-b + ]

    // Check that grid has the pasted content
    var line_buf: [14]u8 = undefined;
    var line_idx: usize = 0;
    const line = active_pane.screen.grid.lines.items[0];
    for (line.cells.items[0..14]) |cell| {
        line_buf[line_idx] = @as(u8, @intCast(cell.char));
        line_idx += 1;
    }
    try testing.expectEqualStrings("pasted-content", line_buf[0..line_idx]);

    // Manually split the pane to test swap and resize without spawning a real shell
    const new_pane = try active_win.splitPane(server.allocator, active_pane, false, 0.5);
    new_pane.pty = try @import("pty.zig").Pty.open();
    try testing.expectEqual(@as(usize, 2), active_win.panes.items.len);

    const original_first_pane = active_win.panes.items[0];
    const original_second_pane = active_win.panes.items[1];

    // Test swap_pane_down
    try server.executeAction(.swap_pane_down);
    try testing.expect(active_win.panes.items[0] == original_second_pane);
    try testing.expect(active_win.panes.items[1] == original_first_pane);

    // Test resize_right
    const old_width = original_second_pane.screen.grid.width;
    try server.executeAction(.resize_right);
    try testing.expectEqual(old_width + 1, original_second_pane.screen.grid.width);
}

test "resolve shell option and env and database" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const shell = try server.resolveShell(testing.allocator, s);
    defer testing.allocator.free(shell);
    try testing.expect(shell.len > 0);
    try testing.expect(shell[0] == '/');
}

test "mouse event filtering based on mouse_opt" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;
    pane.pty = try @import("pty.zig").Pty.open();

    const fd = pane.pty.?.slave;
    // Set non-blocking mode on slave PTY so we can read immediately without newline.
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 0x0004;

    const flags = c_fcntl(fd, F_GETFL, @as(c_int, 0));
    _ = c_fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    // 1. By default, mouse_opt is false. Feed mouse SGR sequence.
    try server.processInput("\x1b[<65;10;5M");
    // Feed a newline to flush the canonical mode buffer.
    try server.processInput("\n");

    // Verify it was NOT forwarded to the PTY (should only contain the newline).
    var buf: [128]u8 = undefined;
    var n = std.posix.read(fd, &buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expect(n > 0);
    try testing.expectEqualStrings("\n", buf[0..n]);

    // 2. Enable mouse option at session level.
    try s.options.set("mouse", .{ .flag = true });

    // Enable mouse reporting inside pane mode so it wants mouse
    pane.screen.mode.mouse_sgr = true;

    // Feed scroll wheel mouse SGR sequence again.
    try server.processInput("\x1b[<64;10;5M");
    // Feed a newline to flush the canonical mode buffer.
    try server.processInput("\n");

    // Verify it WAS forwarded (contains both the mouse sequence and the newline).
    n = std.posix.read(fd, &buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expect(n > 0);
    try testing.expectEqualStrings("\x1b[<64;10;5M\n", buf[0..n]);
}

test "destroyPane cleans up pane, window, and session correctly" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;

    // Destroy the only pane in the only window of the only session
    server.destroyPane(pane);

    // This should have cascaded and killed the window, then the session
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "handlePtyEvent ignores event with stale pane pointer" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var dummy_pane = try Pane.init(testing.allocator, 999, 80, 24);
    defer dummy_pane.deinit();

    const ev = @import("loop.zig").PollEvent{
        .fd = 999,
        .revents = @as(i16, @intCast(std.posix.POLL.IN)),
        .udata = @ptrCast(&dummy_pane),
    };

    const handled = server.handlePtyEvent(ev);
    try testing.expect(handled);
}

test "processInput esc_buf capacity limit" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;
    pane.pty = try @import("pty.zig").Pty.open();

    // Send a long escape sequence prefix (0x1b followed by more than 1024 bytes)
    var big_esc: [1026]u8 = undefined;
    big_esc[0] = 0x1b;
    @memset(big_esc[1..], '1');

    try server.processInput(&big_esc);

    // It should reset input reader state to .ground due to limit trigger.
    try testing.expectEqual(.ground, server.input_reader.state);
}




