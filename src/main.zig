const std = @import("std");
const c = std.c;
const server_mod = @import("server/server.zig");
const Server = server_mod.Server;
const render = @import("server/render.zig");
const Display = render.Display;
const raw_mod = @import("client/raw.zig");
const cmd_mod = @import("cmd/cmd.zig");

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIFLUSH = 1;

var sigwinchFlag = std.atomic.Value(bool).init(false);

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const stdin_fd = c.STDIN_FILENO;
    const stdout_fd = c.STDOUT_FILENO;

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
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

    if (args.items.len > 1) {
        // Run as client
        var client = @import("client/client.zig").Client.init(allocator) catch |err| {
            std.debug.print("Could not connect to zmux server: {any}\n", .{err});
            std.process.exit(1);
        };
        defer client.deinit();

        var cmd_len: usize = 0;
        for (args.items[1..]) |arg| {
            cmd_len += arg.len + 1;
        }
        var cmd_buf = try allocator.alloc(u8, cmd_len);
        defer allocator.free(cmd_buf);

        var offset: usize = 0;
        for (args.items[1..], 0..) |arg, idx| {
            if (idx > 0) {
                cmd_buf[offset] = ' ';
                offset += 1;
            }
            @memcpy(cmd_buf[offset..][0..arg.len], arg);
            offset += arg.len;
        }
        const cmd = cmd_buf[0..offset];

        try client.sendCommand(cmd);
        const reply = try client.recvPacket();
        defer allocator.free(reply.data);
        const msg_type = @as(@import("server/protocol.zig").MessageType, @enumFromInt(reply.header.msg_type));
        switch (msg_type) {
            .ready => {
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

    // Install SIGWINCH handler to detect terminal resize
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = sigwinch_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.WINCH, &act, null);

    // Query terminal size first to initialize session/window/pane to the actual host size
    var ws: c.winsize = undefined;
    var sx: u32 = 80;
    var sy: u32 = 24;
    if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, &ws) == 0 or
        c.ioctl(stdin_fd, c.T.IOCGWINSZ, &ws) == 0 or
        c.ioctl(std.posix.STDERR_FILENO, c.T.IOCGWINSZ, &ws) == 0)
    {
        sx = @max(ws.col, 80);
        sy = @max(ws.row, 24);
    }

    var server = try Server.init(allocator);
    defer server.deinit();

    // Load startup configurations if available
    server.loadDefaultConfig() catch |err| {
        std.log.warn("Failed to load default config: {any}", .{err});
    };

    // Create session matching host window size. Pane size leaves 1 row for status bar.
    const session = try server.newSession("default", sx, sy - 1);
    const pane = session.active_window.?.active_pane.?;

    const shell = try server.resolveShell(allocator, session);
    defer allocator.free(shell);
    try pane.spawn(allocator, &[_][]const u8{shell});
    try server.watchPanePty(pane);

    server.stdin_fd = stdin_fd;
    try server.loop.addFd(allocator, stdin_fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(&server));
    try server.listen();

    var raw = raw_mod.RawTerminal.init(stdin_fd) catch {
        return;
    };
    raw.setRaw() catch {
        return;
    };
    // Drain any stale input that might have been buffered before raw mode
    _ = tcflush(stdin_fd, TCIFLUSH);
    defer raw.deinit();

    var display = Display{
        .fd = stdout_fd,
        .sx = sx,
        .sy = sy,
    };
    display.enterAltScreen() catch {};
    defer display.exitAltScreen() catch {};

    while (server.loop.running) {
        try server.run();
        const active_session = server.activeSession() orelse continue;
        const active_window = active_session.active_window orelse continue;
        const active_pane = active_window.active_pane orelse continue;

        if (sigwinchFlag.load(.seq_cst)) {
            sigwinchFlag.store(false, .seq_cst);
            var new_ws: c.winsize = undefined;
            if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, &new_ws) == 0) {
                if (new_ws.col != ws.col or new_ws.row != ws.row) {
                    ws = new_ws;
                    display.sx = @max(ws.col, 80);
                    display.sy = @max(ws.row, 24);
                    // Resize active session, which resizes active window and panes inside it
                    active_session.resize(display.sx, display.sy - 1) catch {};
                }
            }
        }
        if (active_pane.dirty) {
            display.renderAll(&active_pane.screen, active_session.name, active_session.windows.items.len) catch |err| {
                std.log.warn("render error: {any}", .{err});
            };
            active_pane.dirty = false;
        }
    }
}
