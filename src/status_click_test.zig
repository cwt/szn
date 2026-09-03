const std = @import("std");
const Server = @import("server/server.zig").Server;
const DisplayClient = @import("server/server.zig").DisplayClient;
const options = @import("options.zig");

test "handleMouseFocus status click switches to the clicked window — bug #290" {
    var server = try Server.init(std.testing.allocator);
    defer server.deinit();

    const s = try server.newSession("s", 80, 1);
    // A second window gives a window list to click in the status bar.
    const w2 = try s.newWindow(std.testing.allocator, "second");
    // newWindow makes the new window active; reset to the first window so the
    // click below is actually observable.
    s.setActiveWindow(s.windows.items[0]);

    // A display client so renderToDisplayClient() exercises the real status
    // packing path (buildStatusLine) and populates the cached click ranges.
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    _ = try server.addDisplayClient(.{ .fd = fds[1], .sx = 80, .sy = 2 });

    // Force a render so the status layout (and thus the click ranges) is built.
    server.dirty = true;
    server.renderToDisplayClient();

    // Find a column inside the second window's status entry (pos == 1).
    var tx: ?u32 = null;
    for (server.status_click_ranges.items) |r| {
        if (r.pos == 1) tx = r.start_col + (r.end_col - r.start_col) / 2;
    }
    try std.testing.expect(tx != null);

    // Before: the first window is active.
    try std.testing.expect(s.active_window == s.windows.items[0]);

    // Click on the status bar row at the second window's column.
    try server.handleMouseFocus(tx.?, s.height);

    // After: the second window is active.
    try std.testing.expect(s.active_window == w2);
}

test "handleMouseFocus ignores bottom-row clicks when status is off — bug #290" {
    var server = try Server.init(std.testing.allocator);
    defer server.deinit();

    const s = try server.newSession("s", 80, 1);
    _ = try s.newWindow(std.testing.allocator, "second");
    // With `status off` the bottom row is content, not a status bar.
    try s.options.set("status", options.OptionValue{ .choice = "off" });
    // Reset to the first window so a (non-)switch is observable.
    s.setActiveWindow(s.windows.items[0]);

    const before = s.active_window;

    // Click the last content row at column 0 — this must NOT be interpreted as
    // a status-bar window switch (the previous code treated any y >= height as
    // a status click, hijacking real content clicks when status was off).
    try server.handleMouseFocus(0, s.height);

    try std.testing.expect(s.active_window == before);
}

test "queueToClient / sendRequestCellSize self-heals on overflow instead of truncating — bug #297" {
    var server = try Server.init(std.testing.allocator);
    defer server.deinit();

    // A non-blocking pipe whose read end is never drained: writes to the write
    // end EAGAIN, so the client stays permanently behind.
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
    const flags = std.c.fcntl(fds[1], F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = std.c.fcntl(fds[1], F_SETFL, flags | O_NONBLOCK);
    }

    // Register the display client so sendRequestCellSize() reaches it.
    const dcp = try server.addDisplayClient(.{ .fd = fds[1] });

    // Fill the pipe's kernel buffer so a flushDisplayClient write makes no
    // progress (EAGAIN). That keeps the pending buffer above the cap after the
    // flush, which is exactly the condition that must trigger the self-heal
    // reset.
    var junk: [65536]u8 = undefined;
    @memset(&junk, 'x');
    var guard: usize = 0;
    while (guard < 1024) : (guard += 1) {
        const n = std.c.write(fds[1], &junk, junk.len);
        if (n <= 0) break;
    }

    // Pre-fill the pending buffer to the limit so the next packet overflows.
    const filler = try server.allocator.alloc(u8, Server.MAX_OUT_BUF);
    defer server.allocator.free(filler);
    @memset(filler, 'x');
    try dcp.out_buf.appendSlice(server.allocator, filler);
    // appendSlice copies `filler` into out_buf's own buffer, so `filler` must
    // be freed here; the overflow reset only frees out_buf's copy.

    // sendRequestCellSize() funnels into appendClientOut. With the buffer
    // already over the cap and the pipe unwritable, the packet must be dropped
    // and the buffer reset to empty (not left holding a corrupt slice). The
    // next full render then repaints a coherent screen.
    server.needs_cell_size_refresh = true;
    server.sendRequestCellSize();
    try std.testing.expectEqual(@as(usize, 0), dcp.out_buf.items.len);
}
