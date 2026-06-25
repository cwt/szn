const std = @import("std");
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

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
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

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
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

fn mainInner(init: std.process.Init) Error!void {
    const allocator = init.gpa;

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
    const pane = session.active_window.?.active_pane.?;

    server.display_sx = sx;
    server.display_sy = sy;
    try server.listen();

    var chld_act: std.posix.Sigaction = .{
        .handler = .{ .handler = server_mod.sigchld_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
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

    try pane.spawn(allocator, &[_][]const u8{shell}, null);
    try server.watchPanePty(pane);
    pane.initPty();

    while (server.loop.running) {
        try server.run(100);
        server.renderToDisplayClient();
    }

    server.shutdownServer();
}

fn runInteractiveClient(allocator: std.mem.Allocator) Error!void {
    const stdin_fd = c.STDIN_FILENO;
    const stdout_fd = c.STDOUT_FILENO;
    const server_fd = try connect.connectToServer();
    defer _ = c.close(server_fd);

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
        .flags = 0,
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

    var read_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer read_buf.deinit(allocator);
    var running = true;

    while (running) {
        var pollfds: [2]std.posix.pollfd = undefined;
        pollfds[0] = .{ .fd = server_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 };
        pollfds[1] = .{ .fd = stdin_fd, .events = @as(i16, @intCast(std.posix.POLL.IN)), .revents = 0 };

        _ = std.posix.poll(&pollfds, 10) catch continue;

        if (sigwinchFlag.load(.seq_cst)) {
            sigwinchFlag.store(false, .seq_cst);
            var new_ws: c.winsize = undefined;
            if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, &new_ws) == 0) {
                if (new_ws.col != ws.col or new_ws.row != ws.row) {
                    ws = new_ws;
                    sx = @max(ws.col, 80);
                    sy = @max(ws.row, 24);
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
                const sd_pkt = protocol.Packet.make(.stdin_data, stdin_buf[0..@as(usize, @intCast(n))]);
                var sd_buf: [4096 + 5]u8 = undefined;
                const sd_ser = sd_pkt.serialize(&sd_buf);
                try writeAll(server_fd, sd_ser);
            } else if (n == -1) {
                const err = std.c.errno(n);
                if (err != .AGAIN and err != .INTR) {
                    running = false;
                }
            } else {
                const detach_pkt = protocol.Packet.make(.detach, "");
                var d_buf: [128]u8 = undefined;
                const d_ser = detach_pkt.serialize(&d_buf);
                try writeAll(server_fd, d_ser);
                running = false;
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
                    running = false;
                }
            } else {
                running = false;
                continue;
            }

            var read_pos: usize = 0;
            while (read_buf.items.len - read_pos >= 5) {
                const pkt_len = std.mem.readInt(u32, read_buf.items[read_pos..][0..4], .little);
                if (pkt_len < 5) {
                    running = false;
                    break;
                }
                if (read_buf.items.len - read_pos < pkt_len) break;

                const msg_type = protocol.MessageType.fromByte(read_buf.items[read_pos + 4]) orelse {
                    read_pos += pkt_len;
                    continue;
                };
                const data = read_buf.items[read_pos + 5 .. read_pos + pkt_len];

                switch (msg_type) {
                    .ready => {},
                    .output => {
                        writeAll(stdout_fd, data) catch {};
                    },
                    .detach => {
                        running = false;
                    },
                    else => {},
                }

                read_pos += pkt_len;
            }

            if (read_pos > 0) {
                std.mem.copyForwards(u8, read_buf.items[0 .. read_buf.items.len - read_pos], read_buf.items[read_pos..]);
                read_buf.items.len -= read_pos;
            }
        }
    }
}



