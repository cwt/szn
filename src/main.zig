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

pub const Error = server_mod.ServerError || client_mod.Error || connect.Error || socket_path.Error || error{ OutOfMemory, SocketNotFound, WriteFailed, ReadFailed };

// Cached log file descriptor — opened once, reused for all log calls
var log_fd: ?std.posix.fd_t = null;
var log_fd_failed: bool = false;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn resolveLogPath(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |xdg_raw| {
        const xdg = std.mem.span(xdg_raw);
        var dir_buf: [256]u8 = undefined;
        const dir_z = try std.fmt.bufPrintZ(&dir_buf, "{s}/szn", .{xdg});
        const rc = c.mkdir(dir_z.ptr, 0o755);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err != .EXIST) {
                return try std.fmt.bufPrintZ(buf, "/tmp/szn.log", .{});
            }
        }
        return try std.fmt.bufPrintZ(buf, "{s}/szn/szn.log", .{xdg});
    }
    return try std.fmt.bufPrintZ(buf, "/tmp/szn.log", .{});
}

const builtin = @import("builtin");
extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c.mode_t) c_int;
const O_WRONLY = 1;
const O_CREAT = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 0x0200,
    else => 0x0040,
};
const O_APPEND = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 0x0008,
    else => 0x0400,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (log_fd == null) {
        if (log_fd_failed) return;
        var path_buf: [256]u8 = undefined;
        const path = resolveLogPath(&path_buf) catch {
            log_fd_failed = true;
            return;
        };
        const fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o666);
        if (fd < 0) {
            log_fd_failed = true;
            return;
        }
        log_fd = fd;
    }
    const fd = log_fd.?;
    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{s}] ", .{@tagName(level)}) catch return;
    const msg = std.fmt.bufPrint(buf[prefix.len..], format, args) catch {
        // bufPrint failed — write prefix + fallback directly to avoid
        // reading uninitialized stack bytes past the prefix.
        writeAllRaw(fd, buf[0..prefix.len]);
        writeAllRaw(fd, "log message too long\n");
        return;
    };
    const total_len = prefix.len + msg.len;
    if (total_len < buf.len) {
        buf[total_len] = '\n';
        writeAllRaw(fd, buf[0 .. total_len + 1]);
    } else {
        writeAllRaw(fd, buf[0..total_len]);
        writeAllRaw(fd, "\n");
    }
}

fn writeAllRaw(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = c.write(fd, remaining.ptr, @intCast(remaining.len));
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIFLUSH = 1;

var sigwinchFlag = std.atomic.Value(bool).init(false);

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
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

        var client = blk: {
            if (is_new_cmd and !socket_mod.socketExists()) {
                const pid = c.fork();
                if (pid < 0) {
                    std.debug.print("Failed to fork\n", .{});
                    std.process.exit(1);
                }
                if (pid == 0) {
                    if (log_fd) |fd| {
                        _ = c.close(fd);
                        log_fd = null;
                    }
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
                            if (log_fd) |fd| {
                                _ = c.close(fd);
                                log_fd = null;
                            }
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
                if (is_new_cmd) {
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
        if (log_fd) |fd| {
            _ = c.close(fd);
            log_fd = null;
        }
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
    while (attempts < 100) : (attempts += 1) {
        if (socket_mod.socketExists()) return;
        _ = c_usleep(50000);
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

    const shell = try server.resolveShell(allocator, session);
    defer allocator.free(shell);
    std.log.info("spawning shell: {s}", .{shell});
    try pane.spawn(allocator, &[_][]const u8{shell}, null);
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
            try read_buf.ensureUnusedCapacity(allocator, 4096);
            const write_slice = read_buf.unusedCapacitySlice();
            const n = c.read(server_fd, write_slice.ptr, write_slice.len);
            if (n > 0) {
                read_buf.items.len += @as(usize, @intCast(n));
            } else if (n == -1) {
                const err = std.posix.errno(-1);
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

                const msg_type = @as(protocol.MessageType, @enumFromInt(read_buf.items[read_pos + 4]));
                const data = read_buf.items[read_pos + 5 .. read_pos + pkt_len];

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

                read_pos += pkt_len;
            }

            if (read_pos > 0) {
                std.mem.copyForwards(u8, read_buf.items[0 .. read_buf.items.len - read_pos], read_buf.items[read_pos..]);
                read_buf.items.len -= read_pos;
            }
        }
    }
}

test "logFn writes single line atomically — bug #89" {
    // Use a temp file via posix syscalls to avoid Io.File API differences
    const sub_path = "/tmp/szn_test_log_atomic.log";
    const fd = std.c.open(sub_path, std.c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, @as(c_uint, 0o644));
    if (fd < 0) return error.FileOpen;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    defer log_fd = old_log_fd;
    log_fd = fd;

    logFn(.info, .default, "Test formatted log: {d} + {d} = {d}", .{ 1, 2, 3 });

    // Read back using c.pread (available via libc)
    var buf: [1024]u8 = undefined;
    const n = std.c.pread(fd, &buf, buf.len, 0);
    if (n < 0) return error.ReadFailed;

    try std.testing.expectEqualStrings("[info] Test formatted log: 1 + 2 = 3\n", buf[0..@intCast(n)]);
}

test "logFn handles buffer overflow without writing garbage — bug #89" {
    const sub_path = "/tmp/szn_test_log_overflow.log";
    const fd = std.c.open(sub_path, std.c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, @as(c_uint, 0o644));
    if (fd < 0) return error.FileOpen;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    defer log_fd = old_log_fd;
    log_fd = fd;

    // bufPrint for the message part has ~4096 - prefix.len bytes.
    // Send a format string that produces >4096 bytes of output to trigger
    // the overflow fallback path.
    var big_buf: [5000]u8 = undefined;
    @memset(big_buf[0..5000], 'X');
    const big_str = big_buf[0..4096];
    logFn(.info, .default, "{s}", .{big_str});

    // Read back using c.pread
    var read_buf: [8192]u8 = undefined;
    const n = std.c.pread(fd, &read_buf, read_buf.len, 0);
    if (n < 0) return error.ReadFailed;

    // Should contain the fallback message "log message too long"
    // OR the actual formatted prefix + message + newline.
    // Either way, no garbage bytes (uninitialized stack data) should be written.
    try std.testing.expect(n > 0);
    try std.testing.expect(read_buf[@intCast(n - 1)] == '\n');
    // Verify no null bytes (garbage would include uninitialized data)
    try std.testing.expect(std.mem.indexOfScalar(u8, read_buf[0..@intCast(n)], @as(u8, 0)) == null);
}

test "logFn does not retry open after failure — bug #98" {
    const old_log_fd = log_fd;
    const old_log_fd_failed = log_fd_failed;
    defer {
        log_fd = old_log_fd;
        log_fd_failed = old_log_fd_failed;
    }
    log_fd = null;
    log_fd_failed = true;

    // This call should return immediately without trying to open.
    // If it tried to open, it would need resolveLogPath + open which
    // could fail with env-dependent errors. Instead, log_fd stays null.
    logFn(.info, .default, "should not retry", .{});
    try std.testing.expect(log_fd == null);
    try std.testing.expect(log_fd_failed);
}

test "resolveLogPath fallback on invalid XDG_STATE_HOME" {
    const old_xdg = std.c.getenv("XDG_STATE_HOME");

    // setenv is not declared in std.c, declare it locally
    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;

    _ = setenv("XDG_STATE_HOME", "/nonexistent/invalid/dir/szn_test", 1);

    var path_buf: [256]u8 = undefined;
    const path = try resolveLogPath(&path_buf);

    try std.testing.expectEqualStrings("/tmp/szn.log", path);

    if (old_xdg) |old| {
        _ = setenv("XDG_STATE_HOME", old, 1);
    } else {
        _ = setenv("XDG_STATE_HOME", "", 1);
    }
}


