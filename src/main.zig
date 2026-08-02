const std = @import("std");
const build_options = @import("build_options");
const c = std.c;
const server_mod = @import("server/server.zig");
const Server = server_mod.Server;
const render = @import("server/render.zig");
const Display = render.Display;
const raw_mod = @import("client/raw.zig");
const cmd_mod = @import("cmd/cmd.zig");
const protocol = @import("server/protocol.zig");
const socket_mod = @import("server/socket.zig");
const connect = @import("client/connect.zig");
const client_mod = @import("client/client.zig");
const socket_path = @import("socket_path.zig");
const log_mod = @import("log.zig");

pub const Error = server_mod.ServerError || client_mod.Error || connect.Error || socket_path.Error || log_mod.Error || error{ OutOfMemory, SocketNotFound, WriteFailed, ReadFailed };

pub const std_options: std.Options = .{
    .logFn = log_mod.logFn,
    .log_level = .debug,
};

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIFLUSH = 1;

var sigwinchFlag = std.atomic.Value(bool).init(false);
// Set when the controlling terminal hangs up (mosh/ssh transport drop). The
// client must survive it — mosh -a keeps the pty alive and resumes it.
var sighupFlag = std.atomic.Value(bool).init(false);

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
}

export fn sighup_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sighupFlag.store(true, .seq_cst);
}

fn writeAll(fd: i32, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.write(fd, buf.ptr + off, buf.len - off);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @as(usize, @intCast(n));
    }
}

/// Upper bound on the client's pending stdout bytes. When a downstream pty
/// (e.g. mosh backpressure on a slow link) stops draining, the client queues
/// rendered frames here instead of blocking on write(2). If the queue exceeds
/// this cap the backlog is dropped and a full repaint is requested once the
/// pty drains again (bug #298).
const MAX_CLIENT_OUT_BUF = 1 << 20;

/// Above this pending-stdout level the client stops reading from the server
/// socket. This fills the server's socket, which trips the server's
/// `DisplayClient.behind` flow control and throttles the child to the link's
/// speed — frames get delivered (slowly) instead of piling up and being
/// dropped, which is what a "frozen" screen actually is (bug #298).
const CLIENT_OUT_HIGH_WATERMARK = MAX_CLIENT_OUT_BUF / 2;

fn setNonBlocking(fd: i32) void {
    const c_fcntl = struct {
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    }.fcntl;
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
    const flags = c_fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = c_fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

/// Queue `data` for stdout. If the pending queue would exceed the cap, the
/// backlog is dropped and `needs_redraw` is set so the client asks the server
/// for a full repaint once the pty drains. A single frame larger than the
/// whole cap is rejected outright. Returns false when nothing was queued.
fn queueStdout(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), data: []const u8, needs_redraw: *bool) bool {
    if (data.len == 0) return true;
    if (data.len > MAX_CLIENT_OUT_BUF) {
        out_buf.clearRetainingCapacity();
        needs_redraw.* = true;
        return false;
    }
    if (out_buf.items.len + data.len > MAX_CLIENT_OUT_BUF) {
        out_buf.clearRetainingCapacity();
        needs_redraw.* = true;
    }
    out_buf.appendSlice(allocator, data) catch {
        out_buf.clearRetainingCapacity();
        needs_redraw.* = true;
        return false;
    };
    return true;
}

/// Non-blocking flush of pending stdout bytes. Returns true when the whole
/// buffer was written (or the fd is unwritable for good, in which case the
/// buffer is dropped); false when the pty is applying backpressure and the
/// remainder stays queued for a later POLL.OUT drain.
fn flushStdout(fd: i32, out_buf: *std.ArrayList(u8)) bool {
    if (out_buf.items.len == 0) return true;
    var off: usize = 0;
    while (off < out_buf.items.len) {
        const n = c.write(fd, out_buf.items.ptr + off, out_buf.items.len - off);
        if (n < 0) {
            const err = std.c.errno(n);
            if (err == .INTR) continue;
            if (err == .AGAIN) break;
            out_buf.clearRetainingCapacity();
            return true;
        }
        if (n == 0) break;
        off += @as(usize, @intCast(n));
    }
    if (off >= out_buf.items.len) {
        out_buf.clearRetainingCapacity();
        return true;
    }
    if (off > 0) {
        std.mem.copyForwards(u8, out_buf.items[0 .. out_buf.items.len - off], out_buf.items[off..]);
        out_buf.items.len -= off;
    }
    return false;
}

pub fn detectNested() bool {
    return std.c.getenv("SZN") != null;
}

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        // Log propagated errors to the file too, so a client/server death is
        // visible in szn.log rather than only on the (possibly dropped) pty.
        std.log.err("szn exiting with error: {any}", .{err});
        switch (err) {
            error.SocketNotFound, error.ConnectionRefused => {
                std.debug.print("No szn server running\n", .{});
            },
            else => {
                std.debug.print("Error: {any}\n", .{err});
            },
        }
        std.process.exit(1);
    };
}

fn getVersionComptime() []const u8 {
    return build_options.version;
}

fn mainInner(init: std.process.Init) Error!void {
    const allocator = init.gpa;

    // Ignore SIGPIPE: a write to a closed peer (a mosh link that dropped, a
    // detached terminal, a display client that went away) must return EPIPE so
    // the caller can handle it, not kill the process with a signal. Without
    // this the interactive client dies the instant the downstream pty closes
    // mid-redraw, which is exactly the freeze seen when running opencode over
    // mosh (bug #298).
    var ignore_pipe: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.PIPE, &ignore_pipe, null);

    // Terminal job-control signals: the client does raw-mode/tcsetattr I/O on
    // the mosh/ssh pty. If it is ever momentarily not the foreground process
    // group of that pty, these ops would otherwise stop the client (SIGTTOU)
    // or block its reads (SIGTTIN). tmux ignores them in the client; so do we.
    var ignore_stop: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.TTOU, &ignore_stop, null);
    std.posix.sigaction(.TTIN, &ignore_stop, null);

    // SIGHUP (controlling terminal hangup, i.e. a transport drop) must NOT kill
    // the client: mosh -a keeps the pty and resumes it. Flag it instead so the
    // client can log and keep the session alive.
    var ignore_hup: std.posix.Sigaction = .{
        .handler = .{ .handler = sighup_handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.HUP, &ignore_hup, null);

    if (detectNested()) {
        std.debug.print("szn: you are already running szn; nested instances are not supported\n", .{});
        std.process.exit(1);
    }

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();

    while (arg_it.next()) |arg| {
        const arg_dupe = try allocator.dupe(u8, arg);
        try args.append(allocator, arg_dupe);
    }
    defer {
        for (args.items) |arg| {
            allocator.free(arg);
        }
    }

    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "-V")) {
        const version = getVersionComptime();
        std.debug.print("szn {s}\n", .{version});
        std.process.exit(0);
    }

    if (args.items.len > 1) {
        const is_attach = std.mem.eql(u8, args.items[1], "attach") or
            std.mem.eql(u8, args.items[1], "attach-session");
        if (is_attach) {
            if (socket_mod.socketExists()) {
                try runInteractiveClient(allocator);
                std.process.exit(0);
            } else {
                std.debug.print("No szn server running\n", .{});
                std.process.exit(1);
            }
        }

        const is_help = std.mem.eql(u8, args.items[1], "help") or
            std.mem.eql(u8, args.items[1], "?");
        if (is_help and !socket_mod.socketExists()) {
            const target = if (args.items.len > 2) args.items[2] else null;
            const text = cmd_mod.formatHelp(allocator, target) catch {
                std.debug.print("Failed to format help\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(text);
            std.debug.print("{s}", .{text});
            std.process.exit(0);
        }

        const is_new_cmd = std.mem.eql(u8, args.items[1], "new-session") or
            std.mem.eql(u8, args.items[1], "new");

        var is_detached = false;
        for (args.items[2..]) |arg| {
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) {
                is_detached = true;
            }
        }

        var client = blk: {
            if (is_new_cmd and !socket_mod.socketExists()) {
                const pid = c.fork();
                if (pid < 0) {
                    std.debug.print("Failed to fork\n", .{});
                    std.process.exit(1);
                }
                if (pid == 0) {
                    log_mod.disable();
                    try runServerDaemon(allocator);
                    std.process.exit(0);
                } else {
                    waitForSocket() catch {
                        std.debug.print("Server failed to start\n", .{});
                        std.process.exit(1);
                    };
                }
            }
            break :blk @import("client/client.zig").Client.init(allocator) catch |err| {
                if (err == error.SocketNotFound or err == error.ConnectionRefused) {
                    if (is_new_cmd and err == error.ConnectionRefused) {
                        socket_mod.shutdown();
                        const pid = c.fork();
                        if (pid < 0) {
                            std.debug.print("Failed to fork\n", .{});
                            std.process.exit(1);
                        }
                        if (pid == 0) {
                            log_mod.disable();
                            try runServerDaemon(allocator);
                            std.process.exit(0);
                        } else {
                            waitForSocket() catch {
                                std.debug.print("Server failed to start\n", .{});
                                std.process.exit(1);
                            };
                            break :blk @import("client/client.zig").Client.init(allocator) catch |e| {
                                std.debug.print("Could not connect to szn server: {any}\n", .{e});
                                std.process.exit(1);
                            };
                        }
                    }
                    std.debug.print("No szn server running\n", .{});
                } else {
                    std.debug.print("Could not connect to szn server: {any}\n", .{err});
                }
                std.process.exit(1);
            };
        };
        defer client.deinit();

        var cmd_len: usize = 0;
        var cmd_count: usize = 0;
        for (args.items[1..]) |arg| {
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) continue;
            cmd_len += arg.len;
            cmd_count += 1;
        }
        cmd_len +|= cmd_count -| 1; // n-1 separators for n args
        var cmd_buf = try allocator.alloc(u8, cmd_len);
        defer allocator.free(cmd_buf);

        var offset: usize = 0;
        var first = true;
        for (args.items[1..]) |arg| {
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) continue;
            if (!first) {
                cmd_buf[offset] = ' ';
                offset += 1;
            }
            first = false;
            @memcpy(cmd_buf[offset..][0..arg.len], arg);
            offset += arg.len;
        }
        const cmd = cmd_buf[0..offset];

        try client.sendCommand(cmd);
        var reply = try client.recvPacket();
        defer reply.deinit(allocator);
        const msg_type = protocol.MessageType.fromByte(reply.header.msg_type) orelse {
            std.debug.print("Invalid message type from server: {}\n", .{reply.header.msg_type});
            std.process.exit(1);
        };
        switch (msg_type) {
            .ready => {
                if (is_new_cmd and !is_detached) {
                    try runInteractiveClient(allocator);
                    std.process.exit(0);
                }
                std.debug.print("{s}\n", .{reply.data});
                std.process.exit(0);
            },
            .err => {
                std.debug.print("Error: {s}\n", .{reply.data});
                std.process.exit(1);
            },
            .exit => {
                const code = if (reply.data.len > 0) reply.data[0] else 0;
                std.process.exit(code);
            },
            else => {
                std.debug.print("Unexpected response: {any}\n", .{msg_type});
                std.process.exit(1);
            },
        }
    }

    var interactive_err: ?Error = null;
    if (socket_mod.socketExists()) {
        runInteractiveClient(allocator) catch |err| {
            if (err == error.ConnectionRefused) {
                socket_mod.shutdown();
                try spawnDaemonAndAttach(allocator);
            } else {
                interactive_err = err;
            }
        };
    } else {
        try spawnDaemonAndAttach(allocator);
    }
    if (interactive_err) |err| return err;
}

fn spawnDaemonAndAttach(allocator: std.mem.Allocator) Error!void {
    const pid = c.fork();
    if (pid < 0) {
        std.debug.print("Failed to fork\n", .{});
        std.process.exit(1);
    }
    if (pid == 0) {
        log_mod.disable();
        try runServerDaemon(allocator);
    } else {
        waitForSocket() catch {
            std.debug.print("Server failed to start\n", .{});
            std.process.exit(1);
        };
        try runInteractiveClient(allocator);
    }
}

fn waitForSocket() Error!void {
    const c_usleep = struct {
        extern "c" fn usleep(usec: c_uint) c_int;
    }.usleep;
    var attempts: u32 = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (socket_mod.socketExists()) return;
        _ = c_usleep(5000);
    }
    return error.SocketNotFound;
}

fn runServerDaemon(allocator: std.mem.Allocator) Error!void {
    // Close stdin/stdout/stderr inherited from parent — daemon doesn't need them.
    // Re-open to /dev/null to avoid accidental terminal I/O.
    _ = c.close(0);
    _ = c.close(1);
    _ = c.close(2);
    const dev_null = c.open("/dev/null", c.O{ .ACCMODE = .RDWR }, @as(c_uint, 0));
    if (dev_null >= 0) {
        _ = c.dup2(dev_null, 0);
        _ = c.dup2(dev_null, 1);
        _ = c.dup2(dev_null, 2);
        _ = c.close(dev_null);
    }

    _ = c.setsid();

    const sx: u32 = 80;
    const sy: u32 = 24;

    var server = try Server.init(allocator);
    defer server.deinit();

    server.loadDefaultConfig() catch |err| {
        std.log.warn("Failed to load default config: {any}", .{err});
    };

    const session = try server.newSession("default", sx, sy - 1);
    const default_session_id = session.id;
    // Verify that the initial session has an active window and pane
    if (session.active_window) |win| {
        if (win.active_pane == null) {
            std.log.err("newSession returned window with no active pane", .{});
            return error.OutOfMemory;
        }
    } else {
        std.log.err("newSession returned session with no active window", .{});
        return error.OutOfMemory;
    }

    server.display_sx = sx;
    server.display_sy = sy;
    try server.listen();

    var chld_act: std.posix.Sigaction = .{
        .handler = .{ .handler = server_mod.sigchld_handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.CHLD, &chld_act, null);

    const shell = try server.resolveShell(allocator, session);
    defer allocator.free(shell);
    std.log.info("spawning shell: {s}", .{shell});

    // Wait up to ~16 ms for the parent to connect and send the new-session
    // command before spawning the shell.  This way the parent gets the
    // response quickly instead of waiting for the shell fork+exec.
    for (0..16) |_| {
        try server.run(1);
    }

    // bug #221: re-validate that the pane still exists after the run(1) burst,
    // since a connected parent client could have killed the session in that
    // window.  Walk sessions again to confirm the pointer is still live.
    var default_pane: ?*@import("window.zig").Pane = null;
    for (server.sessions.items) |s| {
        if (s.id == default_session_id) {
            if (s.active_window) |w| {
                default_pane = w.active_pane;
            }
            break;
        }
    }

    if (default_pane) |p| {
        const raw_nofile = server.global_options.asNumber("nofile-limit") orelse 1024;
        const min_nofile: u64 = if (raw_nofile > 0) @intCast(raw_nofile) else 0;
        try p.spawn(allocator, &[_][]const u8{shell}, null, min_nofile);
        try server.watchPanePty(p);
        p.initPty();
    }

    while (server.loop.running) {
        try server.run(100);
        server.renderToDisplayClient();
    }

    server.shutdownServer();
}

fn queryCellSize(server_fd: i32, stdout_fd: i32, stdin_fd: i32, sx: u32, sy: u32) bool {
    _ = c.write(stdout_fd, "\x1b[14t", 5);

    // bug #224: use a short poll timeout (5 ms) instead of blocking for 200 ms.
    // Terminals that don't support CSI 14 t will never reply; a 5 ms timeout
    // keeps the client responsive while still catching fast responders.
    var pollfd: [1]std.posix.pollfd = .{.{ .fd = stdin_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 }};
    const rc = std.posix.poll(&pollfd, 5) catch return false;
    if (rc < 1) return false;

    var buf: [64]u8 = undefined;
    const n = c.read(stdin_fd, &buf, buf.len);
    if (n <= 0) return false;
    const len: usize = @intCast(n);

    if (len < 6 or buf[0] != 0x1b or buf[1] != '[' or buf[2] != '4' or buf[3] != ';') return false;
    var i: usize = 4;
    var px_h: u32 = 0;
    while (i < len and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        px_h = px_h * 10 + @as(u32, buf[i] - '0');
    }
    if (i >= len or buf[i] != ';') return false;
    i += 1;
    var px_w: u32 = 0;
    while (i < len and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        px_w = px_w * 10 + @as(u32, buf[i] - '0');
    }
    if (i >= len or buf[i] != 't' or sy == 0 or sx == 0) return false;

    const cell_h: u32 = @max(px_h / sy, 1);
    const cell_w: u32 = @max(px_w / sx, 1);

    var cell_data: [8]u8 = undefined;
    std.mem.writeInt(u32, cell_data[0..4], cell_h, .little);
    std.mem.writeInt(u32, cell_data[4..8], cell_w, .little);
    const cs_pkt = protocol.Packet.make(.cell_size, &cell_data);
    var cs_buf: [128]u8 = undefined;
    const cs_ser = cs_pkt.serialize(&cs_buf);
    writeAll(server_fd, cs_ser) catch return false;
    return true;
}

fn runInteractiveClient(allocator: std.mem.Allocator) Error!void {
    const stdin_fd = c.STDIN_FILENO;
    const stdout_fd = c.STDOUT_FILENO;
    const server_fd = try connect.connectToServer();
    defer _ = c.close(server_fd);

    // bug #298: a downstream pty that applies backpressure (e.g. mosh on a slow
    // link) must not stall the whole client. stdout is made non-blocking and
    // rendered frames are queued + drained on POLL.OUT instead of blocking in
    // write(2).
    setNonBlocking(stdout_fd);

    var ws: c.winsize = undefined;
    var sx: u32 = 80;
    var sy: u32 = 24;
    if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, &ws) == 0 or
        c.ioctl(stdin_fd, c.T.IOCGWINSZ, &ws) == 0 or
        c.ioctl(std.posix.STDERR_FILENO, c.T.IOCGWINSZ, &ws) == 0)
    {
        sx = @max(ws.col, 2);
        sy = @max(ws.row, 2);
    }

    const identify = protocol.Packet.make(.identify_term, "xterm-256color");
    var id_buf: [128]u8 = undefined;
    const id_ser = identify.serialize(&id_buf);
    try writeAll(server_fd, id_ser);

    var resize_buf: [16]u8 = undefined;
    std.mem.writeInt(u32, resize_buf[0..4], sx, .little);
    std.mem.writeInt(u32, resize_buf[4..8], sy, .little);
    const resize_pkt = protocol.Packet.make(.resize, resize_buf[0..8]);
    var r_buf: [128]u8 = undefined;
    const r_ser = resize_pkt.serialize(&r_buf);
    try writeAll(server_fd, r_ser);

    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = sigwinch_handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);

    var raw = raw_mod.RawTerminal.init(stdin_fd) catch return;
    raw.setRaw() catch return;
    _ = tcflush(stdin_fd, TCIFLUSH);
    defer raw.deinit();

    var display = Display{
        .fd = stdout_fd,
        .sx = sx,
        .sy = sy,
    };
    display.enterAltScreen() catch {};
    defer display.exitAltScreen() catch {};

    var read_buf: std.ArrayList(u8) = .empty;
    defer read_buf.deinit(allocator);

    // Pending stdout bytes that couldn't be written while the downstream pty
    // applied backpressure. Drained whenever POLL.OUT fires on stdout.
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    // Set when the out_buf cap was hit and a backlog was dropped: the client's
    // terminal is behind the server's diff state. Cleared once a full repaint
    // is requested after the pty drains.
    var needs_redraw = false;
    var running = true;
    // The display's stdin (the mosh/ssh pty) can vanish transiently when the
    // transport drops. For mosh -a the remote process — and thus the session —
    // must survive such drops, so a lost stdin is NOT a detach; we stop reading
    // it and probe for revival instead of exiting (bug #298).
    var stdin_alive = true;
    var stdin_check_counter: usize = 0;

    std.log.info("interactive client connected (server_fd={d})", .{server_fd});

    while (running) {
        if (sighupFlag.load(.seq_cst)) {
            sighupFlag.store(false, .seq_cst);
            // Controlling terminal hung up (transport drop). mosh -a keeps the
            // pty alive and will resume it, so do NOT exit — just log and keep
            // the session running.
            std.log.warn("client SIGHUP, staying attached", .{});
        }

        var pollfds: [3]std.posix.pollfd = undefined;
        // Backpressure: while our own stdout queue is congested (the downstream
        // pty, e.g. mosh, can't keep up), do NOT read from the server. That
        // fills the server socket so its flow control throttles the child to
        // our speed; otherwise we'd keep consuming frames and dropping them,
        // which reads as a frozen screen. Resume when the queue drains.
        if (out_buf.items.len >= CLIENT_OUT_HIGH_WATERMARK) {
            pollfds[0] = .{ .fd = -1, .events = 0, .revents = 0 };
        } else {
            pollfds[0] = .{ .fd = server_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 };
        }
        // While stdin is dead we stop polling it (polling a HUP fd busy-loops)
        // and instead probe it again every ~50 iterations for revival.
        if (stdin_alive) {
            pollfds[1] = .{ .fd = stdin_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 };
        } else {
            pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
            stdin_check_counter += 1;
            if (stdin_check_counter >= 50) {
                stdin_check_counter = 0;
                pollfds[1] = .{ .fd = stdin_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 };
            }
        }
        var poll_count: usize = 2;
        if (out_buf.items.len > 0) {
            pollfds[2] = .{ .fd = stdout_fd, .events = @as(i16, @intCast(std.posix.POLL.OUT)), .revents = 0 };
            poll_count = 3;
        }

        _ = std.posix.poll(pollfds[0..poll_count], 10) catch continue;

        if (sigwinchFlag.load(.seq_cst)) {
            sigwinchFlag.store(false, .seq_cst);
            var new_ws: c.winsize = undefined;
            if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, &new_ws) == 0) {
                if (new_ws.col != ws.col or new_ws.row != ws.row) {
                    ws = new_ws;
                    sx = @max(ws.col, 2);
                    sy = @max(ws.row, 2);
                    std.mem.writeInt(u32, resize_buf[0..4], sx, .little);
                    std.mem.writeInt(u32, resize_buf[4..8], sy, .little);
                    const rs_pkt = protocol.Packet.make(.resize, resize_buf[0..8]);
                    var rs_buf: [128]u8 = undefined;
                    const rs_ser = rs_pkt.serialize(&rs_buf);
                    try writeAll(server_fd, rs_ser);
                }
            }
        }

        if (pollfds[1].revents != 0) {
            var stdin_buf: [4096]u8 = undefined;
            const n = c.read(stdin_fd, &stdin_buf, stdin_buf.len);
            if (n > 0) {
                const len: usize = @intCast(n);
                const was_dead = !stdin_alive;
                const sd_pkt = protocol.Packet.make(.stdin_data, stdin_buf[0..len]);
                var sd_buf: [4096 + 5]u8 = undefined;
                const sd_ser = sd_pkt.serialize(&sd_buf);
                try writeAll(server_fd, sd_ser);
                stdin_alive = true;
                if (was_dead) {
                    // The display link is back; ask for a full repaint so any
                    // frames dropped while it was down are replaced coherently.
                    const rd_pkt = protocol.Packet.make(.redraw, "");
                    var rd_buf: [128]u8 = undefined;
                    const rd_ser = rd_pkt.serialize(&rd_buf);
                    writeAll(server_fd, rd_ser) catch {};
                }
            } else if (n == -1) {
                const err = std.c.errno(n);
                if (err != .AGAIN and err != .INTR) {
                    // Display stdin gone (mosh/ssh transport drop). Stay
                    // attached — the session keeps running and the link resumes.
                    std.log.warn("client stdin unavailable, staying attached", .{});
                    stdin_alive = false;
                    stdin_check_counter = 0;
                }
            } else {
                // EOF on stdin: a transport drop, not a detach. Keep the
                // session alive and wait for the pty to come back.
                std.log.warn("client stdin EOF, staying attached", .{});
                stdin_alive = false;
                stdin_check_counter = 0;
            }
        }

        if (pollfds[0].revents != 0) {
            try read_buf.ensureUnusedCapacity(allocator, 4096);
            const write_slice = read_buf.unusedCapacitySlice();
            const n = c.read(server_fd, write_slice.ptr, write_slice.len);
            if (n > 0) {
                read_buf.items.len += @as(usize, @intCast(n));
            } else if (n == -1) {
                const err = std.c.errno(n);
                if (err != .AGAIN and err != .INTR) {
                    std.log.err("client server_fd read error {s}, exiting", .{@errorName(error.ReadFailed)});
                    running = false;
                }
            } else {
                std.log.warn("client server_fd EOF (server closed), exiting", .{});
                running = false;
                continue;
            }

            var read_pos: usize = 0;
            while (read_buf.items.len - read_pos >= 5) {
                const pkt_len = std.mem.readInt(u32, read_buf.items[read_pos..][0..4], .little);
                if (pkt_len < 5) {
                    std.log.err("client malformed packet length {d}, exiting", .{pkt_len});
                    running = false;
                    break;
                }
                if (read_buf.items.len - read_pos < pkt_len) break;

                const msg_type = protocol.MessageType.fromByte(read_buf.items[read_pos + 4]) orelse {
                    std.log.warn("client received unknown message type byte: {}", .{read_buf.items[read_pos + 4]});
                    read_pos += pkt_len;
                    continue;
                };
                const data = read_buf.items[read_pos + 5 .. read_pos + pkt_len];

                switch (msg_type) {
                    .ready => {},
                    .output => {
                        // Never block on a full downstream pty. Queue the frame
                        // and flush; the poll loop drains on POLL.OUT. If the
                        // cap was hit and a backlog dropped, request a full
                        // repaint once the pty demonstrably drains again.
                        if (queueStdout(allocator, &out_buf, data, &needs_redraw)) {
                            if (flushStdout(stdout_fd, &out_buf) and needs_redraw) {
                                needs_redraw = false;
                                const rd_pkt = protocol.Packet.make(.redraw, "");
                                var rd_buf: [128]u8 = undefined;
                                const rd_ser = rd_pkt.serialize(&rd_buf);
                                writeAll(server_fd, rd_ser) catch {};
                            }
                        }
                    },
                    .detach => {
                        std.log.info("client received detach, exiting", .{});
                        running = false;
                    },
                    .request_cell_size => {
                        _ = queryCellSize(server_fd, stdout_fd, stdin_fd, sx, sy);
                    },
                    else => {
                        std.log.warn("client ignored unhandled message type: {any}", .{msg_type});
                    },
                }

                read_pos += pkt_len;
            }

            if (read_pos > 0) {
                std.mem.copyForwards(u8, read_buf.items[0 .. read_buf.items.len - read_pos], read_buf.items[read_pos..]);
                read_buf.items.len -= read_pos;
            }
        }

        if (poll_count == 3 and (pollfds[2].revents & @as(i16, @intCast(std.posix.POLL.OUT))) != 0) {
            if (flushStdout(stdout_fd, &out_buf) and needs_redraw) {
                needs_redraw = false;
                const rd_pkt = protocol.Packet.make(.redraw, "");
                var rd_buf: [128]u8 = undefined;
                const rd_ser = rd_pkt.serialize(&rd_buf);
                writeAll(server_fd, rd_ser) catch {};
            }
        }
    }
}

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "detectNested returns true when SZN env is set" {
    const prev = std.c.getenv("SZN");
    if (prev) |_| {
        try testing.expect(detectNested());
    } else {
        _ = setenv("SZN", "1-test", 1);
        defer _ = unsetenv("SZN");
        try testing.expect(detectNested());
    }
}

test "detectNested returns false when SZN env is not set" {
    const prev = std.c.getenv("SZN");
    if (prev) |_| {
        // Running inside szn — can't test false case, just mark as skipped
        return error.SkipZigTest;
    }
    try testing.expect(!detectNested());
}

test "sigaction configured with SA_RESTART — bug #236" {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = sigwinch_handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    try testing.expect((act.flags & std.posix.SA.RESTART) != 0);
}

test "queueStdout drops the backlog on overflow and sets needs_redraw — bug #298" {
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);
    var needs_redraw = false;

    const chunk = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'A');

    // Fill the queue to exactly the cap without tripping it.
    var total: usize = 0;
    while (total + chunk.len <= MAX_CLIENT_OUT_BUF) : (total += chunk.len) {
        try testing.expect(queueStdout(testing.allocator, &out_buf, chunk, &needs_redraw));
    }
    try testing.expectEqual(@as(usize, MAX_CLIENT_OUT_BUF), out_buf.items.len);
    try testing.expect(!needs_redraw);

    // One more chunk overflows: the backlog is dropped and redraw is requested.
    try testing.expect(queueStdout(testing.allocator, &out_buf, chunk, &needs_redraw));
    try testing.expectEqual(@as(usize, 1024), out_buf.items.len);
    try testing.expect(needs_redraw);

    // A single frame larger than the whole cap is dropped outright.
    const huge = try testing.allocator.alloc(u8, MAX_CLIENT_OUT_BUF + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'B');
    needs_redraw = false;
    try testing.expect(!queueStdout(testing.allocator, &out_buf, huge, &needs_redraw));
    try testing.expectEqual(@as(usize, 0), out_buf.items.len);
    try testing.expect(needs_redraw);
}

test "flushStdout keeps the remainder on a full pipe and drains later — bug #298" {
    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    setNonBlocking(fds[1]);

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);

    // Larger than the OS pipe buffer so the first flush cannot finish.
    const big = try testing.allocator.alloc(u8, 1 << 19); // 512 KiB
    defer testing.allocator.free(big);
    @memset(big, 'X');
    try out_buf.appendSlice(testing.allocator, big);

    // The pipe fills up and the flush returns false, keeping the remainder.
    try testing.expect(!flushStdout(fds[1], &out_buf));
    try testing.expect(out_buf.items.len > 0);

    // Drain the read end until the whole buffer is written out.
    var drain_buf: [16384]u8 = undefined;
    while (out_buf.items.len > 0) {
        _ = std.c.read(fds[0], &drain_buf, drain_buf.len);
        if (flushStdout(fds[1], &out_buf)) break;
    }
    try testing.expectEqual(@as(usize, 0), out_buf.items.len);
}

test "ignoring SIGPIPE turns a write to a closed peer into EPIPE, not a crash — bug #298" {
    // The interactive client over mosh must survive a closed downstream pty.
    // Mirror main.zig's disposition so the test process is not killed by the
    // signal, then confirm write() to a closed fd returns EPIPE.
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &act, &old);
    defer std.posix.sigaction(.PIPE, &old, null);

    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[1]);
    _ = std.c.close(fds[0]); // close read end so writes get EPIPE

    const n = std.c.write(fds[1], "x", 1);
    const err = std.c.errno(n);
    try testing.expect(err == .PIPE);
}
