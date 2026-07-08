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
const Colour = @import("../colour.zig").Colour;
const buffer_mod = @import("../buffer.zig");

extern "c" fn fopen(filename: [*c]const u8, modes: [*c]const u8) ?*anyopaque;
extern "c" fn fclose(stream: ?*anyopaque) c_int;
extern "c" fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: ?*anyopaque) c_long;
extern "c" fn fread(ptr: ?*anyopaque, size: usize, n: usize, stream: ?*anyopaque) usize;
extern "c" fn access(pathname: [*c]const u8, mode: c_int) c_int;
extern "c" fn gettimeofday(tv: *std.c.timeval, tz: ?*anyopaque) c_int;
extern "c" fn time(t: ?*i64) i64;

const passwd = if (@import("builtin").os.tag.isDarwin())
    extern struct {
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
    }
else
    extern struct {
        pw_name: [*:0]const u8,
        pw_passwd: [*:0]const u8,
        pw_uid: c.uid_t,
        pw_gid: c.gid_t,
        pw_gecos: [*:0]const u8,
        pw_dir: [*:0]const u8,
        pw_shell: [*:0]const u8,
    };

extern "c" fn getuid() c.uid_t;
extern "c" fn getpwuid(uid: c.uid_t) ?*const passwd;

pub const DisplayClient = struct {
    fd: i32,
    sx: u32 = 80,
    sy: u32 = 24,
    last_cells: std.ArrayList(@import("../grid.zig").Cell) = .empty,
    last_sx: u32 = 0,
    last_sy: u32 = 0,
    merged_screen: ?@import("../screen.zig").Screen = null,
    last_paste: ?bool = null,

    pub fn deinit(self: *DisplayClient, allocator: std.mem.Allocator) void {
        self.last_cells.deinit(allocator);
        if (self.merged_screen) |*ms| {
            ms.deinit();
        }
    }
};

pub const Server = struct {
    pub const MAX_PASTE_SIZE = 16384;

    allocator: std.mem.Allocator,
    sessions: std.ArrayList(*Session) = .empty,
    next_session_id: u32 = 1,
    next_window_id: u32 = 1,
    next_pane_id: u32 = 1,
    listener_fd: ?i32 = null,
    client_fds: std.ArrayList(i32) = .empty,
    client_readers: std.AutoHashMap(i32, *MessageReader),
    input_reader: @import("../tty/tty_key.zig").InputReader = .{},
    dispatcher: @import("../key_binding.zig").KeyDispatcher,
    stdin_fd: ?i32 = null,
    loop: Loop = .{},
    global_options: @import("../options.zig").Options,
    global_window_options: @import("../options.zig").Options,
    response_buf: std.ArrayList(u8),
    display_clients: std.ArrayList(DisplayClient) = .empty,
    current_client_fd: ?i32 = null,
    render_buf: std.ArrayList(u8),
    buffers: buffer_mod.BufferList,
    log_messages: std.ArrayList([]const u8) = .empty,
    display_sx: u32 = 80,
    display_sy: u32 = 24,
    dirty: bool = true,
    message: ?[]const u8 = null,
    message_time: i64 = 0,
    command_mode: bool = false,
    command_buf: std.ArrayList(u8) = .empty,
    mouse_press_x: u32 = 0,
    mouse_press_y: u32 = 0,
    mouse_press_pane: ?*Pane = null,
    mouse_autoscroll_dir: ?enum { up, down } = null,
    mouse_autoscroll_pane: ?*Pane = null,
    ignore_unknown_msg_warn: bool = false,

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
            .buffers = buffer_mod.BufferList.init(allocator),
            .log_messages = .empty,
            .dirty = true,
            .ignore_unknown_msg_warn = false,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.log_messages.items) |m| {
            self.allocator.free(m);
        }
        self.log_messages.deinit(self.allocator);
        if (self.message) |m| self.allocator.free(m);
        self.command_buf.deinit(self.allocator);
        self.buffers.deinit();
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
        for (self.display_clients.items) |*dc| {
            dc.deinit(self.allocator);
        }
        self.display_clients.deinit(self.allocator);
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
        @import("../thai.zig").deinitLibThai();
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
        errdefer self.allocator.free(duped);
        try self.log_messages.append(self.allocator, duped);
        if (self.log_messages.items.len > 1000) {
            const old = self.log_messages.orderedRemove(0);
            self.allocator.free(old);
        }
    }

    fn currentMillis() i64 {
        var tv: extern struct {
            tv_sec: i64,
            tv_usec: i64,
        } = undefined;
        _ = gettimeofday(@ptrCast(&tv), null);
        return tv.tv_sec * 1000 + @divFloor(tv.tv_usec, 1000);
    }

    pub fn setMessage(self: *Server, msg: []const u8) !void {
        if (self.message) |m| self.allocator.free(m);
        self.message = try self.allocator.dupe(u8, msg);
        self.message_time = currentMillis();
    }

    pub fn clearMessage(self: *Server) void {
        if (self.message) |m| {
            self.allocator.free(m);
            self.message = null;
        }
    }

    pub fn messageExpired(self: *Server, display_time: u32) bool {
        if (self.message == null) return true;
        const now = currentMillis();
        return now - self.message_time >= display_time;
    }

    pub fn listen(self: *Server) ServerError!void {
        const fd = try socket_mod.createListener();
        self.listener_fd = fd;
        try self.loop.addFd(self.allocator, fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(self));
    }

    pub fn reapZombies() void {
        if (sigchldFlag.load(.seq_cst)) {
            sigchldFlag.store(false, .seq_cst);
            var status: c_int = 0;
            while (true) {
                const pid = c.waitpid(-1, &status, 1);
                if (pid <= 0) break;
                std.log.info("reapZombies reaped pid {d} with status {d}", .{ pid, status });
            }
        }
    }

    fn tickAutoscroll(self: *Server) void {
        const pane = self.mouse_autoscroll_pane orelse return;
        const dir = self.mouse_autoscroll_dir orelse return;
        if (pane.screen.copy_mode) |*cm| {
            if (cm.selection.active) {
                const grid = &pane.screen.grid;
                const hist_len: u32 = @intCast(grid.history.items.len);
                if (dir == .up and cm.scroll_offset < hist_len) {
                    cm.scroll_offset += 1;
                    cm.adjustSelectionForAutoScroll(1);
                    pane.dirty = true;
                } else if (dir == .down and cm.scroll_offset > 0) {
                    cm.scroll_offset -= 1;
                    cm.adjustSelectionForAutoScroll(-1);
                    pane.dirty = true;
                }
            }
        }
    }

    pub fn run(self: *Server, timeout_ms: i32) ServerError!void {
        reapZombies();
        self.tickAutoscroll();
        const auto_timeout: i32 = if (self.mouse_autoscroll_pane != null) @min(timeout_ms, 50) else timeout_ms;
        const events = try self.loop.pollOnce(self.allocator, auto_timeout);
        for (events) |ev| {
            switch (self.handlePtyEvent(ev)) {
                .destroyed => break,
                .handled => continue,
                .not_ours => {},
            }

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

    const PtyResult = enum { not_ours, handled, destroyed };

    fn handlePtyEvent(self: *Server, ev: loop_mod.PollEvent) PtyResult {
        if (ev.fd == self.listener_fd or ev.fd == self.stdin_fd) return .not_ours;
        for (self.client_fds.items) |cfd| {
            if (ev.fd == cfd) return .not_ours;
        }
        const pane: *Pane = @ptrCast(@alignCast(ev.udata orelse return .not_ours));
        if (!self.isPaneValid(pane)) {
            std.log.debug("handlePtyEvent: received event for invalid/stale pane pointer", .{});
            return .handled;
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
        } else if (has_hup) {
            // Read any pending data before the fd leaves the poll set.
            _ = pane.feedPty() catch {};
            self.loop.removeFd(ev.fd);
            // On Linux the kernel can report POLLHUP when the foreground
            // process group goes empty (e.g. vim/htop just exited) while the
            // shell still holds the slave open.  Check whether the shell
            // process is actually dead before declaring exit.
            var status: c_int = 0;
            const shell_alive = if (pane.pty) |pty| blk: {
                const rc = c.waitpid(pty.pid, &status, 1); // WNOHANG
                std.log.info("HUP waitpid(pid={d}) returned {d}, status={d}", .{ pty.pid, rc, status });
                break :blk rc == 0;
            } else false;
            if (!shell_alive) {
                std.log.info("pty process exited (HUP)", .{});
                exited = true;
            } else {
                const c_usleep = struct {
                    extern "c" fn usleep(usec: c_uint) c_int;
                }.usleep;
                _ = c_usleep(5000);
                _ = pane.feedPty() catch {};
                self.watchPanePty(pane) catch {};
            }
        } else if (has_err) {
            self.loop.removeFd(ev.fd);
            exited = true;
        }

        var destroyed = false;
        if (exited) {
            const remain = if (pane.window) |w| w.options.asFlag("remain-on-exit") orelse false else false;
            // Only honour remain-on-exit if there are other panes/windows/
            // sessions to keep the server alive.  Otherwise destroy so the
            // client can exit cleanly (e.g. user typed "exit").
            const has_other_panes = if (pane.window) |w| w.panes.items.len > 1 else false;
            if (remain and has_other_panes) {
                std.log.info("pane exited, remain-on-exit set — keeping pane", .{});
                if (pane.pty) |*pty| {
                    pty.deinit();
                    pane.pty = null;
                }
                pane.dirty = true;
                self.dirty = true;
            } else {
                self.destroyPane(pane);
                destroyed = true;
            }
        }
        return if (destroyed) .destroyed else .handled;
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

            if (pane.pty) |*pty| {
                self.loop.removeFd(pty.master);
            }

            if (win.panes.items.len <= 1) {
                session.killWindow(self.allocator, win);
            } else {
                win.removePane(self.allocator, pane);
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

    pub fn setupPane(self: *Server, session: *Session, pane: *Pane, cwd: ?[]const u8) ServerError!void {
        const shell = try self.resolveShell(self.allocator, session);
        defer self.allocator.free(shell);
        try pane.spawn(self.allocator, &[_][]const u8{shell}, cwd);
        try self.watchPanePty(pane);
        pane.drainPty();
    }

    /// Returns an allocated slice. Caller must free with `allocator.free`.
    pub fn paneCwd(self: *Server, pane: *Pane) ?[]const u8 {
        const pty = pane.pty orelse return null;
        return pty.getCwd(self.allocator) catch return null;
    }

    pub fn executeAction(self: *Server, action: @import("../key_binding.zig").Action) ServerError!void {
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;

        self.dirty = true;

        switch (action) {
            .new_window => {
                const current_cwd = self.paneCwd(pane);
                defer if (current_cwd) |cwd_ptr| self.allocator.free(cwd_ptr);
                const win = try session.newWindow(self.allocator, "window");
                if (win.active_pane) |p| {
                    try self.setupPane(session, p, current_cwd);
                }
            },
            .split_horizontal => {
                const current_cwd = self.paneCwd(pane);
                defer if (current_cwd) |cwd_ptr| self.allocator.free(cwd_ptr);
                const new_pane = try window.splitPane(self.allocator, pane, false, 0.5);
                try self.setupPane(session, new_pane, current_cwd);
            },
            .split_vertical => {
                const current_cwd = self.paneCwd(pane);
                defer if (current_cwd) |cwd_ptr| self.allocator.free(cwd_ptr);
                const new_pane = try window.splitPane(self.allocator, pane, true, 0.5);
                try self.setupPane(session, new_pane, current_cwd);
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
                const target_fd = self.current_client_fd orelse (if (self.display_clients.items.len > 0) self.display_clients.items[0].fd else null);
                if (target_fd) |cfd| {
                    const detach_pkt = protocol.Packet.make(.detach, "");
                    var detach_buf: [128]u8 = undefined;
                    const ser = detach_pkt.serialize(&detach_buf);
                    var remaining: []const u8 = ser;
                    while (remaining.len > 0) {
                        const written_bytes = c.write(cfd, remaining.ptr, remaining.len);
                        if (written_bytes < 0) {
                            if (std.c.errno(written_bytes) == .INTR) continue;
                            break;
                        }
                        remaining = remaining[@intCast(written_bytes)..];
                    }
                    for (self.display_clients.items, 0..) |*dc, idx| {
                        if (dc.fd == cfd) {
                            dc.deinit(self.allocator);
                            _ = self.display_clients.swapRemove(idx);
                            break;
                        }
                    }
                    if (self.current_client_fd == cfd) {
                        self.current_client_fd = null;
                    }
                    self.recalculateMinimumSize();
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
                pane.enterCopyMode() catch {};
            },
            .paste_buffer => {
                if (self.buffers.get(null)) |pb| {
                    if (pb.len > MAX_PASTE_SIZE) {
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Error: paste buffer too large ({d} bytes, limit is {d}B)", .{ pb.len, MAX_PASTE_SIZE }) catch "Error: paste buffer too large";
                        self.setMessage(msg) catch {};
                    } else {
                        if (pane.screen.mode.paste) {
                            pane.writeInput("\x1b[200~") catch {};
                            pane.writeInput(pb) catch {};
                            pane.writeInput("\x1b[201~") catch {};
                        } else {
                            pane.writeInput(pb) catch {};
                        }
                    }
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
                const target_w = current_w +| 1;
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
                const target_h = current_h +| 1;
                pane.resizeTerminal(current_w, target_h) catch {};
            },
            .send_prefix => {
                const prefix_key = self.dispatcher.prefix;
                writeKeyToPty(pane, prefix_key);
            },
            .clock_mode => {
                if (pane.saved_grid) |*g| {
                    g.deinit();
                    pane.saved_grid = null;
                }
                pane.saved_grid = pane.screen.grid.clone(pane.screen.grid.allocator) catch {
                    pane.screen.clock_mode = false;
                    return;
                };
                pane.screen.clock_mode = true;
                pane.screen.clock_utc = false;
                const clock = @import("../clock.zig");
                clock.renderClock(&pane.screen.grid, pane.screen.grid.width, pane.screen.grid.height, false);
                pane.dirty = true;
            },
            .command_prompt => {
                self.command_mode = true;
                self.command_buf.clearRetainingCapacity();
                self.dirty = true;
            },
            .reflow_pane => {
                pane.forceReflow() catch {};
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
    fn writeKeyToPty(pane_opt: ?*Pane, k: @import("../key.zig").Key) void {
        const pane = pane_opt orelse return;
        switch (k) {
            .char => |ch| {
                // Handle Tab variants before the general char path, since
                // kitty protocol encodes Tab as codepoint 9 with modifiers.
                if (ch.code == 9) {
                    if (ch.mod.shift and !ch.mod.ctrl and !ch.mod.alt) {
                        pane.writeInput("\x1b[Z") catch {};
                        return;
                    }
                    if (ch.mod.alt) {
                        pane.writeInput("\x1b\x09") catch {};
                        return;
                    }
                    pane.writeInput("\t") catch {};
                    return;
                }
                // Kitty private-use arrow codepoints (57344-57347)
                if (ch.code >= 57344 and ch.code <= 57347) {
                    const seq: []const u8 = switch (ch.code) {
                        57344 => "\x1bOA",
                        57345 => "\x1bOB",
                        57347 => "\x1bOC",
                        57346 => "\x1bOD",
                        else => unreachable,
                    };
                    pane.writeInput(seq) catch {};
                    return;
                }
                if (ch.mod.ctrl) {
                    const ctrl_byte: u8 = @intCast(ch.code & 0x1F);
                    if (ch.mod.alt) {
                        pane.writeInput(&[_]u8{ 0x1b, ctrl_byte }) catch {};
                    } else {
                        pane.writeInput(&[_]u8{ctrl_byte}) catch {};
                    }
                } else if (ch.mod.alt) {
                    if (ch.code <= 0x7F) {
                        pane.writeInput(&[_]u8{ 0x1b, @intCast(ch.code) }) catch {};
                    }
                } else if (ch.code >= 0x20 and ch.code <= 0x7E) {
                    pane.writeInput(&[_]u8{@intCast(ch.code)}) catch {};
                } else if (ch.code < 0x20 or ch.code == 0x7F) {
                    pane.writeInput(&[_]u8{@intCast(ch.code)}) catch {};
                } else if (ch.code > 0x7F) {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(ch.code, &utf8_buf) catch return;
                    pane.writeInput(utf8_buf[0..len]) catch {};
                }
            },
            .arrow => |a| {
                const seq: []const u8 = switch (a.key) {
                    .up => "\x1bOA",
                    .down => "\x1bOB",
                    .right => "\x1bOC",
                    .left => "\x1bOD",
                };
                pane.writeInput(seq) catch {};
            },
            .special => |s| {
                switch (s.key) {
                    .enter => pane.writeInput("\r") catch {},
                    .tab => pane.writeInput("\t") catch {},
                    .backspace => pane.writeInput("\x7f") catch {},
                    .escape => pane.writeInput("\x1b") catch {},
                    .home => pane.writeInput("\x1b[H") catch {},
                    .end => pane.writeInput("\x1b[F") catch {},
                    .page_up => pane.writeInput("\x1b[5~") catch {},
                    .page_down => pane.writeInput("\x1b[6~") catch {},
                    .insert => pane.writeInput("\x1b[2~") catch {},
                    .delete_ => pane.writeInput("\x1b[3~") catch {},
                    .btab => pane.writeInput("\x1b[Z") catch {},
                }
            },
            .function => |f| {
                const seq: []const u8 = switch (f.key) {
                    .f1 => "\x1bOP",
                    .f2 => "\x1bOQ",
                    .f3 => "\x1bOR",
                    .f4 => "\x1bOS",
                    .f5 => "\x1b[15~",
                    .f6 => "\x1b[17~",
                    .f7 => "\x1b[18~",
                    .f8 => "\x1b[19~",
                    .f9 => "\x1b[20~",
                    .f10 => "\x1b[21~",
                    .f11 => "\x1b[23~",
                    .f12 => "\x1b[24~",
                };
                pane.writeInput(seq) catch {};
            },
            else => {},
        }
    }

    pub fn processInput(self: *Server, buf: []const u8) ServerError!void {
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;

        var i: usize = 0;
        var esc_buf: std.ArrayList(u8) = .empty;
        defer esc_buf.deinit(self.allocator);

        while (i < buf.len) : (i += 1) {
            const byte = buf[i];

            if (self.input_reader.state == .ground and byte >= 0x20 and byte != 0x7f and !self.command_mode and !pane.choose_mode.active and !pane.screen.clock_mode and pane.screen.copy_mode == null and self.dispatcher.prefix_state == .normal) {
                var run_len: usize = 1;
                while (i + run_len < buf.len) : (run_len += 1) {
                    const next_byte = buf[i + run_len];
                    if (next_byte < 0x20 or next_byte == 0x7f) break;
                }
                pane.writeInput(buf[i .. i + run_len]) catch {};
                i += run_len - 1;
                continue;
            }

            if (self.command_mode) {
                if (self.input_reader.feed(byte)) |event| {
                    switch (event) {
                        .key => |k| {
                            var is_enter = false;
                            if (k == .special and k.special.key == .enter) {
                                is_enter = true;
                            } else if (k == .char and (k.char.code == '\r' or k.char.code == '\n')) {
                                is_enter = true;
                            }

                            var is_cancel = false;
                            if (k == .special and k.special.key == .escape) {
                                is_cancel = true;
                            } else if (k == .char and k.char.code == 0x1b) {
                                is_cancel = true;
                            } else if (k == .char and k.char.code == 'C' and k.char.mod.ctrl) {
                                is_cancel = true;
                            }

                            var is_backspace = false;
                            if (k == .special and k.special.key == .backspace) {
                                is_backspace = true;
                            } else if (k == .char and k.char.code == 'H' and k.char.mod.ctrl) {
                                is_backspace = true;
                            }

                            var is_tab = false;
                            if (k == .special and k.special.key == .tab) {
                                is_tab = true;
                            }

                            if (is_enter) {
                                const cmd = self.command_buf.items;
                                if (cmd.len > 0) {
                                    const dispatch = @import("dispatch.zig");
                                    const result = dispatch.dispatchCommand(self.allocator, self, cmd);
                                    if (result.response_type == .ready or result.response_type == .err) {
                                        if (result.data.len > 0) self.setMessage(result.data) catch {};
                                    }
                                }
                                self.command_mode = false;
                                self.command_buf.clearRetainingCapacity();
                                self.dirty = true;
                            } else if (is_tab) {
                                const prefix = self.command_buf.items;
                                var matches: std.ArrayList(@import("../choose.zig").ChooseItem) = .empty;
                                defer {
                                    for (matches.items) |item| {
                                        self.allocator.free(item.name);
                                        self.allocator.free(item.data);
                                    }
                                    matches.deinit(self.allocator);
                                }

                                const table = @import("../cmd/cmd.zig").cmdTable();
                                for (table) |entry| {
                                    if (std.mem.startsWith(u8, entry.name, prefix)) {
                                        const dup_name = self.allocator.dupe(u8, entry.name) catch continue;
                                        errdefer self.allocator.free(dup_name);
                                        const dup_data = self.allocator.dupe(u8, entry.name) catch {
                                            self.allocator.free(dup_name);
                                            continue;
                                        };
                                        matches.append(self.allocator, .{
                                            .name = dup_name,
                                            .data = dup_data,
                                        }) catch {
                                            self.allocator.free(dup_name);
                                            self.allocator.free(dup_data);
                                        };
                                    }
                                }

                                if (matches.items.len == 1) {
                                    self.command_buf.clearRetainingCapacity();
                                    try self.command_buf.appendSlice(self.allocator, matches.items[0].name);
                                    try self.command_buf.append(self.allocator, ' ');
                                    self.dirty = true;
                                } else if (matches.items.len > 1) {
                                    if (pane.saved_grid) |*g| {
                                        g.deinit();
                                        pane.saved_grid = null;
                                    }
                                    pane.saved_grid = try pane.screen.grid.clone(pane.screen.grid.allocator);

                                    self.command_mode = false;
                                    try pane.choose_mode.enter(pane.screen.grid.allocator, matches.items);
                                    pane.choose_mode.target = .command;
                                    pane.choose_mode.renderIntoGrid(&pane.screen.grid);
                                    pane.dirty = true;
                                }
                            } else if (is_cancel) {
                                self.command_mode = false;
                                self.command_buf.clearRetainingCapacity();
                                self.dirty = true;
                            } else if (is_backspace) {
                                if (self.command_buf.items.len > 0) {
                                    self.command_buf.items.len -= 1;
                                }
                                self.dirty = true;
                            } else if (k == .char) {
                                const code = k.char.code;
                                if (code >= 0x20 and code <= 0x7e and !k.char.mod.ctrl and !k.char.mod.alt) {
                                    try self.command_buf.append(self.allocator, @intCast(code));
                                    self.dirty = true;
                                }
                            }
                        },
                        else => {},
                    }
                }
                continue;
            }

            if (pane.choose_mode.active) {
                if (self.input_reader.state == .esc and byte != '[' and byte != 'O') {
                    self.input_reader.state = .ground;
                    const escaped = pane.choose_mode.handleKey(.{ .special = .{ .key = .escape } }, self.allocator) catch continue;
                    if (escaped == .cancelled) {
                        const is_cmd = (pane.choose_mode.target == .command);
                        pane.choose_mode.active = false;

                        const grid_alloc = pane.screen.grid.allocator;
                        if (pane.saved_grid) |sg| {
                            pane.screen.grid.deinit();
                            pane.screen.grid = sg;
                            pane.saved_grid = null;
                        } else {
                            if (@import("../grid.zig").Grid.init(grid_alloc, pane.screen.grid.width, pane.screen.grid.height)) |fallback| {
                                pane.screen.grid.deinit();
                                pane.screen.grid = fallback;
                            } else |_| {}
                        }

                        pane.dirty = true;
                        if (is_cmd) {
                            self.command_mode = true;
                        }
                    }
                    continue;
                }

                if (self.input_reader.feed(byte)) |event| {
                    switch (event) {
                        .key => |k| {
                            const res = pane.choose_mode.handleKey(k, self.allocator) catch continue;
                            switch (res) {
                                .consumed => {
                                    pane.choose_mode.renderIntoGrid(&pane.screen.grid);
                                    pane.dirty = true;
                                },
                                .selected => {
                                    const selected = pane.choose_mode.selectedItem();
                                    const is_cmd = (pane.choose_mode.target == .command);
                                    pane.choose_mode.active = false;

                                    const grid_alloc = pane.screen.grid.allocator;
                                    if (pane.saved_grid) |sg| {
                                        pane.screen.grid.deinit();
                                        pane.screen.grid = sg;
                                        pane.saved_grid = null;
                                    } else {
                                        if (@import("../grid.zig").Grid.init(grid_alloc, pane.screen.grid.width, pane.screen.grid.height)) |fallback| {
                                            pane.screen.grid.deinit();
                                            pane.screen.grid = fallback;
                                        } else |_| {}
                                    }

                                    pane.dirty = true;
                                    if (is_cmd) {
                                        if (selected) |item| {
                                            self.command_buf.clearRetainingCapacity();
                                            try self.command_buf.appendSlice(self.allocator, item.name);
                                            try self.command_buf.append(self.allocator, ' ');
                                        }
                                        self.command_mode = true;
                                    } else {
                                        if (selected) |item| {
                                            const buf_data = self.buffers.get(item.name);
                                            if (buf_data) |data| {
                                                if (data.len > MAX_PASTE_SIZE) {
                                                    var msg_buf: [128]u8 = undefined;
                                                    const msg = std.fmt.bufPrint(&msg_buf, "Error: paste buffer too large ({d} bytes, limit is {d}B)", .{ data.len, MAX_PASTE_SIZE }) catch "Error: paste buffer too large";
                                                    self.setMessage(msg) catch {};
                                                } else {
                                                    if (pane.pty) |*chosen_pty| {
                                                        if (pane.screen.mode.paste) {
                                                            _ = chosen_pty.writeInput("\x1b[200~") catch {};
                                                            _ = chosen_pty.writeInput(data) catch {};
                                                            _ = chosen_pty.writeInput("\x1b[201~") catch {};
                                                        } else {
                                                            _ = chosen_pty.writeInput(data) catch {};
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                },
                                .cancelled => {
                                    const is_cmd = (pane.choose_mode.target == .command);
                                    pane.choose_mode.active = false;

                                    const grid_alloc = pane.screen.grid.allocator;
                                    if (pane.saved_grid) |sg| {
                                        pane.screen.grid.deinit();
                                        pane.screen.grid = sg;
                                        pane.saved_grid = null;
                                    } else {
                                        if (@import("../grid.zig").Grid.init(grid_alloc, pane.screen.grid.width, pane.screen.grid.height)) |fallback| {
                                            pane.screen.grid.deinit();
                                            pane.screen.grid = fallback;
                                        } else |_| {}
                                    }

                                    pane.dirty = true;
                                    if (is_cmd) {
                                        self.command_mode = true;
                                    }
                                },
                            }
                        },
                        else => {},
                    }
                }
                continue;
            }

            if (pane.screen.clock_mode) {
                pane.screen.clock_mode = false;

                const grid_alloc = pane.screen.grid.allocator;
                if (pane.saved_grid) |sg| {
                    pane.screen.grid.deinit();
                    pane.screen.grid = sg;
                    pane.saved_grid = null;
                } else {
                    if (@import("../grid.zig").Grid.init(grid_alloc, pane.screen.grid.width, pane.screen.grid.height)) |fallback| {
                        pane.screen.grid.deinit();
                        pane.screen.grid = fallback;
                    } else |_| {}
                }

                pane.dirty = true;
            }

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
                                        const data = cm.yankSelection(self.allocator, &pane.screen.grid) catch null;
                                        if (data) |d| {
                                            const name = try self.buffers.generateName();
                                            errdefer self.allocator.free(name);
                                            try self.buffers.pushOwned(name, d);
                                        }
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
                                if (m.button == .scroll_up or m.button == .scroll_down) {
                                    self.handleMouseFocus(m.x, m.y) catch {};
                                    const target_pane = window.active_pane orelse return;
                                    const target_wants_mouse = target_pane.screen.mode.mouse_standard or
                                        target_pane.screen.mode.mouse_button or
                                        target_pane.screen.mode.mouse_sgr;
                                    if (target_wants_mouse) {
                                        self.forwardMouseToPane(target_pane, m, window);
                                    } else {
                                        if (target_pane.screen.copy_mode) |*target_cm| {
                                            if (m.button == .scroll_up) {
                                                target_cm.scroll_offset = @min(target_cm.scroll_offset + 3, @as(u32, @intCast(target_pane.screen.grid.history.items.len)));
                                            } else {
                                                if (target_cm.scroll_offset == 0) {
                                                    target_pane.screen.copy_mode = null;
                                                } else {
                                                    target_cm.scroll_offset = target_cm.scroll_offset -| 3;
                                                }
                                            }
                                            target_pane.dirty = true;
                                        } else {
                                            if (m.button == .scroll_up) {
                                                target_pane.enterCopyMode() catch {};
                                                if (target_pane.screen.copy_mode) |*target_cm| {
                                                    target_cm.scroll_offset = @min(3, @as(u32, @intCast(target_pane.screen.grid.history.items.len)));
                                                }
                                                target_pane.dirty = true;
                                            }
                                        }
                                    }
                                } else if (m.button == .left) {
                                    const old_active_pane = window.active_pane;
                                    self.handleMouseFocus(m.x, m.y) catch {};
                                    const current_active_pane = window.active_pane orelse return;
                                    if (current_active_pane == old_active_pane) {
                                        if (self.findPaneBounds(window.layout.root, current_active_pane, 0, 0, window.layout.width, window.layout.height)) |pb| {
                                            const local_x = m.x -| pb.x;
                                            const local_y = m.y -| pb.y;
                                            const grid_w = current_active_pane.screen.grid.width;
                                            const grid_h = current_active_pane.screen.grid.height;
                                            const inside = m.x >= pb.x and m.x < pb.x + pb.w and m.y >= pb.y and m.y < pb.y + pb.h;
                                            if (inside) {
                                                cm.cursor_x = @min(local_x, grid_w -| 1);
                                                cm.cursor_y = @min(local_y, grid_h -| 1);
                                                if (!cm.selection.active) {
                                                    cm.startSelection();
                                                } else {
                                                    cm.updateSelection();
                                                }
                                            }
                                            const hist_len: u32 = @intCast(current_active_pane.screen.grid.history.items.len);
                                            const at_top_edge = (local_y == 0 and inside) or m.y < pb.y;
                                            const at_bottom_edge = (local_y >= grid_h -| 1 and grid_h > 0 and inside) or m.y >= pb.y + pb.h;
                                            if (at_top_edge and cm.scroll_offset < hist_len) {
                                                self.mouse_autoscroll_dir = .up;
                                                self.mouse_autoscroll_pane = current_active_pane;
                                            } else if (at_bottom_edge and cm.scroll_offset > 0) {
                                                self.mouse_autoscroll_dir = .down;
                                                self.mouse_autoscroll_pane = current_active_pane;
                                            } else {
                                                self.mouse_autoscroll_dir = null;
                                                self.mouse_autoscroll_pane = null;
                                            }
                                            current_active_pane.dirty = true;
                                        }
                                    }
                                } else if (m.button == .release) {
                                    self.mouse_autoscroll_dir = null;
                                    self.mouse_autoscroll_pane = null;
                                    if (cm.selection.active) {
                                        const data = cm.yankSelection(self.allocator, &pane.screen.grid) catch null;
                                        if (data) |d| {
                                            const name = try self.buffers.generateName();
                                            errdefer self.allocator.free(name);
                                            try self.buffers.pushOwned(name, d);
                                        }
                                        pane.screen.copy_mode = null;
                                        pane.dirty = true;
                                    }
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
                                    } else if (m.button == .scroll_up or m.button == .scroll_down) {
                                        self.handleMouseFocus(m.x, m.y) catch {};
                                    }
                                    const active_pane = window.active_pane orelse return;
                                    const wants_mouse = active_pane.screen.mode.mouse_standard or
                                        active_pane.screen.mode.mouse_button or
                                        active_pane.screen.mode.mouse_sgr;
                                    std.log.debug("MOUSE EVENT: button={any}, x={d}, y={d}, wants_mouse={}, standard={}, button_mode={}, sgr={}", .{
                                        m.button,                               m.x,                                  m.y,                               wants_mouse,
                                        active_pane.screen.mode.mouse_standard, active_pane.screen.mode.mouse_button, active_pane.screen.mode.mouse_sgr,
                                    });
                                    if (wants_mouse) {
                                        handled = true;
                                        self.forwardMouseToPane(active_pane, m, window);
                                    } else {
                                        handled = true;
                                        if (m.button == .scroll_up) {
                                            if (active_pane.screen.copy_mode) |*target_cm| {
                                                target_cm.scroll_offset = @min(target_cm.scroll_offset + 3, @as(u32, @intCast(active_pane.screen.grid.history.items.len)));
                                            } else {
                                                active_pane.enterCopyMode() catch {};
                                                if (active_pane.screen.copy_mode) |*target_cm| {
                                                    target_cm.scroll_offset = @min(3, @as(u32, @intCast(active_pane.screen.grid.history.items.len)));
                                                }
                                            }
                                            active_pane.dirty = true;
                                        } else if (m.button == .scroll_down) {
                                            if (active_pane.screen.copy_mode) |*target_cm| {
                                                if (target_cm.scroll_offset == 0) {
                                                    active_pane.screen.copy_mode = null;
                                                } else {
                                                    target_cm.scroll_offset = target_cm.scroll_offset -| 3;
                                                }
                                                active_pane.dirty = true;
                                            }
                                        } else if (m.button == .left and m.drag) {
                                            if (self.mouse_press_pane) |press_pane| {
                                                if (self.findPaneBounds(window.layout.root, press_pane, 0, 0, window.layout.width, window.layout.height)) |pb| {
                                                    if (press_pane.screen.copy_mode == null) {
                                                        press_pane.enterCopyMode() catch {};
                                                    }
                                                    if (press_pane.screen.copy_mode) |*cm| {
                                                        const grid_w = press_pane.screen.grid.width;
                                                        const grid_h = press_pane.screen.grid.height;
                                                        const local_x = m.x -| pb.x;
                                                        const local_y = m.y -| pb.y;
                                                        const inside = m.x >= pb.x and m.x < pb.x + pb.w and m.y >= pb.y and m.y < pb.y + pb.h;
                                                        if (inside) {
                                                            const press_local_x = if (self.mouse_press_x >= pb.x) self.mouse_press_x - pb.x else 0;
                                                            const press_local_y = if (self.mouse_press_y >= pb.y) self.mouse_press_y - pb.y else 0;
                                                            if (!cm.selection.active) {
                                                                cm.cursor_x = @min(press_local_x, grid_w -| 1);
                                                                cm.cursor_y = @min(press_local_y, grid_h -| 1);
                                                                cm.startSelection();
                                                            }
                                                            cm.cursor_x = @min(local_x, grid_w -| 1);
                                                            cm.cursor_y = @min(local_y, grid_h -| 1);
                                                            cm.updateSelection();
                                                        }
                                                        const hist_len: u32 = @intCast(press_pane.screen.grid.history.items.len);
                                                        const at_top_edge = (local_y == 0 and inside) or m.y < pb.y;
                                                        const at_bottom_edge = (local_y >= grid_h -| 1 and grid_h > 0 and inside) or m.y >= pb.y + pb.h;
                                                        if (at_top_edge and cm.scroll_offset < hist_len) {
                                                            self.mouse_autoscroll_dir = .up;
                                                            self.mouse_autoscroll_pane = press_pane;
                                                        } else if (at_bottom_edge and cm.scroll_offset > 0) {
                                                            self.mouse_autoscroll_dir = .down;
                                                            self.mouse_autoscroll_pane = press_pane;
                                                        } else {
                                                            self.mouse_autoscroll_dir = null;
                                                            self.mouse_autoscroll_pane = null;
                                                        }
                                                    }
                                                    press_pane.dirty = true;
                                                }
                                            }
                                        } else if (m.button == .left) {
                                            self.mouse_press_x = m.x;
                                            self.mouse_press_y = m.y;
                                            self.handleMouseFocus(m.x, m.y) catch {};
                                            self.mouse_press_pane = window.active_pane;
                                        } else if (m.button == .release) {
                                            self.mouse_autoscroll_dir = null;
                                            self.mouse_autoscroll_pane = null;
                                            if (self.mouse_press_pane) |press_pane| {
                                                if (press_pane.screen.copy_mode) |*cm| {
                                                    if (cm.selection.active) {
                                                        const data = cm.yankSelection(self.allocator, &press_pane.screen.grid) catch null;
                                                        if (data) |d| {
                                                            const name = try self.buffers.generateName();
                                                            errdefer self.allocator.free(name);
                                                            try self.buffers.pushOwned(name, d);
                                                        }
                                                        press_pane.screen.copy_mode = null;
                                                        press_pane.dirty = true;
                                                    }
                                                }
                                            }
                                            self.mouse_press_pane = null;
                                        }
                                    }
                                } else {
                                    handled = true;
                                }
                            },
                            else => {},
                        }

                        if (!handled) {
                            switch (event) {
                                .key => |k| writeKeyToPty(pane, k),
                                else => pane.writeInput(esc_buf.items) catch {},
                            }
                        }
                        esc_buf.clearRetainingCapacity();
                    } else if (self.input_reader.state == .ground) {
                        pane.writeInput(esc_buf.items) catch {};
                        esc_buf.clearRetainingCapacity();
                    }
                } else {
                    if (self.dispatcher.prefix_state == .normal) {
                        pane.writeInput(&[_]u8{byte}) catch {};
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
            const prefix_len = 3 +| @as(u32, @intCast(@min(session.name.len, std.math.maxInt(u32))));
            col += prefix_len;

            for (session.windows.items, 0..) |win, idx| {
                const is_active = (win == session.active_window);
                const suffix_len: u32 = if (is_active) 1 else 0;

                var idx_buf: [32]u8 = undefined;
                const idx_len = (std.fmt.bufPrint(&idx_buf, "{}", .{idx}) catch {
                    std.log.warn("window index overflow: idx={d}", .{idx});
                    return error.OutOfMemory;
                }).len;
                const entry_len = 1 +| @as(u32, @intCast(@min(idx_len, std.math.maxInt(u32)))) +| 1 +| @as(u32, @intCast(@min(win.name.len, std.math.maxInt(u32)))) +| suffix_len;

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

    pub fn forwardMouseToPane(self: *Server, pane: *Pane, m: anytype, window: *Window) void {
        const wants_mouse = pane.screen.mode.mouse_standard or
            pane.screen.mode.mouse_button or
            pane.screen.mode.mouse_sgr;
        if (!wants_mouse) return;
        if (self.findPaneBounds(window.layout.root, pane, 0, 0, window.layout.width, window.layout.height)) |pb| {
            if (m.x >= pb.x and m.x < pb.x + pb.w and m.y >= pb.y and m.y < pb.y + pb.h) {
                const local_x = m.x - pb.x;
                const local_y = m.y - pb.y;
                var btn: u8 = switch (m.button) {
                    .left => @as(u8, 0),
                    .middle => 1,
                    .right => 2,
                    .release => 3,
                    .scroll_up => 64,
                    .scroll_down => 65,
                    .scroll_left => 66,
                    .scroll_right => 67,
                };
                if (m.mod.shift) btn |= 4;
                if (m.mod.alt) btn |= 8;
                if (m.mod.ctrl) btn |= 16;
                if (m.drag) btn |= 32;

                if (pane.pty) |*ap_pty| {
                    if (pane.screen.mode.mouse_sgr) {
                        const final_char: u8 = if (m.button == .release) 'm' else 'M';
                        var sgr_buf: [64]u8 = undefined;
                        const sgr_seq = std.fmt.bufPrint(&sgr_buf, "\x1b[<{d};{d};{d}{c}", .{
                            btn,
                            local_x + 1,
                            local_y + 1,
                            final_char,
                        }) catch null;
                        if (sgr_seq) |s| {
                            ap_pty.writeInput(s) catch {};
                        }
                    } else {
                        var legacy_buf: [6]u8 = .{ 0x1b, '[', 'M', 0, 0, 0 };
                        legacy_buf[3] = btn + 32;
                        legacy_buf[4] = @intCast(@min(local_x + 33, 255));
                        legacy_buf[5] = @intCast(@min(local_y + 33, 255));
                        ap_pty.writeInput(&legacy_buf) catch {};
                    }
                }
            }
        }
    }

    fn collectPaneBounds(self: *Server, node: *const @import("../layout.zig").Node, lx: u32, ly: u32, lw: u32, lh: u32, result: *std.ArrayList(render.PaneBounds)) ServerError!void {
        switch (node.*) {
            .leaf => |pane| {
                try result.append(self.allocator, .{ .pane = pane, .x = lx, .y = ly, .w = lw, .h = lh });
            },
            .split => |s| {
                if (s.direction == .horizontal) {
                    const available_w = lw -| 1;
                    const split_w = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_w)) * s.proportion));
                    const w1 = @max(1, split_w);
                    const w2 = @max(1, available_w -| w1);
                    try self.collectPaneBounds(s.a, lx, ly, w1, lh, result);
                    try self.collectPaneBounds(s.b, lx + w1 + 1, ly, w2, lh, result);
                } else {
                    const available_h = lh -| 1;
                    const split_h = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_h)) * s.proportion));
                    const h1 = @max(1, split_h);
                    const h2 = @max(1, available_h -| h1);
                    try self.collectPaneBounds(s.a, lx, ly, lw, h1, result);
                    try self.collectPaneBounds(s.b, lx, ly + h1 + 1, lw, h2, result);
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
                        return self.findPaneAtNode(s.a, x, y, lx, ly, split_w -| 1, lh);
                    } else {
                        return self.findPaneAtNode(s.b, x, y, lx + split_w, ly, lw - split_w, lh);
                    }
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    if (y < ly + split_h) {
                        return self.findPaneAtNode(s.a, x, y, lx, ly, lw, split_h -| 1);
                    } else {
                        return self.findPaneAtNode(s.b, x, y, lx, ly + split_h, lw, lh - split_h);
                    }
                }
            },
        }
    }

    fn findPaneBounds(self: *Server, node: *const @import("../layout.zig").Node, target: *Pane, lx: u32, ly: u32, lw: u32, lh: u32) ?render.PaneBounds {
        switch (node.*) {
            .leaf => |pane| {
                if (pane == target) {
                    return render.PaneBounds{ .pane = pane, .x = lx, .y = ly, .w = lw, .h = lh };
                }
                return null;
            },
            .split => |s| {
                if (s.direction == .horizontal) {
                    const split_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lw)) * s.proportion)));
                    if (self.findPaneBounds(s.a, target, lx, ly, split_w -| 1, lh)) |b| return b;
                    if (self.findPaneBounds(s.b, target, lx + split_w, ly, lw -| split_w, lh)) |b| return b;
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    if (self.findPaneBounds(s.a, target, lx, ly, lw, split_h -| 1)) |b| return b;
                    if (self.findPaneBounds(s.b, target, lx, ly + split_h, lw, lh -| split_h)) |b| return b;
                }
                return null;
            },
        }
    }

    fn paneClipboardCallback(ctx: ?*anyopaque, target: []const u8, base64: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx orelse return));

        // 1. Forward raw OSC 52 to all display clients wrapped in an output packet
        const raw_buf = std.fmt.allocPrint(self.allocator, "\x1b]52;{s};{s}\x07", .{ target, base64 }) catch return;
        defer self.allocator.free(raw_buf);

        const pkt = protocol.Packet.make(.output, raw_buf);
        var hdr: [5]u8 = undefined;
        pkt.header.encode(&hdr);

        for (self.display_clients.items) |dc| {
            var hdr_remaining: []const u8 = hdr[0..];
            var write_ok = true;
            while (hdr_remaining.len > 0) {
                const written = std.c.write(dc.fd, hdr_remaining.ptr, hdr_remaining.len);
                if (written < 0) {
                    if (std.c.errno(written) == .INTR) continue;
                    write_ok = false;
                    break;
                }
                hdr_remaining = hdr_remaining[@intCast(written)..];
            }

            if (!write_ok) continue;

            var body_remaining: []const u8 = raw_buf;
            while (body_remaining.len > 0) {
                const written = std.c.write(dc.fd, body_remaining.ptr, body_remaining.len);
                if (written < 0) {
                    if (std.c.errno(written) == .INTR) continue;
                    break;
                }
                body_remaining = body_remaining[@intCast(written)..];
            }
        }

        // 2. Decode base64 and push to self.buffers
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(base64) catch return;
        const decoded = self.allocator.alloc(u8, decoded_len) catch return;
        errdefer self.allocator.free(decoded);
        decoder.decode(decoded, base64) catch {
            self.allocator.free(decoded);
            return;
        };

        const name = self.buffers.generateName() catch {
            self.allocator.free(decoded);
            return;
        };
        errdefer self.allocator.free(name);
        self.buffers.pushOwned(name, decoded) catch {
            self.allocator.free(name);
            self.allocator.free(decoded);
        };
    }

    pub fn watchPanePty(self: *Server, pane: *Pane) ServerError!void {
        const pty = pane.pty orelse return;
        const parser = pane.getParser();
        parser.clipboard_cb = paneClipboardCallback;
        parser.clipboard_ctx = self;
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
            const msg_type = protocol.MessageType.fromByte(pkt.header.msg_type) orelse {
                if (!self.ignore_unknown_msg_warn) {
                    std.log.warn("server received unknown message type byte: {}", .{pkt.header.msg_type});
                }
                continue;
            };
            switch (msg_type) {
                .command => {
                    const dispatch = @import("dispatch.zig");
                    var result = dispatch.dispatchCommand(self.allocator, self, pkt.data);
                    self.dirty = true;
                    defer result.deinit();
                    try dispatch.sendResponse(fd, &result);
                },
                .identify_term => {
                    var exists = false;
                    for (self.display_clients.items) |*dc| {
                        if (dc.fd == fd) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        try self.display_clients.append(self.allocator, .{ .fd = fd });
                    }
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
                    self.current_client_fd = fd;
                    self.processInput(pkt.data) catch |err| {
                        std.log.err("stdin processing error: {any}", .{err});
                    };
                },
                .resize => {
                    if (pkt.data.len >= 8) {
                        const new_w = std.mem.readInt(u32, pkt.data[0..4], .little);
                        const new_h = std.mem.readInt(u32, pkt.data[4..8], .little);
                        for (self.display_clients.items) |*dc| {
                            if (dc.fd == fd) {
                                dc.sx = @max(new_w, 2);
                                dc.sy = @max(new_h, 2);
                                break;
                            }
                        }
                        self.recalculateMinimumSize();
                    }
                },
                .detach => {
                    for (self.display_clients.items, 0..) |*dc, idx| {
                        if (dc.fd == fd) {
                            dc.deinit(self.allocator);
                            _ = self.display_clients.swapRemove(idx);
                            break;
                        }
                    }
                    if (self.current_client_fd == fd) {
                        self.current_client_fd = null;
                    }
                    self.recalculateMinimumSize();
                },
                else => {
                    std.log.warn("server ignored unhandled message type: {any}", .{msg_type});
                },
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
        for (self.display_clients.items, 0..) |*dc, idx| {
            if (dc.fd == fd) {
                dc.deinit(self.allocator);
                _ = self.display_clients.swapRemove(idx);
                break;
            }
        }
        if (self.current_client_fd == fd) {
            self.current_client_fd = null;
        }
        self.recalculateMinimumSize();
    }

    pub fn recalculateMinimumSize(self: *Server) void {
        if (self.display_clients.items.len == 0) {
            return;
        }
        var min_sx: u32 = 999999;
        var min_sy: u32 = 999999;
        for (self.display_clients.items) |*dc| {
            if (dc.sx < min_sx) min_sx = dc.sx;
            if (dc.sy < min_sy) min_sy = dc.sy;
        }
        self.display_sx = @max(min_sx, 2);
        self.display_sy = @max(min_sy, 2);
        if (self.activeSession()) |s| {
            s.resize(self.display_sx, self.display_sy - 1) catch {};
        }
    }

    pub fn renderToDisplayClient(self: *Server) void {
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;

        if (pane.screen.clock_mode) {
            const now = @as(u64, @intCast(@max(time(null), 0)));
            if (now != pane.clock_time) {
                if (pane.saved_grid) |*sg| {
                    const grid_alloc = pane.screen.grid.allocator;
                    if (sg.clone(grid_alloc)) |cloned| {
                        pane.screen.grid.deinit();
                        pane.screen.grid = cloned;
                        pane.clock_time = now;
                        const clock = @import("../clock.zig");
                        clock.renderClock(&pane.screen.grid, pane.screen.grid.width, pane.screen.grid.height, pane.screen.clock_utc);
                        pane.dirty = true;
                    } else |_| {}
                }
            }
        }

        // Perform automatic window renaming
        for (session.windows.items) |win| {
            if (win.automatic_rename) {
                if (win.active_pane) |ap| {
                    if (ap.pty) |pty| {
                        var proc_buf: [128]u8 = undefined;
                        if (pty.getForegroundProcessName(&proc_buf)) |proc_name_val| {
                            if (proc_name_val.len > 0 and !std.mem.eql(u8, win.name, proc_name_val)) {
                                if (win.allocator.dupe(u8, proc_name_val)) |new_name| {
                                    win.allocator.free(win.name);
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

        const display_time = if (session.options.get("display-time")) |dt| blk: {
            break :blk if (dt == .number) @as(u32, @intCast(@max(dt.number, 0))) else 1000;
        } else 1000;
        if (self.messageExpired(display_time)) {
            if (self.message != null) {
                self.clearMessage();
                self.dirty = true;
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

        for (self.display_clients.items) |*dc| {
            self.render_buf.clearRetainingCapacity();

            var display = Display{
                .fd = dc.fd,
                .sx = dc.sx,
                .sy = dc.sy,
                .capture = &self.render_buf,
                .capture_allocator = self.allocator,
                .last_cells = &dc.last_cells,
                .last_sx = &dc.last_sx,
                .last_sy = &dc.last_sy,
                .merged_screen = &dc.merged_screen,
                .last_paste = &dc.last_paste,
            };

            var bounds: std.ArrayList(render.PaneBounds) = .empty;
            defer bounds.deinit(self.allocator);
            self.collectPaneBounds(window.layout.root, 0, 0, dc.sx, dc.sy - 1, &bounds) catch |err| {
                std.log.warn("collectPaneBounds error: {any}", .{err});
                continue;
            };

            const pane_in_copy_mode = pane.screen.copy_mode != null;
            display.renderAll(
                self.allocator,
                bounds.items,
                pane,
                session.name,
                session.windows.items,
                session.active_window,
                window.layout.root,
                .{
                    .status_fg = session.options.asColour("status-fg") orelse Colour.default_(),
                    .status_bg = session.options.asColour("status-bg") orelse Colour.default_(),
                    .pane_border_fg = session.options.asColour("pane-border-fg") orelse Colour.default_(),
                    .pane_active_border_fg = session.options.asColour("pane-active-border-fg") orelse Colour.default_(),
                },
                self.message,
                self.command_mode,
                self.command_buf.items,
                pane_in_copy_mode,
            ) catch |err| {
                std.log.warn("render error: {any}", .{err});
                continue;
            };

            if (self.render_buf.items.len > 0) {
                const pkt = protocol.Packet.make(.output, self.render_buf.items);
                var hdr: [5]u8 = undefined;
                pkt.header.encode(&hdr);

                // Write header — retry partial writes
                var hdr_remaining: []const u8 = hdr[0..];
                var write_ok = true;
                while (hdr_remaining.len > 0) {
                    const written_bytes = c.write(dc.fd, hdr_remaining.ptr, hdr_remaining.len);
                    if (written_bytes < 0) {
                        if (std.c.errno(written_bytes) == .INTR) continue;
                        write_ok = false;
                        break;
                    }
                    hdr_remaining = hdr_remaining[@intCast(written_bytes)..];
                }

                if (!write_ok) continue;

                // Write body — retry partial writes
                var body_remaining: []const u8 = self.render_buf.items;
                while (body_remaining.len > 0) {
                    const written_bytes = c.write(dc.fd, body_remaining.ptr, body_remaining.len);
                    if (written_bytes < 0) {
                        if (std.c.errno(written_bytes) == .INTR) continue;
                        break;
                    }
                    body_remaining = body_remaining[@intCast(written_bytes)..];
                }
            }
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
        var session = self.sessions.orderedRemove(idx);
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
        const log_mod = @import("../log.zig");
        for (parsed.directives.items) |d| {
            switch (d) {
                .set => |s| {
                    if (std.mem.eql(u8, s.option, "log-file")) {
                        if (s.value == .string) {
                            log_mod.enable(s.value.string);
                        }
                        continue;
                    }
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

        const content = try self.allocator.alloc(u8, @as(usize, @intCast(size)));
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
    try server.buffers.push("paste0", "pasted-content");
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

    // Test paste-buffer limit warning
    {
        const large_data = try testing.allocator.alloc(u8, Server.MAX_PASTE_SIZE + 1);
        defer testing.allocator.free(large_data);
        @memset(large_data, 'A');

        _ = server.buffers.delete("paste0");
        try server.buffers.push("paste0", large_data);
        try server.processInput(&[_]u8{ 0x02, ']' }); // Ctrl-b + ]
        try testing.expect(server.message != null);
        try testing.expect(std.mem.indexOf(u8, server.message.?, "Error: paste buffer too large") != null);
    }

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

    // Test resize_down
    const old_height = original_second_pane.screen.grid.height;
    try server.executeAction(.resize_down);
    try testing.expectEqual(old_height + 1, original_second_pane.screen.grid.height);
}

test "send-prefix forwards C-b to inner process" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;
    const pty = try @import("pty.zig").Pty.open();
    const slave_fd = pty.slave;
    pane.pty = pty;

    // Put slave in raw mode so read() doesn't wait for newline.
    {
        var term: std.c.termios = undefined;
        _ = std.c.tcgetattr(slave_fd, &term);
        term.lflag.ICANON = false;
        term.lflag.ECHO = false;
        term.oflag.OPOST = false;
        _ = std.c.tcsetattr(slave_fd, std.c.TCSA.FLUSH, &term);
    }

    // Feed C-b C-b — first enters prefix mode, second invokes send-prefix.
    try server.processInput(&[_]u8{ 0x02, 0x02 });

    // Read from slave: should see the prefix byte (0x02).
    var buf: [4]u8 = undefined;
    const n = std.posix.read(slave_fd, buf[0..]) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x02), buf[0]);
}

test "saturating arithmetic in resize actions — bug #94" {
    // Verify +| saturates instead of panicking on overflow
    const max: u32 = std.math.maxInt(u32);
    try testing.expectEqual(max, max +| 1);
    try testing.expectEqual(@as(u32, 42), @as(u32, 41) +| 1);
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
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
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

    // 3. Test legacy (non-SGR) mouse forwarding. Disable SGR, enable only basic mouse.
    pane.screen.mode.mouse_sgr = false;
    pane.screen.mode.mouse_standard = true;

    // Feed left-click SGR sequence from terminal (szn always receives SGR from outer terminal).
    try server.processInput("\x1b[<0;10;5M");
    try server.processInput("\n");

    // Verify legacy format forwarded: \x1b[M + btn+32 + local_x+33 + local_y+33.
    // SGR x=10 → m.x=9, y=5 → m.y=4. Single pane bounds: x=0,y=0. local_x=9, local_y=4.
    // btn=0 (left)+32=32(space), 9+33=42('*'), 4+33=37('%').
    n = std.posix.read(fd, &buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expect(n > 0);
    try testing.expectEqualStrings("\x1b[M *%\n", buf[0..n]);
}

test "mouse SGR left-click forwarded when program enables 1006+1000" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;
    pane.pty = try @import("pty.zig").Pty.open();

    const fd = pane.pty.?.slave;
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    _ = c_fcntl(fd, 3, @as(c_int, 0));
    _ = c_fcntl(fd, 4, c_fcntl(fd, 3, @as(c_int, 0)) | 0x0004);

    try s.options.set("mouse", .{ .flag = true });

    // Simulate what htop/ncurses sends with TERM=xterm-256color on ncurses 6:
    // \x1b[?1006;1000h  — enables SGR mouse (1006) + basic mouse (1000)
    const parser = pane.getParser();
    try parser.feed("\x1b[?1006;1000h");
    try testing.expect(pane.screen.mode.mouse_sgr);
    try testing.expect(pane.screen.mode.mouse_standard);

    // Simulate left-click at screen (9, 4) — SGR from outer terminal.
    try server.processInput("\x1b[<0;10;5M");
    try server.processInput("\n");

    var buf: [128]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    // Should forward SGR format since mouse_sgr is true.
    // local_x=9, local_y=4 → SGR coords (10, 5).
    try testing.expect(n > 0);
    try testing.expectEqualStrings("\x1b[<0;10;5M\n", buf[0..n]);
}

test "clock mode mouse click exits clock and consumes SGR sequence" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;
    pane.pty = try @import("pty.zig").Pty.open();

    const fd = pane.pty.?.slave;
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
    const flags = c_fcntl(fd, F_GETFL, @as(c_int, 0));
    _ = c_fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    try s.options.set("mouse", .{ .flag = true });

    pane.screen.clock_mode = true;
    pane.saved_grid = try pane.screen.grid.clone(pane.screen.grid.allocator);

    try server.processInput("\x1b[<0;10;5M");

    try testing.expect(!pane.screen.clock_mode);

    var buf: [128]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expectEqual(@as(usize, 0), n);
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

test "destroyPane deinitializes the last pane of a window" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    // Create a session with two windows so the session remains alive
    const s = try server.newSession("test", 80, 24);
    const w1 = s.active_window.?;
    const pane1 = w1.active_pane.?;
    _ = try s.newWindow(testing.allocator, "another");

    // Destroy the only pane of the first window
    server.destroyPane(pane1);

    // Pane should be deinitialized
    try testing.expect(pane1.deinited);
}

test "destroyPane removes pty fd from event loop — bug #178" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const window = s.active_window.?;
    const pane = window.active_pane.?;

    // Give the pane a real pty and register it in the event loop
    const pty = try pty_mod.Pty.open();
    pane.pty = pty;
    try server.watchPanePty(pane);

    // Verify the fd is registered
    const fd = pty.master;
    {
        var found = false;
        for (server.loop.fds.items) |f| {
            if (f.fd == fd) found = true;
        }
        try testing.expect(found);
    }

    // Destroy the pane — should also remove the fd
    server.destroyPane(pane);

    // Verify the fd was removed from the loop
    {
        var found = false;
        for (server.loop.fds.items) |f| {
            if (f.fd == fd) found = true;
        }
        try testing.expect(!found);
    }
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

    const result = server.handlePtyEvent(ev);
    try testing.expect(result == .handled);
}

test "handleMouseFocus handles long session name without panic — bug #180" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var long_name: [300]u8 = undefined;
    @memset(&long_name, 'a');
    const s = try server.newSession(&long_name, 80, 24);

    // Call handleMouseFocus at the status bar row. This exercises the
    // @intCast(session.name.len) path. Should not panic regardless of name length.
    try server.handleMouseFocus(0, s.height);
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

test "findPaneAtNode accounts for border width — bug #127" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test", 80, 24);
    const win = s.active_window.?;
    const pane1 = win.active_pane.?;

    // Split horizontally: pane1 (left, 39 cols) + border (1 col) + pane2 (right, 40 cols)
    const pane2 = try win.splitPane(testing.allocator, pane1, false, 0.5);

    // Click on left pane (col 0)
    const found1 = server.findPaneAtNode(win.layout.root, 0, 0, 0, 0, 80, 24);
    try testing.expect(found1 == pane1);

    // Click on right pane (col 50)
    const found2 = server.findPaneAtNode(win.layout.root, 50, 0, 0, 0, 80, 24);
    try testing.expect(found2 == pane2);

    // Click on the border column (col 39) — should return null
    const border = server.findPaneAtNode(win.layout.root, 39, 0, 0, 0, 80, 24);
    try testing.expect(border == null);
}

test "killSession preserves active session — bug #133" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    _ = try server.newSession("first", 80, 24);
    _ = try server.newSession("second", 80, 24);
    try testing.expectEqualStrings("first", server.activeSession().?.name);

    // killSession with orderedRemove preserves session[0]
    try server.killSession("first");
    try testing.expect(server.sessions.items.len == 1);
    try testing.expectEqualStrings("second", server.activeSession().?.name);
}

test "command prompt keys validation" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    _ = try server.newSession("test", 80, 24);

    // Put server in command mode
    server.command_mode = true;
    server.command_buf.clearRetainingCapacity();

    // Simulate typing "abc"
    try server.processInput("a");
    try server.processInput("b");
    try server.processInput("c");
    try testing.expectEqualStrings("abc", server.command_buf.items);

    // Feed backspace (0x7f)
    try server.processInput("\x7f");
    try testing.expectEqualStrings("ab", server.command_buf.items);

    // Feed Control-H (0x08)
    try server.processInput("\x08");
    try testing.expectEqualStrings("a", server.command_buf.items);

    // Feed 'x' -> command becomes "ax"
    try server.processInput("x");
    try testing.expectEqualStrings("ax", server.command_buf.items);

    // Feed Escape (0x1b) twice to cancel command mode
    try server.processInput("\x1b");
    try server.processInput("\x1b");
    try testing.expect(!server.command_mode);
    try testing.expectEqual(@as(usize, 0), server.command_buf.items.len);

    // Try again and cancel with Ctrl-C (0x03)
    server.command_mode = true;
    try server.processInput("abc");
    try server.processInput("\x03");
    try testing.expect(!server.command_mode);
    try testing.expectEqual(@as(usize, 0), server.command_buf.items.len);

    // Try again and submit with Enter (\r)
    server.command_mode = true;
    try server.processInput("nonexistentcommand");
    try server.processInput("\r");
    try testing.expect(!server.command_mode);
    try testing.expectEqual(@as(usize, 0), server.command_buf.items.len);
}

test "command prompt tab completion" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-completion", 80, 24);
    const win = s.active_window.?;
    const pane = win.active_pane.?;
    pane.pty = try @import("pty.zig").Pty.open();

    // 1. Single match completion
    server.command_mode = true;
    try server.processInput("clock-mo");
    try testing.expectEqualStrings("clock-mo", server.command_buf.items);

    // Send Tab
    try server.processInput("\x09");
    try testing.expectEqualStrings("clock-mode ", server.command_buf.items);
    try testing.expect(server.command_mode);

    // 2. Multiple match completion
    server.command_buf.clearRetainingCapacity();
    try server.processInput("se");
    try testing.expectEqualStrings("se", server.command_buf.items);

    // Send Tab
    try server.processInput("\x09");
    // Should deactivate command mode temporarily and activate choose mode
    try testing.expect(!server.command_mode);
    try testing.expect(pane.choose_mode.active);
    try testing.expectEqual(pane.choose_mode.target, .command);
    try testing.expect(pane.choose_mode.items.items.len > 1);

    // 3. Cancel completion selection
    // Send 'q' to cancel choose mode
    try server.processInput("q");
    try testing.expect(!pane.choose_mode.active);
    // Command mode should be active again
    try testing.expect(server.command_mode);
    try testing.expectEqualStrings("se", server.command_buf.items);
}

test "multiple display clients attached simultaneously" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    // Create client A socketpair
    var fds_a: [2]i32 = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds_a) != 0) return error.Unexpected;
    const server_a = fds_a[0];
    const client_a = fds_a[1];
    defer _ = std.c.close(server_a);
    defer _ = std.c.close(client_a);

    // Create client B socketpair
    var fds_b: [2]i32 = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds_b) != 0) return error.Unexpected;
    const server_b = fds_b[0];
    const client_b = fds_b[1];
    defer _ = std.c.close(server_b);
    defer _ = std.c.close(client_b);

    // Set up message readers for both
    const reader_a = try testing.allocator.create(MessageReader);
    reader_a.* = .{};
    try server.client_readers.put(server_a, reader_a);
    try server.client_fds.append(server.allocator, server_a);
    defer {
        if (server.client_readers.fetchRemove(server_a)) |entry| {
            testing.allocator.destroy(entry.value);
        }
    }

    const reader_b = try testing.allocator.create(MessageReader);
    reader_b.* = .{};
    try server.client_readers.put(server_b, reader_b);
    try server.client_fds.append(server.allocator, server_b);
    defer {
        if (server.client_readers.fetchRemove(server_b)) |entry| {
            testing.allocator.destroy(entry.value);
        }
    }

    // 1. Identify Client A as a display client
    const identify_a = protocol.Packet.make(.identify_term, "xterm-256color");
    var id_buf_a: [128]u8 = undefined;
    const id_ser_a = identify_a.serialize(&id_buf_a);
    _ = std.c.write(client_a, id_ser_a.ptr, id_ser_a.len);

    try server.handleClient(server_a);
    try testing.expectEqual(@as(usize, 1), server.display_clients.items.len);
    try testing.expectEqual(server_a, server.display_clients.items[0].fd);

    // Read the reply "ok" from client A end
    var reply_buf_a: [128]u8 = undefined;
    _ = std.c.read(client_a, &reply_buf_a, reply_buf_a.len);

    // 2. Identify Client B as another display client
    const identify_b = protocol.Packet.make(.identify_term, "xterm-256color");
    var id_buf_b: [128]u8 = undefined;
    const id_ser_b = identify_b.serialize(&id_buf_b);
    _ = std.c.write(client_b, id_ser_b.ptr, id_ser_b.len);

    try server.handleClient(server_b);
    try testing.expectEqual(@as(usize, 2), server.display_clients.items.len);
    // Both should still be attached!
    try testing.expect(server.display_clients.items[0].fd == server_a or server.display_clients.items[1].fd == server_a);
    try testing.expect(server.display_clients.items[0].fd == server_b or server.display_clients.items[1].fd == server_b);

    // Read the reply "ok" from client B end
    var reply_buf_b: [128]u8 = undefined;
    _ = std.c.read(client_b, &reply_buf_b, reply_buf_b.len);

    // Verify Client A did NOT receive any detach packet
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: i32, cmd: i32, ...) i32;
    }.fcntl;
    const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
        .macos, .ios, .watchos, .tvos => 0x0004,
        .freebsd, .netbsd, .openbsd, .dragonfly => 0x0004,
        else => 0x0800, // Linux
    };
    const flags = c_fcntl(client_a, 3, @as(i32, 0));
    _ = c_fcntl(client_a, 4, flags | O_NONBLOCK);

    var temp_buf: [128]u8 = undefined;
    const read_res = std.c.read(client_a, &temp_buf, temp_buf.len);
    try testing.expect(read_res < 0);
    try testing.expect(std.c.errno(read_res) == .AGAIN);
}

test "mouse click and drag selection" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-mouse-selection", 80, 24);
    const win = s.active_window.?;
    const pane = win.active_pane.?;

    try testing.expect(pane.screen.copy_mode == null);

    try server.processInput("\x1b[<0;11;6M");

    try testing.expect(pane.screen.copy_mode == null);

    try server.processInput("\x1b[<32;21;6M");

    try testing.expect(pane.screen.copy_mode != null);
    const cm = &pane.screen.copy_mode.?;
    try testing.expect(cm.selection.active);
    try testing.expectEqual(@as(u32, 10), cm.selection.start_x);
    try testing.expectEqual(@as(u32, 5), cm.selection.start_y);
    try testing.expectEqual(@as(u32, 20), cm.selection.end_x);
    try testing.expectEqual(@as(u32, 5), cm.selection.end_y);

    for (10..21) |x| {
        pane.screen.grid.getLine(5).cells.items[x].char = 'x';
    }

    try server.processInput("\x1b[<3;21;6m");

    try testing.expect(pane.screen.copy_mode == null);

    const pb = server.buffers.get(null);
    try testing.expect(pb != null);
    try testing.expectEqualStrings("xxxxxxxxxxx", pb.?);
}

test "mouse selection from inactive pane focus and drag" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-mouse-selection-inactive", 80, 24);
    const win = s.active_window.?;
    const pane1 = win.active_pane.?;

    const pane2 = try win.splitPane(server.allocator, pane1, false, 0.5);

    win.setActivePane(pane1);
    try testing.expectEqual(pane1, win.active_pane.?);

    try testing.expect(pane2.screen.copy_mode == null);

    try server.processInput("\x1b[<0;51;6M");

    try testing.expectEqual(pane2, win.active_pane.?);
    try testing.expect(pane2.screen.copy_mode == null);

    try server.processInput("\x1b[<32;61;6M");

    try testing.expect(pane2.screen.copy_mode != null);
    const cm = &pane2.screen.copy_mode.?;
    try testing.expect(cm.selection.active);

    try testing.expectEqual(@as(u32, 10), cm.selection.start_x);
    try testing.expectEqual(@as(u32, 5), cm.selection.start_y);
    try testing.expectEqual(@as(u32, 20), cm.selection.end_x);
    try testing.expectEqual(@as(u32, 5), cm.selection.end_y);

    for (10..21) |x| {
        pane2.screen.grid.getLine(5).cells.items[x].char = 'x';
    }

    try server.processInput("\x1b[<3;61;6m");

    try testing.expect(pane2.screen.copy_mode == null);

    const pb = server.buffers.get(null);
    try testing.expect(pb != null);
    try testing.expectEqualStrings("xxxxxxxxxxx", pb.?);
}

test "mouse hover scroll focus and scroll" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-mouse-scroll-focus", 80, 24);
    const win = s.active_window.?;
    const pane1 = win.active_pane.?;

    const pane2 = try win.splitPane(server.allocator, pane1, false, 0.5);

    win.setActivePane(pane1);
    try testing.expectEqual(pane1, win.active_pane.?);

    try testing.expect(pane2.screen.copy_mode == null);

    // Scroll up over pane2 at (50, 5) -> SGR button 64, coordinates (51, 6) -> \x1b[<64;51;6M
    try server.processInput("\x1b[<64;51;6M");

    // pane2 should be active now!
    try testing.expectEqual(pane2, win.active_pane.?);
    try testing.expect(pane2.screen.copy_mode != null);

    // Scroll down over pane2 at (50, 5) -> SGR button 65 -> \x1b[<65;51;6M
    try testing.expectEqual(@as(u32, 0), pane2.screen.copy_mode.?.scroll_offset);
    try server.processInput("\x1b[<65;51;6M");

    // Copy mode should be null now
    try testing.expect(pane2.screen.copy_mode == null);
}

test "OSC 52 clipboard forwarding and buffer copy" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-osc52", 80, 24);
    const win = s.active_window.?;
    const pane = win.active_pane.?;

    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.LOCAL, std.posix.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    const client_fd = fds[0];
    const server_fd = fds[1];
    defer _ = std.c.close(client_fd);
    defer _ = std.c.close(server_fd);

    try server.display_clients.append(server.allocator, .{ .fd = server_fd });
    defer {
        for (server.display_clients.items, 0..) |*dc, idx| {
            if (dc.fd == server_fd) {
                dc.deinit(server.allocator);
                _ = server.display_clients.swapRemove(idx);
                break;
            }
        }
    }

    const parser = pane.getParser();
    parser.clipboard_cb = Server.paneClipboardCallback;
    parser.clipboard_ctx = &server;

    // Feed "hello" in base64: "aGVsbG8="
    try parser.feed("\x1b]52;c;aGVsbG8=\x07");

    // 1. Verify paste buffer has it
    const pb = server.buffers.get(null);
    try testing.expect(pb != null);
    try testing.expectEqualStrings("hello", pb.?);

    // 2. Verify display client received the raw sequence
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: i32, cmd: i32, ...) i32;
    }.fcntl;
    const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
        .macos, .ios, .watchos, .tvos => 0x0004,
        .freebsd, .netbsd, .openbsd, .dragonfly => 0x0004,
        else => 0x0800, // Linux
    };
    const flags = c_fcntl(client_fd, 3, @as(i32, 0));
    _ = c_fcntl(client_fd, 4, flags | O_NONBLOCK);

    var temp_buf: [128]u8 = undefined;
    const read_res = std.c.read(client_fd, &temp_buf, temp_buf.len);
    const received = temp_buf[0..@intCast(read_res)];
    try testing.expect(std.mem.indexOf(u8, received, "\x1b]52;c;aGVsbG8=\x07") != null);
}

test "mouse drag event forwarding" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const s = try server.newSession("test-mouse-drag", 80, 24);
    const win = s.active_window.?;
    const pane = win.active_pane.?;

    try s.options.set("mouse", .{ .flag = true });

    pane.pty = try @import("pty.zig").Pty.open();
    defer {
        if (pane.pty) |*pty| {
            pty.deinit();
            pane.pty = null;
        }
    }

    pane.screen.mode.mouse_sgr = true;

    const fd = pane.pty.?.slave;
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
    const flags = c_fcntl(fd, F_GETFL, @as(c_int, 0));
    _ = c_fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    try server.processInput("\x1b[<32;16;9M");
    try server.processInput("\n");

    var temp_buf: [128]u8 = undefined;
    const n = std.posix.read(fd, &temp_buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0) else return err;
    };
    try testing.expect(n > 0);
    const received = temp_buf[0..n];
    try testing.expect(std.mem.indexOf(u8, received, "[<32;16;9M") != null);
}

test "wire protocol attaches clients only to global active session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    // Verify initially activeSession is null
    try testing.expect(server.activeSession() == null);

    // Create a session
    const s1 = try server.newSession("session1", 80, 24);
    // Retrieve the active session
    const active = server.activeSession().?;
    try testing.expectEqualStrings("session1", active.name);
    try testing.expectEqual(s1, active);

    // Even if another session is created, the active session remains the first one (global active)
    const s2 = try server.newSession("session2", 80, 24);
    _ = s2;
    try testing.expectEqual(active, server.activeSession().?);
}

test "server handleClient handles unknown message types gracefully" {
    var server = try Server.init(testing.allocator);
    server.ignore_unknown_msg_warn = true;
    defer server.deinit();

    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.Unexpected;
    const server_fd = fds[0];
    const client_fd = fds[1];
    defer _ = std.c.close(server_fd);
    defer _ = std.c.close(client_fd);

    const reader = try testing.allocator.create(MessageReader);
    reader.* = .{};
    try server.client_readers.put(server_fd, reader);
    try server.client_fds.append(server.allocator, server_fd);
    defer {
        if (server.client_readers.fetchRemove(server_fd)) |entry| {
            testing.allocator.destroy(entry.value);
        }
    }

    // Write a packet with invalid message type byte (0xFF)
    var pkt_buf = [_]u8{ 0x05, 0x00, 0x00, 0x00, 0xFF };
    const n = std.c.write(client_fd, &pkt_buf, pkt_buf.len);
    try testing.expectEqual(@as(isize, 5), n);

    // Call handleClient: it should not fail/return error, it should log and ignore
    try server.handleClient(server_fd);
}
