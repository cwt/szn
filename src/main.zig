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

extern "c" fn fopen(filename: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(stream: ?*anyopaque) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: ?*anyopaque) usize;
extern "c" fn fflush(stream: ?*anyopaque) c_int;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const f = fopen("/tmp/szn.log", "a") orelse return;
    defer _ = fclose(f);

    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{s}] ", .{@tagName(level)}) catch return;
    _ = fwrite(prefix.ptr, 1, prefix.len, f);

    const msg = std.fmt.bufPrint(&buf, format, args) catch "log message too long\n";
    _ = fwrite(msg.ptr, 1, msg.len, f);
    _ = fwrite("\n", 1, 1, f);
    _ = fflush(f);
}

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIFLUSH = 1;

var sigwinchFlag = std.atomic.Value(bool).init(false);

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
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
                try runInteractiveClient();
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

        var client = @import("client/client.zig").Client.init(allocator) catch |err| {
            std.debug.print("Could not connect to szn server: {any}\n", .{err});
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
        const msg_type = @as(protocol.MessageType, @enumFromInt(reply.header.msg_type));
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

    if (socket_mod.socketExists()) {
        try runInteractiveClient();
    } else {
        const pid = c.fork();
        if (pid < 0) {
            std.debug.print("Failed to fork\n", .{});
            std.process.exit(1);
        }
        if (pid == 0) {
            try runServerDaemon(allocator);
        } else {
            waitForSocket() catch {
                std.debug.print("Server failed to start\n", .{});
                std.process.exit(1);
            };
            try runInteractiveClient();
        }
    }
}

fn waitForSocket() !void {
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (socket_mod.socketExists()) return;
        _ = std.posix.poll(&[0]std.posix.pollfd{}, 50) catch 0;
    }
    return error.SocketNotFound;
}

fn runServerDaemon(allocator: std.mem.Allocator) !void {
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

    const shell = try server.resolveShell(allocator, session);
    defer allocator.free(shell);
    try pane.spawn(allocator, &[_][]const u8{shell});
    try server.watchPanePty(pane);

    server.display_sx = sx;
    server.display_sy = sy;
    try server.listen();

    var chld_act: std.posix.Sigaction = .{
        .handler = .{ .handler = server_mod.sigchld_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &chld_act, null);

    while (server.loop.running) {
        try server.run();
        server.renderToDisplayClient();
    }

    server.shutdownServer();
}

fn runInteractiveClient() !void {
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
    if (c.write(server_fd, id_ser.ptr, id_ser.len) < 0) return error.WriteFailed;

    var resize_buf: [16]u8 = undefined;
    std.mem.writeInt(u32, resize_buf[0..4], sx, .little);
    std.mem.writeInt(u32, resize_buf[4..8], sy, .little);
    const resize_pkt = protocol.Packet.make(.resize, resize_buf[0..8]);
    var r_buf: [128]u8 = undefined;
    const r_ser = resize_pkt.serialize(&r_buf);
    _ = c.write(server_fd, r_ser.ptr, r_ser.len);

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

    var read_buf: [8192]u8 = undefined;
    var read_pos: usize = 0;
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
                    _ = c.write(server_fd, rs_ser.ptr, rs_ser.len);
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
                _ = c.write(server_fd, sd_ser.ptr, sd_ser.len);
            } else if (n == -1) {
                const err = std.posix.errno(-1);
                if (err != .AGAIN and err != .INTR) {
                    running = false;
                }
            } else {
                const detach_pkt = protocol.Packet.make(.detach, "");
                var d_buf: [128]u8 = undefined;
                const d_ser = detach_pkt.serialize(&d_buf);
                _ = c.write(server_fd, d_ser.ptr, d_ser.len);
                running = false;
            }
        }

        if (pollfds[0].revents != 0) {
            const n = c.read(server_fd, read_buf[read_pos..].ptr, read_buf.len - read_pos);
            if (n > 0) {
                read_pos += @as(usize, @intCast(n));
            } else if (n == -1) {
                const err = std.posix.errno(-1);
                if (err != .AGAIN and err != .INTR) {
                    running = false;
                }
            } else {
                running = false;
                continue;
            }

            while (read_pos >= 5) {
                const pkt_len = std.mem.readInt(u32, read_buf[0..4], .little);
                if (pkt_len < 5 or pkt_len > read_buf.len) break;
                if (read_pos < pkt_len) break;

                const msg_type = @as(protocol.MessageType, @enumFromInt(read_buf[4]));
                const data = read_buf[5..pkt_len];

                switch (msg_type) {
                    .ready => {},
                    .output => {
                        _ = c.write(stdout_fd, data.ptr, data.len);
                    },
                    .detach => {
                        running = false;
                    },
                    else => {},
                }

                const remaining = read_pos - pkt_len;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[pkt_len..read_pos]);
                }
                read_pos = remaining;
            }
        }
    }
}
