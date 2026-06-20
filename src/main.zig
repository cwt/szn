const std = @import("std");
const c = std.c;
const server_mod = @import("server/server.zig");
const Server = server_mod.Server;
const render = @import("server/render.zig");
const Display = render.Display;
const raw_mod = @import("client/raw.zig");
const cmd_mod = @import("cmd/cmd.zig");

var sigwinchFlag = std.atomic.Value(bool).init(false);

export fn sigwinch_handler(sig: c.SIG) callconv(.c) void {
    _ = sig;
    sigwinchFlag.store(true, .seq_cst);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdin_fd = c.STDIN_FILENO;
    const stdout_fd = c.STDOUT_FILENO;

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

    // Create session matching host window size. Pane size leaves 1 row for status bar.
    const session = try server.newSession("default", sx, sy - 1);
    const pane = session.active_window.?.active_pane.?;

    try pane.spawn(allocator, null);
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
    defer raw.deinit();

    var display = Display{
        .fd = stdout_fd,
        .sx = sx,
        .sy = sy,
    };
    display.enterAltScreen() catch {};
    defer display.exitAltScreen() catch {};

    while (server.loop.running) {
        if (pane.pty == null) break;
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
