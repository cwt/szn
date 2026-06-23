const std = @import("std");
const testing = std.testing;
const server_mod = @import("../server/server.zig");
const Server = server_mod.Server;
const Pane = @import("../window.zig").Pane;

pub const CmdResult = enum(u8) {
    ok,
    err,
    wait,
    stop,
};

pub const CmdEntry = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    min_args: u32 = 0,
    max_args: u32 = std.math.maxInt(u32),
    args_usage: []const u8 = "",
    description: []const u8 = "",
    exec: *const fn (server: *Server, args: []const []const u8) CmdResult,
};

fn cmdNewSession(server: *Server, args: []const []const u8) CmdResult {
    const name = if (args.len > 1) args[1] else "default";
    _ = server.newSession(name, 80, 24) catch return .err;
    if (server.sessions.items.len > 1) {
        const idx = server.sessions.items.len - 1;
        const target = server.sessions.items[idx];
        server.sessions.items[idx] = server.sessions.items[0];
        server.sessions.items[0] = target;
        server.dirty = true;
    }
    return .ok;
}

fn cmdListSessions(server: *Server, _: []const []const u8) CmdResult {
    for (server.sessions.items) |session| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}: {d} windows\n", .{ session.name, session.windows.items.len }) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }
    return .ok;
}

fn cmdKillSession(server: *Server, args: []const []const u8) CmdResult {
    const name = if (args.len > 1) args[1] else null;
    if (name) |n| {
        server.killSession(n) catch return .err;
    } else {
        server.killAllSessions();
    }
    return .ok;
}

fn cmdSwitchClient(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const name = args[1];
    var target_idx: ?usize = null;
    for (server.sessions.items, 0..) |s, idx| {
        if (std.mem.eql(u8, s.name, name)) {
            target_idx = idx;
            break;
        }
    }
    if (target_idx) |idx| {
        if (idx > 0) {
            const s = server.sessions.items[idx];
            var i = idx;
            while (i > 0) : (i -= 1) {
                server.sessions.items[i] = server.sessions.items[i - 1];
            }
            server.sessions.items[0] = s;
        }
        return .ok;
    }
    return .err;
}

fn cmdNewWindow(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const name = if (args.len > 1) args[1] else "window";
    _ = session.newWindow(server.allocator, name) catch return .err;
    return .ok;
}

fn cmdKillWindow(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const idx = if (args.len > 1) std.fmt.parseInt(u32, args[1], 10) catch return .err else null;
    if (idx) |i| {
        if (i < session.windows.items.len) {
            session.killWindow(server.allocator, session.windows.items[i]);
        }
    } else {
        if (session.active_window) |w| {
            session.killWindow(server.allocator, w);
        }
    }
    return .ok;
}

fn cmdSendKeys(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;
    var i: u32 = 1;
    while (i < args.len) : (i += 1) {
        pane.writeStr(args[i]) catch return .err;
    }
    return .ok;
}

fn cmdSplitWindow(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;

    var direction: enum { horizontal, vertical } = .horizontal;
    var prop_arg: ?[]const u8 = null;

    for (args, 0..) |arg, i| {
        if (i == 0) continue;
        if (std.mem.eql(u8, arg, "-v")) {
            direction = .vertical;
        } else if (std.mem.eql(u8, arg, "-h")) {
            direction = .horizontal;
        } else if (prop_arg == null) {
            prop_arg = arg;
        }
    }

    const proportion: f64 = if (prop_arg) |p| std.fmt.parseFloat(f64, p) catch 0.5 else 0.5;

    const new_pane = window.splitPane(server.allocator, pane, direction == .vertical, proportion) catch return .err;
    if (pane.pty != null) {
        server.setupPane(session, new_pane) catch return .err;
    }
    return .ok;
}

fn cmdListWindows(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    for (session.windows.items, 0..) |w, idx| {
        const active_char = if (session.active_window == w) @as(u8, '*') else @as(u8, ' ');
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}: {s}{c} ({d} panes)\n", .{ idx, w.name, active_char, w.panes.items.len }) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }
    return .ok;
}

fn cmdRenameSession(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    session.rename(server.allocator, args[1]);
    return .ok;
}

fn cmdRenameWindow(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const a = session.arenaAllocator();
    window.name = a.dupe(u8, args[1]) catch return .err;
    window.automatic_rename = false;
    return .ok;
}

fn cmdSelectWindow(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    const idx = std.fmt.parseInt(u32, args[1], 10) catch return .err;
    if (idx >= session.windows.items.len) return .err;
    session.setActiveWindow(session.windows.items[idx]);
    return .ok;
}

fn cmdMoveWindow(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    if (session.windows.items.len == 0) return .err;

    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    if (args.len == 2) {
        const active = session.active_window orelse session.windows.items[0];
        src_idx = for (session.windows.items, 0..) |w, idx| {
            if (w == active) break idx;
        } else return .err;
        dst_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
    } else {
        src_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
        dst_idx = std.fmt.parseInt(usize, args[2], 10) catch return .err;
    }

    if (src_idx >= session.windows.items.len or dst_idx >= session.windows.items.len) return .err;

    const w = session.windows.orderedRemove(src_idx);
    session.windows.insert(server.allocator, dst_idx, w) catch return .err;
    return .ok;
}

fn cmdSwapWindow(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    if (session.windows.items.len == 0) return .err;

    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    if (args.len == 1) {
        const active = session.active_window orelse session.windows.items[0];
        src_idx = for (session.windows.items, 0..) |w, idx| {
            if (w == active) break idx;
        } else return .err;
        dst_idx = if (src_idx + 1 < session.windows.items.len) src_idx + 1 else if (src_idx > 0) src_idx - 1 else src_idx;
    } else if (args.len == 2) {
        const active = session.active_window orelse session.windows.items[0];
        src_idx = for (session.windows.items, 0..) |w, idx| {
            if (w == active) break idx;
        } else return .err;
        dst_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
    } else {
        src_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
        dst_idx = std.fmt.parseInt(usize, args[2], 10) catch return .err;
    }

    if (src_idx >= session.windows.items.len or dst_idx >= session.windows.items.len) return .err;

    const tmp = session.windows.items[src_idx];
    session.windows.items[src_idx] = session.windows.items[dst_idx];
    session.windows.items[dst_idx] = tmp;
    return .ok;
}

fn cmdSelectPane(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const idx = std.fmt.parseInt(u32, args[1], 10) catch return .err;
    if (idx >= window.panes.items.len) return .err;
    window.setActivePane(window.panes.items[idx]);
    return .ok;
}

fn cmdKillPane(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;
    if (window.panes.items.len <= 1) return .err;
    window.removePane(server.allocator, pane);
    return .ok;
}

fn cmdSwapPane(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    if (window.panes.items.len <= 1) return .err;

    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    const active = window.active_pane orelse window.panes.items[0];
    src_idx = for (window.panes.items, 0..) |p, idx| {
        if (p == active) break idx;
    } else return .err;

    if (args.len < 2) {
        dst_idx = (src_idx + 1) % window.panes.items.len;
    } else if (args.len == 2) {
        dst_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
    } else {
        src_idx = std.fmt.parseInt(usize, args[1], 10) catch return .err;
        dst_idx = std.fmt.parseInt(usize, args[2], 10) catch return .err;
    }

    if (src_idx >= window.panes.items.len or dst_idx >= window.panes.items.len) return .err;
    if (src_idx == dst_idx) return .ok;

    const pane1 = window.panes.items[src_idx];
    const pane2 = window.panes.items[dst_idx];

    const node1 = window.layout.findLeafParent(window.layout.root, pane1) orelse return .err;
    const node2 = window.layout.findLeafParent(window.layout.root, pane2) orelse return .err;
    node1.leaf = pane2;
    node2.leaf = pane1;

    window.panes.items[src_idx] = pane2;
    window.panes.items[dst_idx] = pane1;

    return .ok;
}

fn cmdJoinPane(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const dst_win = session.active_window orelse return .err;
    const dst_pane = dst_win.active_pane orelse return .err;

    var vertical = true;
    var src_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            vertical = false;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            vertical = true;
        } else {
            src_arg = args[i];
        }
    }

    var src_win = dst_win;
    var src_pane: *@import("../window.zig").Pane = undefined;

    if (src_arg) |sa| {
        const colon = std.mem.indexOfScalar(u8, sa, ':');
        if (colon) |c_pos| {
            const win_idx = std.fmt.parseInt(usize, sa[0..c_pos], 10) catch return .err;
            const pane_idx = std.fmt.parseInt(usize, sa[c_pos + 1 ..], 10) catch return .err;
            if (win_idx >= session.windows.items.len) return .err;
            src_win = session.windows.items[win_idx];
            if (pane_idx >= src_win.panes.items.len) return .err;
            src_pane = src_win.panes.items[pane_idx];
        } else {
            const win_idx = std.fmt.parseInt(usize, sa, 10) catch return .err;
            if (win_idx >= session.windows.items.len) return .err;
            src_win = session.windows.items[win_idx];
            src_pane = src_win.active_pane orelse return .err;
        }
    } else {
        if (session.windows.items.len <= 1) return .err;
        for (session.windows.items) |w| {
            if (w != dst_win) {
                src_win = w;
                src_pane = w.active_pane orelse return .err;
                break;
            }
        }
    }

    if (src_pane == dst_pane) return .err;

    src_win.extractPane(server.allocator, src_pane);
    if (src_win.panes.items.len == 0) {
        const a = session.arenaAllocator();
        const dummy = a.create(Pane) catch return .err;
        dummy.* = Pane.init(a, 9999, 1, 1) catch return .err;
        src_win.layout.root.leaf = dummy;
        session.killWindow(server.allocator, src_win);
    }

    const dummy_pane = dst_win.splitPane(server.allocator, dst_pane, vertical, 0.5) catch return .err;

    for (dst_win.panes.items) |*p| {
        if (p.* == dummy_pane) {
            p.* = src_pane;
            dst_win.registerPane(src_pane);
            break;
        }
    }
    const dummy_node = dst_win.layout.findLeafParent(dst_win.layout.root, dummy_pane) orelse return .err;
    dummy_node.leaf = src_pane;

    src_pane.resizeTerminal(dummy_pane.screen.grid.width, dummy_pane.screen.grid.height) catch return .err;

    dst_win.setActivePane(src_pane);
    return .ok;
}

fn cmdBreakPane(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;

    if (window.panes.items.len <= 1) return .err;

    window.extractPane(server.allocator, pane);

    const new_win = session.newWindow(server.allocator, "window") catch return .err;
    if (new_win.panes.items.len > 0) {
        new_win.panes.items[0] = pane;
        new_win.registerPane(pane);
        new_win.layout.root.leaf = pane;
        new_win.setActivePane(pane);
        pane.resizeTerminal(new_win.width, new_win.height) catch return .err;
    }

    return .ok;
}

fn cmdPasteBuffer(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;
    if (server.paste_buffer) |pb| {
        pane.writeStr(pb) catch return .err;
    }
    return .ok;
}

fn cmdCopyMode(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;
    pane.screen.copy_mode = @import("../mode_copy.zig").CopyMode.init(.vi);
    pane.screen.copy_mode.?.enter(&pane.screen.grid);
    pane.dirty = true;
    return .ok;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn cmdFindWindow(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    const query = args[1];
    const session = server.activeSession() orelse return .err;

    for (session.windows.items) |w| {
        if (indexOfIgnoreCase(w.name, query) != null) {
            session.setActiveWindow(w);
            return .ok;
        }
    }
    return .err;
}

fn cmdShowMessages(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    for (server.log_messages.items) |msg| {
        server.response_buf.appendSlice(server.allocator, msg) catch return .err;
        server.response_buf.appendSlice(server.allocator, "\n") catch return .err;
    }
    return .ok;
}

fn cmdListKeys(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    const key_mod = @import("../key.zig");

    // List prefix bindings
    for (server.dispatcher.prefix_table.bindings.items) |b| {
        var key_buf: [64]u8 = undefined;
        const key_str = key_mod.format(b.key, &key_buf);
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "bind-key -T prefix {s} {s}\n", .{ key_str, @tagName(b.action) }) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }

    // List root bindings (if any)
    for (server.dispatcher.root_table.bindings.items) |b| {
        var key_buf: [64]u8 = undefined;
        const key_str = key_mod.format(b.key, &key_buf);
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "bind-key -T root {s} {s}\n", .{ key_str, @tagName(b.action) }) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }

    return .ok;
}

fn cmdRotateWindow(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    if (window.panes.items.len <= 1) return .ok;
    const first = window.panes.items[0];
    for (0..window.panes.items.len - 1) |i| {
        window.panes.items[i] = window.panes.items[i + 1];
    }
    window.panes.items[window.panes.items.len - 1] = first;
    return .ok;
}

fn cmdCapturePane(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;

    var y: u32 = 0;
    while (y < pane.screen.grid.height) : (y += 1) {
        var x: u32 = 0;
        while (x < pane.screen.grid.width) : (x += 1) {
            const cell = pane.screen.grid.getCell(x, y);
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch blk: {
                utf8_buf[0] = ' ';
                break :blk 1;
            };
            server.response_buf.appendSlice(server.allocator, utf8_buf[0..len]) catch return .err;
        }
        server.response_buf.appendSlice(server.allocator, "\n") catch return .err;
    }
    return .ok;
}

fn cmdListPanes(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const session_wide = for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s")) break true;
    } else false;

    if (session_wide) {
        for (session.windows.items, 0..) |win, win_idx| {
            for (win.panes.items, 0..) |p, pane_idx| {
                const active_char = if (win.active_pane == p) @as(u8, '*') else @as(u8, ' ');
                var buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{d}.{d}: [{d}x{d}]{c}\n", .{ win_idx, pane_idx, p.screen.grid.width, p.screen.grid.height, active_char }) catch return .err;
                server.response_buf.appendSlice(server.allocator, line) catch return .err;
            }
        }
    } else {
        const window = session.active_window orelse return .err;
        for (window.panes.items, 0..) |p, idx| {
            const active_char = if (window.active_pane == p) @as(u8, '*') else @as(u8, ' ');
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d}: [{d}x{d}]{c}\n", .{ idx, p.screen.grid.width, p.screen.grid.height, active_char }) catch return .err;
            server.response_buf.appendSlice(server.allocator, line) catch return .err;
        }
    }
    return .ok;
}

fn cmdListCommands(server: *Server, _: []const []const u8) CmdResult {
    const table = cmdTable();
    for (table) |entry| {
        var buf: [512]u8 = undefined;
        const line = if (entry.description.len > 0)
            std.fmt.bufPrint(&buf, "{s} {s}\n", .{ entry.name, entry.description }) catch return .err
        else
            std.fmt.bufPrint(&buf, "{s}\n", .{entry.name}) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }
    return .ok;
}

fn cmdHelp(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) {
        const table = cmdTable();
        for (table) |entry| {
            var buf: [256]u8 = undefined;
            const line = if (entry.args_usage.len > 0)
                std.fmt.bufPrint(&buf, "  {s}  {s}\n", .{ entry.name, entry.args_usage }) catch return .err
            else
                std.fmt.bufPrint(&buf, "  {s}\n", .{entry.name}) catch return .err;
            server.response_buf.appendSlice(server.allocator, line) catch return .err;
        }
        const footer = "\nUse `szn help <command>` for details on a specific command.\n";
        server.response_buf.appendSlice(server.allocator, footer) catch return .err;
        return .ok;
    }

    const name = args[1];
    const entry = lookup(name) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command: {s}\n", .{name}) catch return .err;
        server.response_buf.appendSlice(server.allocator, msg) catch return .err;
        return .err;
    };

    var buf: [512]u8 = undefined;
    const lf = "\n";

    var line = std.fmt.bufPrint(&buf, "  Name:    {s}\n", .{entry.name}) catch return .err;
    server.response_buf.appendSlice(server.allocator, line) catch return .err;

    if (entry.alias) |a| {
        line = std.fmt.bufPrint(&buf, "  Alias:   {s}\n", .{a}) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }

    line = std.fmt.bufPrint(&buf, "  Usage:   szn {s}", .{entry.name}) catch return .err;
    server.response_buf.appendSlice(server.allocator, line) catch return .err;
    if (entry.args_usage.len > 0) {
        line = std.fmt.bufPrint(&buf, " {s}", .{entry.args_usage}) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }
    server.response_buf.appendSlice(server.allocator, lf) catch return .err;

    if (entry.description.len > 0) {
        line = std.fmt.bufPrint(&buf, "  Details: {s}\n", .{entry.description}) catch return .err;
        server.response_buf.appendSlice(server.allocator, line) catch return .err;
    }

    server.response_buf.appendSlice(server.allocator, lf) catch return .err;
    return .ok;
}

fn cmdDetachClient(server: *Server, _: []const []const u8) CmdResult {
    _ = server;
    return .stop;
}

fn cmdLastWindow(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    if (session.windows.items.len <= 1) return .ok;
    if (session.last_window) |lw| {
        session.setActiveWindow(lw);
        return .ok;
    }
    const current = session.active_window orelse return .err;
    for (session.windows.items) |w| {
        if (w != current) {
            session.setActiveWindow(w);
            return .ok;
        }
    }
    return .ok;
}

fn cmdNextWindow(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const current = session.active_window orelse return .err;
    for (session.windows.items, 0..) |w, i| {
        if (w == current) {
            const next = (i + 1) % session.windows.items.len;
            session.setActiveWindow(session.windows.items[next]);
            return .ok;
        }
    }
    return .err;
}

fn cmdPrevWindow(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const current = session.active_window orelse return .err;
    for (session.windows.items, 0..) |w, i| {
        if (w == current) {
            const prev = if (i == 0) session.windows.items.len - 1 else i - 1;
            session.setActiveWindow(session.windows.items[prev]);
            return .ok;
        }
    }
    return .err;
}

fn cmdSetOption(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 3) return .err;
    var is_global = false;
    var is_window = false;
    var opt_idx: usize = 1;
    while (opt_idx < args.len and std.mem.startsWith(u8, args[opt_idx], "-")) {
        if (std.mem.eql(u8, args[opt_idx], "-g")) {
            is_global = true;
        } else if (std.mem.eql(u8, args[opt_idx], "-w")) {
            is_window = true;
        }
        opt_idx += 1;
    }
    if (args.len - opt_idx < 2) return .err;
    const option_name = args[opt_idx];
    const value_str = args[opt_idx + 1];

    const cfg_mod = @import("../cfg.zig");
    const parsed_val = cfg_mod.parseValue(server.allocator, value_str) catch return .err;
    // Note: OptionValue duplicates strings internally when set, so we can free parsed_val.string on exit.
    defer {
        if (parsed_val == .string) server.allocator.free(parsed_val.string);
    }

    if (is_global) {
        if (is_window) {
            server.global_window_options.set(option_name, parsed_val) catch return .err;
        } else {
            server.global_options.set(option_name, parsed_val) catch return .err;
            if (std.mem.eql(u8, option_name, "prefix")) {
                if (parsed_val == .key) {
                    server.dispatcher.prefix = parsed_val.key;
                }
            }
        }
    } else {
        const session = server.activeSession() orelse return .err;
        if (is_window) {
            const window = session.active_window orelse return .err;
            window.options.set(option_name, parsed_val) catch return .err;
        } else {
            session.options.set(option_name, parsed_val) catch return .err;
        }
    }
    return .ok;
}

fn printOptionValue(server: *Server, val: @import("../options.zig").OptionValue) ParseError!void {
    switch (val) {
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try server.response_buf.appendSlice(server.allocator, s);
        },
        .string => |s| {
            try server.response_buf.appendSlice(server.allocator, "\"");
            try server.response_buf.appendSlice(server.allocator, s);
            try server.response_buf.appendSlice(server.allocator, "\"");
        },
        .colour => |col| {
            var buf: [64]u8 = undefined;
            try server.response_buf.appendSlice(server.allocator, col.fmt(&buf));
        },
        .key => |k| {
            var buf: [64]u8 = undefined;
            try server.response_buf.appendSlice(server.allocator, @import("../key.zig").format(k, &buf));
        },
        .flag => |b| {
            try server.response_buf.appendSlice(server.allocator, if (b) "on" else "off");
        },
        .choice => |c| {
            try server.response_buf.appendSlice(server.allocator, c);
        },
    }
}

fn cmdShowOptions(server: *Server, args: []const []const u8) CmdResult {
    _ = args;
    const session = server.activeSession() orelse return .err;

    for (session.options.table, 0..) |def, idx| {
        server.response_buf.appendSlice(server.allocator, def.name) catch return .err;
        server.response_buf.appendSlice(server.allocator, " ") catch return .err;
        printOptionValue(server, session.options.values[idx]) catch return .err;
        server.response_buf.appendSlice(server.allocator, "\n") catch return .err;
    }

    if (session.active_window) |window| {
        for (window.options.table, 0..) |def, idx| {
            server.response_buf.appendSlice(server.allocator, def.name) catch return .err;
            server.response_buf.appendSlice(server.allocator, " ") catch return .err;
            printOptionValue(server, window.options.values[idx]) catch return .err;
            server.response_buf.appendSlice(server.allocator, "\n") catch return .err;
        }
    }
    return .ok;
}

fn cmdResizePane(server: *Server, args: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    const window = session.active_window orelse return .err;
    const pane = window.active_pane orelse return .err;

    var adjust_w: i32 = 0;
    var adjust_h: i32 = 0;
    var exact_w: ?u32 = null;
    var exact_h: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-D")) {
            var val: i32 = 1;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(i32, args[i + 1], 10)) |v| {
                    val = v;
                    i += 1;
                } else |_| {}
            }
            adjust_h += val;
        } else if (std.mem.eql(u8, args[i], "-U")) {
            var val: i32 = 1;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(i32, args[i + 1], 10)) |v| {
                    val = v;
                    i += 1;
                } else |_| {}
            }
            adjust_h -= val;
        } else if (std.mem.eql(u8, args[i], "-L")) {
            var val: i32 = 1;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(i32, args[i + 1], 10)) |v| {
                    val = v;
                    i += 1;
                } else |_| {}
            }
            adjust_w -= val;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            var val: i32 = 1;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(i32, args[i + 1], 10)) |v| {
                    val = v;
                    i += 1;
                } else |_| {}
            }
            adjust_w += val;
        } else if (std.mem.eql(u8, args[i], "-x")) {
            if (i + 1 >= args.len) return .err;
            exact_w = std.fmt.parseUnsigned(u32, args[i + 1], 10) catch return .err;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-y")) {
            if (i + 1 >= args.len) return .err;
            exact_h = std.fmt.parseUnsigned(u32, args[i + 1], 10) catch return .err;
            i += 1;
        }
    }

    const current_w = pane.screen.grid.width;
    const current_h = pane.screen.grid.height;

    const new_w = @as(i32, @intCast(current_w)) + adjust_w;
    if (new_w < 1) return .err;
    const target_w = exact_w orelse @as(u32, @intCast(new_w));
    const new_h = @as(i32, @intCast(current_h)) + adjust_h;
    if (new_h < 1) return .err;
    const target_h = exact_h orelse @as(u32, @intCast(new_h));

    pane.resizeTerminal(target_w, target_h) catch return .err;
    return .ok;
}

fn cmdBindKey(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 3) return .err;
    var is_root = false;
    var opt_idx: usize = 1;
    while (opt_idx < args.len and std.mem.startsWith(u8, args[opt_idx], "-")) {
        if (std.mem.eql(u8, args[opt_idx], "-n")) {
            is_root = true;
        }
        opt_idx += 1;
    }
    if (args.len - opt_idx < 2) return .err;
    const key_name = args[opt_idx];
    const cmd_str = args[opt_idx + 1];

    const key_mod = @import("../key.zig");
    const parsed_key = key_mod.parseKeyName(key_name) catch return .err;

    const key_binding = @import("../key_binding.zig");
    const action = key_binding.mapCommandToAction(cmd_str) orelse return .err;

    const table = if (is_root) &server.dispatcher.root_table else &server.dispatcher.prefix_table;
    table.bind(parsed_key, action) catch return .err;
    return .ok;
}

fn cmdUnbindKey(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    var is_root = false;
    var opt_idx: usize = 1;
    while (opt_idx < args.len and std.mem.startsWith(u8, args[opt_idx], "-")) {
        if (std.mem.eql(u8, args[opt_idx], "-n")) {
            is_root = true;
        }
        opt_idx += 1;
    }
    if (args.len - opt_idx < 1) return .err;
    const key_name = args[opt_idx];

    const key_mod = @import("../key.zig");
    const parsed_key = key_mod.parseKeyName(key_name) catch return .err;

    const table = if (is_root) &server.dispatcher.root_table else &server.dispatcher.prefix_table;
    table.unbind(parsed_key);
    return .ok;
}

fn cmdSourceFile(server: *Server, args: []const []const u8) CmdResult {
    if (args.len < 2) return .err;
    server.loadConfigFile(args[1]) catch return .err;
    return .ok;
}

pub const commands = struct {
    pub const new_session = CmdEntry{
        .name = "new-session",
        .alias = "new",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[name]",
        .description = "Create a new session with an optional name",
        .exec = cmdNewSession,
    };
    pub const list_sessions = CmdEntry{
        .name = "list-sessions",
        .alias = "ls",
        .description = "List all sessions",
        .exec = cmdListSessions,
    };
    pub const kill_session = CmdEntry{
        .name = "kill-session",
        .alias = null,
        .description = "Kill a session by name, or the active session if no name given",
        .exec = cmdKillSession,
    };
    pub const rename_session = CmdEntry{
        .name = "rename-session",
        .alias = null,
        .min_args = 1,
        .max_args = 1,
        .args_usage = "new-name",
        .description = "Rename the current session",
        .exec = cmdRenameSession,
    };
    pub const new_window = CmdEntry{
        .name = "new-window",
        .alias = "neww",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[name]",
        .description = "Create a new window in the current session",
        .exec = cmdNewWindow,
    };
    pub const kill_window = CmdEntry{
        .name = "kill-window",
        .alias = "killw",
        .description = "Kill a window by index, or the active window if none given",
        .exec = cmdKillWindow,
    };
    pub const rename_window = CmdEntry{
        .name = "rename-window",
        .alias = null,
        .min_args = 1,
        .max_args = 1,
        .args_usage = "new-name",
        .description = "Rename the current window",
        .exec = cmdRenameWindow,
    };
    pub const select_window = CmdEntry{
        .name = "select-window",
        .alias = "selectw",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "index",
        .description = "Select a window by index",
        .exec = cmdSelectWindow,
    };
    pub const move_window = CmdEntry{
        .name = "move-window",
        .alias = "movew",
        .min_args = 1,
        .max_args = 2,
        .args_usage = "[src-index] dst-index",
        .description = "Move a window to a new index",
        .exec = cmdMoveWindow,
    };
    pub const swap_window = CmdEntry{
        .name = "swap-window",
        .alias = "swapw",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[src-index] [dst-index]",
        .description = "Swap two windows by index",
        .exec = cmdSwapWindow,
    };
    pub const next_window = CmdEntry{
        .name = "next-window",
        .alias = "next",
        .description = "Move to the next window",
        .exec = cmdNextWindow,
    };
    pub const prev_window = CmdEntry{
        .name = "previous-window",
        .alias = "prev",
        .description = "Move to the previous window",
        .exec = cmdPrevWindow,
    };
    pub const last_window = CmdEntry{
        .name = "last-window",
        .alias = "last",
        .description = "Move to the last used window",
        .exec = cmdLastWindow,
    };
    pub const send_keys = CmdEntry{
        .name = "send-keys",
        .alias = "send",
        .min_args = 1,
        .args_usage = "key ...",
        .description = "Send keys to the active pane",
        .exec = cmdSendKeys,
    };
    pub const split_window = CmdEntry{
        .name = "split-window",
        .alias = "splitw",
        .min_args = 0,
        .max_args = 3,
        .args_usage = "[-v] [proportion]",
        .description = "Split the current pane horizontally (-v for vertical)",
        .exec = cmdSplitWindow,
    };
    pub const select_pane = CmdEntry{
        .name = "select-pane",
        .alias = "selectp",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "index",
        .description = "Select a pane by index",
        .exec = cmdSelectPane,
    };
    pub const kill_pane = CmdEntry{
        .name = "kill-pane",
        .alias = "killp",
        .description = "Kill the active pane",
        .exec = cmdKillPane,
    };
    pub const rotate_window = CmdEntry{
        .name = "rotate-window",
        .alias = "rotatew",
        .description = "Rotate panes within the current window",
        .exec = cmdRotateWindow,
    };
    pub const capture_pane = CmdEntry{
        .name = "capture-pane",
        .alias = "capturep",
        .description = "Capture the contents of the active pane",
        .exec = cmdCapturePane,
    };
    pub const list_windows = CmdEntry{
        .name = "list-windows",
        .alias = "lsw",
        .description = "List all windows in the current session",
        .exec = cmdListWindows,
    };
    pub const list_panes = CmdEntry{
        .name = "list-panes",
        .alias = "lsp",
        .description = "List panes (-s for all windows in session)",
        .exec = cmdListPanes,
    };
    pub const list_commands = CmdEntry{
        .name = "list-commands",
        .alias = "lscm",
        .description = "List all available commands",
        .exec = cmdListCommands,
    };
    pub const detach_client = CmdEntry{
        .name = "detach-client",
        .alias = "detach",
        .description = "Detach the current client from the server",
        .exec = cmdDetachClient,
    };
    pub const set_option = CmdEntry{
        .name = "set-option",
        .alias = "set",
        .description = "Set a session or window option",
        .exec = cmdSetOption,
    };
    pub const show_options = CmdEntry{
        .name = "show-options",
        .alias = "show",
        .description = "Show all session and window options",
        .exec = cmdShowOptions,
    };
    pub const resize_pane = CmdEntry{
        .name = "resize-pane",
        .alias = "resizep",
        .description = "Resize the active pane",
        .exec = cmdResizePane,
    };
    pub const bind_key = CmdEntry{
        .name = "bind-key",
        .alias = "bind",
        .description = "Bind a key to a command",
        .exec = cmdBindKey,
    };
    pub const unbind_key = CmdEntry{
        .name = "unbind-key",
        .alias = "unbind",
        .description = "Unbind a key binding",
        .exec = cmdUnbindKey,
    };
    pub const source_file = CmdEntry{
        .name = "source-file",
        .alias = "source",
        .description = "Load and execute commands from a file",
        .exec = cmdSourceFile,
    };
    pub const attach_session = CmdEntry{
        .name = "attach-session",
        .alias = "attach",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "target-session",
        .description = "Attach to an existing session",
        .exec = cmdSwitchClient,
    };
    pub const switch_client = CmdEntry{
        .name = "switch-client",
        .alias = "switchc",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "target-session",
        .description = "Switch the attached client to another session",
        .exec = cmdSwitchClient,
    };
    pub const swap_pane = CmdEntry{
        .name = "swap-pane",
        .alias = "swapp",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[src-index] [dst-index]",
        .description = "Swap two panes in the current window",
        .exec = cmdSwapPane,
    };
    pub const join_pane = CmdEntry{
        .name = "join-pane",
        .alias = "joinp",
        .min_args = 0,
        .max_args = 3,
        .args_usage = "[-h] [-v] [src-window:src-pane]",
        .description = "Join a pane from another window into the current one",
        .exec = cmdJoinPane,
    };
    pub const break_pane = CmdEntry{
        .name = "break-pane",
        .alias = "breakp",
        .min_args = 0,
        .max_args = 0,
        .args_usage = "",
        .description = "Break the active pane into a new window",
        .exec = cmdBreakPane,
    };
    pub const paste_buffer = CmdEntry{
        .name = "paste-buffer",
        .alias = "pasteb",
        .min_args = 0,
        .max_args = 0,
        .args_usage = "",
        .description = "Paste the most recent copy buffer into the active pane",
        .exec = cmdPasteBuffer,
    };
    pub const copy_mode = CmdEntry{
        .name = "copy-mode",
        .alias = null,
        .min_args = 0,
        .max_args = 0,
        .args_usage = "",
        .description = "Enter copy mode in the active pane",
        .exec = cmdCopyMode,
    };
    pub const find_window = CmdEntry{
        .name = "find-window",
        .alias = "findw",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "query",
        .description = "Search for a window by name",
        .exec = cmdFindWindow,
    };
    pub const show_messages = CmdEntry{
        .name = "show-messages",
        .alias = "showmsgs",
        .min_args = 0,
        .max_args = 0,
        .args_usage = "",
        .description = "Show recent log messages",
        .exec = cmdShowMessages,
    };
    pub const list_keys = CmdEntry{
        .name = "list-keys",
        .alias = "lsk",
        .min_args = 0,
        .max_args = 0,
        .args_usage = "",
        .description = "List all current key bindings",
        .exec = cmdListKeys,
    };
    pub const help = CmdEntry{
        .name = "help",
        .alias = "?",
        .min_args = 0,
        .max_args = 1,
        .args_usage = "[command]",
        .description = "Show help for all commands or a specific command",
        .exec = cmdHelp,
    };
};

fn cmdTable() []const *const CmdEntry {
    return comptime blk: {
        const entries = [_]*const CmdEntry{
            &commands.new_session,
            &commands.list_sessions,
            &commands.kill_session,
            &commands.rename_session,
            &commands.new_window,
            &commands.kill_window,
            &commands.rename_window,
            &commands.select_window,
            &commands.move_window,
            &commands.swap_window,
            &commands.next_window,
            &commands.prev_window,
            &commands.last_window,
            &commands.send_keys,
            &commands.split_window,
            &commands.select_pane,
            &commands.kill_pane,
            &commands.rotate_window,
            &commands.capture_pane,
            &commands.list_windows,
            &commands.list_panes,
            &commands.list_commands,
            &commands.detach_client,
            &commands.set_option,
            &commands.show_options,
            &commands.bind_key,
            &commands.unbind_key,
            &commands.source_file,
            &commands.resize_pane,
            &commands.attach_session,
            &commands.switch_client,
            &commands.swap_pane,
            &commands.join_pane,
            &commands.break_pane,
            &commands.paste_buffer,
            &commands.copy_mode,
            &commands.find_window,
            &commands.show_messages,
            &commands.list_keys,
            &commands.help,
        };
        break :blk &entries;
    };
}

pub fn lookup(name: []const u8) ?*const CmdEntry {
    const table = cmdTable();
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
        if (entry.alias) |a| {
            if (std.mem.eql(u8, a, name)) return entry;
        }
    }
    return null;
}

pub fn formatHelp(allocator: std.mem.Allocator, command_name: ?[]const u8) ParseError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    if (command_name) |name| {
        const entry = lookup(name) orelse {
            try buf.appendSlice(allocator, "Unknown command: ");
            try buf.appendSlice(allocator, name);
            try buf.appendSlice(allocator, "\n");
            return try buf.toOwnedSlice(allocator);
        };

        var line_buf: [512]u8 = undefined;
        var line = try std.fmt.bufPrint(&line_buf, "  Name:    {s}\n", .{entry.name});
        try buf.appendSlice(allocator, line);

        if (entry.alias) |a| {
            line = try std.fmt.bufPrint(&line_buf, "  Alias:   {s}\n", .{a});
            try buf.appendSlice(allocator, line);
        }

        line = try std.fmt.bufPrint(&line_buf, "  Usage:   szn {s}", .{entry.name});
        try buf.appendSlice(allocator, line);
        if (entry.args_usage.len > 0) {
            line = try std.fmt.bufPrint(&line_buf, " {s}", .{entry.args_usage});
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, "\n");

        if (entry.description.len > 0) {
            line = try std.fmt.bufPrint(&line_buf, "  Details: {s}\n", .{entry.description});
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, "\n");
    } else {
        const table = cmdTable();
        for (table) |entry| {
            var line_buf: [256]u8 = undefined;
            const line = if (entry.args_usage.len > 0)
                try std.fmt.bufPrint(&line_buf, "  {s}  {s}\n", .{ entry.name, entry.args_usage })
            else
                try std.fmt.bufPrint(&line_buf, "  {s}\n", .{entry.name});
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, "\nUse `szn help <command>` for details on a specific command.\n");
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn parse(input: []const u8, allocator: std.mem.Allocator) !CmdArgs {
    var arg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer arg_list.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    while (it.next()) |token| {
        try arg_list.append(allocator, token);
    }
    const name = if (arg_list.items.len > 0) arg_list.items[0] else "";
    const entry = lookup(name) orelse return error.UnknownCommand;
    if (arg_list.items.len - 1 < entry.min_args) return error.MissingArgs;
    if (arg_list.items.len - 1 > entry.max_args) return error.TooManyArgs;
    return CmdArgs{
        .entry = entry,
        .args = try arg_list.toOwnedSlice(allocator),
    };
}

pub const CmdArgs = struct {
    entry: *const CmdEntry,
    args: [][]const u8,

    pub fn deinit(self: *CmdArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
    }

    pub fn exec(self: CmdArgs, server: *Server) CmdResult {
        return self.entry.exec(server, self.args);
    }
};

pub const ParseError = error{
    UnknownCommand,
    MissingArgs,
    TooManyArgs,
    OutOfMemory,
    NoSpaceLeft,
};

test "lookup by name" {
    const entry = lookup("new-session") orelse return error.SkipTest;
    try testing.expectEqualStrings("new-session", entry.name);
}

test "lookup by alias" {
    const entry = lookup("new") orelse return error.SkipTest;
    try testing.expectEqualStrings("new-session", entry.name);
}

test "lookup unknown returns null" {
    try testing.expect(lookup("nonexistent") == null);
}

test "parse valid command" {
    var result = try parse("new-session mysession", testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("new-session", result.args[0]);
    try testing.expectEqualStrings("mysession", result.args[1]);
}

test "parse unknown command fails" {
    try testing.expectError(error.UnknownCommand, parse("blah", testing.allocator));
}

test "parse missing args fails" {
    try testing.expectError(error.MissingArgs, parse("send-keys", testing.allocator));
}

test "parse too many args fails" {
    try testing.expectError(error.TooManyArgs, parse("new-session a b c", testing.allocator));
}

test "cmd table all entries have names" {
    const table = cmdTable();
    for (table) |entry| {
        try testing.expect(entry.name.len > 0);
    }
}

test "new-session exec creates session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    var cmd = try parse("new-session test", testing.allocator);
    defer cmd.deinit(testing.allocator);
    const result = cmd.exec(&server);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "kill-session removes session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var cmd = try parse("new-session test", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
    {
        var cmd = try parse("kill-session test", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "split-window creates new pane" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var cmd = try parse("new-session test", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    const session = server.activeSession().?;
    const window = session.active_window.?;
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
    {
        var cmd = try parse("split-window", testing.allocator);
        defer cmd.deinit(testing.allocator);
        const result = cmd.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
}

test "new-window creates new window" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var cmd = try parse("new-session test", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    try testing.expectEqual(@as(usize, 1), server.sessions.items[0].windows.items.len);
    {
        var cmd = try parse("new-window edit", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), server.sessions.items[0].windows.items.len);
}

test "send-keys writes to active pane" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var cmd = try parse("new-session test", testing.allocator);
        defer cmd.deinit(testing.allocator);
        _ = cmd.exec(&server);
    }
    {
        var cmd = try parse("send-keys hello", testing.allocator);
        defer cmd.deinit(testing.allocator);
        const result = cmd.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    const pane = server.sessions.items[0].active_window.?.active_pane.?;
    try testing.expectEqual(@as(u21, 'h'), pane.screen.grid.getCell(0, 0).char);
}

test "exec on unknown session returns error" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    var cmd = try parse("send-keys hello", testing.allocator);
    defer cmd.deinit(testing.allocator);
    const result = cmd.exec(&server);
    try testing.expectEqual(.err, result);
}

test "rename-session changes name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session old", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("rename-session newname", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqualStrings("newname", server.sessions.items[0].name);
}

test "rename-window changes name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("rename-window editor", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqualStrings("editor", server.sessions.items[0].active_window.?.name);
}

test "select-window switches active" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window second", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("select-window 0", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    const session = server.sessions.items[0];
    try testing.expectEqual(session.windows.items[0], session.active_window.?);
}

test "select-window invalid index" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("select-window 99", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.err, result);
    }
}

test "select-pane switches active" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("split-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("select-pane 0", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    const window = server.sessions.items[0].active_window.?;
    try testing.expectEqual(window.panes.items[0], window.active_pane.?);
}

test "kill-pane removes pane" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("split-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const window = server.sessions.items[0].active_window.?;
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
    {
        var c = try parse("kill-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
}

test "kill-pane last pane fails" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("kill-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.err, result);
    }
}

test "rotate-window rotates panes" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("split-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const window = server.sessions.items[0].active_window.?;
    const first_pane = window.panes.items[0];
    {
        var c = try parse("rotate-window", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expect(window.panes.items[window.panes.items.len - 1] == first_pane);
}

test "next-window cycles forward" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window second", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    session.setActiveWindow(session.windows.items[0]);
    {
        var c = try parse("next-window", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(session.windows.items[1], session.active_window.?);
}

test "prev-window cycles backward" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window second", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    session.setActiveWindow(session.windows.items[1]);
    {
        var c = try parse("previous-window", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(session.windows.items[0], session.active_window.?);
}

test "last-window switches to non-active" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session test", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window second", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    try testing.expectEqual(session.windows.items[1], session.active_window.?);
    {
        var c = try parse("last-window", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(session.windows.items[0], session.active_window.?);
}

test "cmd table has 40 entries" {
    const table = cmdTable();
    try testing.expectEqual(@as(usize, 40), table.len);
}

test "lookup all new commands" {
    try testing.expect(lookup("copy-mode") != null);
    try testing.expect(lookup("list-keys") != null);
    try testing.expect(lookup("show-messages") != null);
    try testing.expect(lookup("find-window") != null);
    try testing.expect(lookup("paste-buffer") != null);
    try testing.expect(lookup("rename-session") != null);
    try testing.expect(lookup("rename-window") != null);
    try testing.expect(lookup("select-window") != null);
    try testing.expect(lookup("select-pane") != null);
    try testing.expect(lookup("kill-pane") != null);
    try testing.expect(lookup("rotate-window") != null);
    try testing.expect(lookup("next-window") != null);
    try testing.expect(lookup("previous-window") != null);
    try testing.expect(lookup("last-window") != null);
    try testing.expect(lookup("capture-pane") != null);
    try testing.expect(lookup("list-panes") != null);
    try testing.expect(lookup("list-commands") != null);
    try testing.expect(lookup("detach-client") != null);
    try testing.expect(lookup("set-option") != null);
    try testing.expect(lookup("show-options") != null);
    try testing.expect(lookup("bind-key") != null);
    try testing.expect(lookup("unbind-key") != null);
    try testing.expect(lookup("source-file") != null);
    try testing.expect(lookup("resize-pane") != null);
    try testing.expect(lookup("attach-session") != null);
    try testing.expect(lookup("switch-client") != null);
    try testing.expect(lookup("move-window") != null);
    try testing.expect(lookup("swap-window") != null);
    try testing.expect(lookup("swap-pane") != null);
    try testing.expect(lookup("join-pane") != null);
    try testing.expect(lookup("break-pane") != null);
}

test "lookup aliases" {
    try testing.expectEqualStrings("select-window", lookup("selectw").?.name);
    try testing.expectEqualStrings("select-pane", lookup("selectp").?.name);
    try testing.expectEqualStrings("kill-pane", lookup("killp").?.name);
    try testing.expectEqualStrings("rotate-window", lookup("rotatew").?.name);
    try testing.expectEqualStrings("capture-pane", lookup("capturep").?.name);
    try testing.expectEqualStrings("list-panes", lookup("lsp").?.name);
    try testing.expectEqualStrings("list-commands", lookup("lscm").?.name);
    try testing.expectEqualStrings("detach-client", lookup("detach").?.name);
    try testing.expectEqualStrings("next-window", lookup("next").?.name);
    try testing.expectEqualStrings("previous-window", lookup("prev").?.name);
    try testing.expectEqualStrings("last-window", lookup("last").?.name);
    try testing.expectEqualStrings("set-option", lookup("set").?.name);
    try testing.expectEqualStrings("show-options", lookup("show").?.name);
    try testing.expectEqualStrings("bind-key", lookup("bind").?.name);
    try testing.expectEqualStrings("unbind-key", lookup("unbind").?.name);
    try testing.expectEqualStrings("source-file", lookup("source").?.name);
    try testing.expectEqualStrings("attach-session", lookup("attach").?.name);
    try testing.expectEqualStrings("switch-client", lookup("switchc").?.name);
    try testing.expectEqualStrings("move-window", lookup("movew").?.name);
    try testing.expectEqualStrings("swap-window", lookup("swapw").?.name);
    try testing.expectEqualStrings("swap-pane", lookup("swapp").?.name);
    try testing.expectEqualStrings("join-pane", lookup("joinp").?.name);
    try testing.expectEqualStrings("break-pane", lookup("breakp").?.name);
    try testing.expectEqualStrings("paste-buffer", lookup("pasteb").?.name);
    try testing.expectEqualStrings("find-window", lookup("findw").?.name);
    try testing.expectEqualStrings("show-messages", lookup("showmsgs").?.name);
    try testing.expectEqualStrings("list-keys", lookup("lsk").?.name);
}

test "config commands exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    // Spawn session to have active state
    _ = try server.newSession("test", 80, 24);

    {
        var c = try parse("set-option -g mouse on", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expect(server.global_options.asFlag("mouse").?);
    }

    {
        var c = try parse("bind-key -n Escape split-window", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));

        const k = try @import("../key.zig").parseKeyName("Escape");
        const act = server.dispatcher.root_table.lookup(k);
        try testing.expectEqual(@import("../key_binding.zig").Action.split_vertical, act.?);
    }
}

test "query commands and resize-pane" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    _ = try server.newSession("testsession", 80, 24);

    {
        var c = try parse("list-sessions", testing.allocator);
        defer c.deinit(testing.allocator);
        server.response_buf.clearRetainingCapacity();
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "testsession") != null);
    }

    {
        var c = try parse("list-windows", testing.allocator);
        defer c.deinit(testing.allocator);
        server.response_buf.clearRetainingCapacity();
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "testsession*") != null);
    }

    {
        var c = try parse("list-panes", testing.allocator);
        defer c.deinit(testing.allocator);
        server.response_buf.clearRetainingCapacity();
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "0:") != null);
    }

    {
        var c = try parse("list-commands", testing.allocator);
        defer c.deinit(testing.allocator);
        server.response_buf.clearRetainingCapacity();
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "resize-pane") != null);
    }

    {
        var c = try parse("resize-pane -x 90 -y 30", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));

        const session = server.activeSession().?;
        const window = session.active_window orelse session.windows.items[0];
        const pane = window.active_pane.?;
        try testing.expectEqual(@as(u32, 90), pane.screen.grid.width);
        try testing.expectEqual(@as(u32, 30), pane.screen.grid.height);
    }

    {
        var c = try parse("resize-pane -D 5", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));

        const session = server.activeSession().?;
        const window = session.active_window orelse session.windows.items[0];
        const pane = window.active_pane.?;
        try testing.expectEqual(@as(u32, 35), pane.screen.grid.height);
    }
}

test "attach-session and switch-client exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    _ = try server.newSession("sess1", 80, 24);
    _ = try server.newSession("sess2", 80, 24);

    try testing.expectEqualStrings("sess1", server.activeSession().?.name);

    {
        var c = try parse("switch-client sess2", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqualStrings("sess2", server.activeSession().?.name);
    }

    {
        var c = try parse("attach-session sess1", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqualStrings("sess1", server.activeSession().?.name);
    }
}

test "move-window and swap-window exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const session = try server.newSession("test", 80, 24);
    _ = try session.newWindow(server.allocator, "win1");
    _ = try session.newWindow(server.allocator, "win2");

    // Initially: win0 (test), win1, win2
    try testing.expectEqualStrings("test", session.windows.items[0].name);
    try testing.expectEqualStrings("win1", session.windows.items[1].name);
    try testing.expectEqualStrings("win2", session.windows.items[2].name);

    // move-window 0 2 -> moves win0 to index 2
    {
        var c = try parse("move-window 0 2", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqualStrings("win1", session.windows.items[0].name);
        try testing.expectEqualStrings("win2", session.windows.items[1].name);
        try testing.expectEqualStrings("test", session.windows.items[2].name);
    }

    // swap-window 0 1 -> swaps win1 and win2
    {
        var c = try parse("swap-window 0 1", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqualStrings("win2", session.windows.items[0].name);
        try testing.expectEqualStrings("win1", session.windows.items[1].name);
        try testing.expectEqualStrings("test", session.windows.items[2].name);
    }
}

test "swap-pane, join-pane, and break-pane exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const session = try server.newSession("test", 80, 24);
    const win = session.active_window.?;
    const pane1 = win.active_pane.?;

    // Split pane1 vertically -> creates pane2
    const pane2 = try win.splitPane(server.allocator, pane1, true, 0.5);
    try testing.expectEqual(@as(usize, 2), win.panes.items.len);
    try testing.expectEqual(pane2, win.active_pane.?);

    // swap-pane 0 1
    {
        var c = try parse("swap-pane 0 1", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqual(pane2, win.panes.items[0]);
        try testing.expectEqual(pane1, win.panes.items[1]);
    }

    // break-pane -> promotes the active pane (pane1) to a new window
    win.setActivePane(pane1);
    {
        var c = try parse("break-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqual(@as(usize, 1), win.panes.items.len);
        try testing.expectEqual(@as(usize, 2), session.windows.items.len);

        const new_win = session.windows.items[1];
        try testing.expectEqual(pane1, new_win.panes.items[0]);
    }

    // join-pane from window 1 (pane1) to window 0
    session.setActiveWindow(win);
    {
        var c = try parse("join-pane 1:0", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqual(@as(usize, 2), win.panes.items.len);
        try testing.expectEqual(pane1, win.active_pane.?);
    }
}

test "paste-buffer exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const session = try server.newSession("test", 80, 24);
    const win = session.active_window.?;
    const pane = win.active_pane.?;

    server.paste_buffer = try server.allocator.dupe(u8, "hello paste buffer");

    var c = try parse("paste-buffer", testing.allocator);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(CmdResult.ok, c.exec(&server));

    // Verify cell content
    try testing.expectEqual(@as(u21, 'h'), pane.screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), pane.screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'l'), pane.screen.grid.getCell(2, 0).char);
}

test "copy-mode exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const session = try server.newSession("test", 80, 24);
    const win = session.active_window.?;
    const pane = win.active_pane.?;

    try testing.expect(pane.screen.copy_mode == null);

    var c = try parse("copy-mode", testing.allocator);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(CmdResult.ok, c.exec(&server));

    try testing.expect(pane.screen.copy_mode != null);
    try testing.expect(pane.screen.copy_mode.?.active);
}

test "find-window exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    const session = try server.newSession("test", 80, 24);
    const w1 = session.active_window.?; // Name is "test" (created in newSession)
    _ = w1;

    // Create new windows
    const w2 = try session.newWindow(server.allocator, "shell_window");
    const w3 = try session.newWindow(server.allocator, "editor_window");

    // Make sure w3 is active
    try testing.expectEqual(w3, session.active_window.?);

    // Search for case-insensitive "shell" -> should switch to w2
    {
        var c = try parse("find-window shell", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqual(w2, session.active_window.?);
    }

    // Search for case-insensitive "EDIT" -> should switch to w3
    {
        var c = try parse("find-window EDIT", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(CmdResult.ok, c.exec(&server));
        try testing.expectEqual(w3, session.active_window.?);
    }
}

test "show-messages exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    try server.addLogMessage("test log message 1");
    try server.addLogMessage("test log message 2");

    var c = try parse("show-messages", testing.allocator);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(CmdResult.ok, c.exec(&server));

    // Verify response buffer contains the log messages
    try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "test log message 1") != null);
    try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "test log message 2") != null);
}

test "list-keys exec" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var c = try parse("list-keys", testing.allocator);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(CmdResult.ok, c.exec(&server));

    // Verify response buffer contains default key bindings
    try testing.expect(std.mem.indexOf(u8, server.response_buf.items, "bind-key -T prefix") != null);
}
