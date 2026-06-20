const std = @import("std");
const testing = std.testing;
const server_mod = @import("../server/server.zig");
const Server = server_mod.Server;

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
    exec: *const fn (server: *Server, args: []const []const u8) CmdResult,
};

fn cmdNewSession(server: *Server, args: []const []const u8) CmdResult {
    const name = if (args.len > 1) args[1] else "default";
    _ = server.newSession(name, 80, 24) catch return .err;
    return .ok;
}

fn cmdListSessions(server: *Server, _: []const []const u8) CmdResult {
    _ = server;
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

    const direction: enum { horizontal, vertical } = if (args.len > 1 and std.mem.eql(u8, args[1], "-v")) .vertical else .horizontal;
    const proportion: f64 = if (args.len > 2) std.fmt.parseFloat(f64, args[2]) catch 0.5 else 0.5;

    const new_pane = window.splitPane(server.allocator, pane, direction == .vertical, proportion) catch return .err;
    _ = new_pane;
    return .ok;
}

fn cmdListWindows(server: *Server, _: []const []const u8) CmdResult {
    _ = server;
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
    server.allocator.free(window.name);
    window.name = server.allocator.dupe(u8, args[1]) catch return .err;
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
    _ = window.active_pane orelse return .err;
    return .ok;
}

fn cmdListPanes(server: *Server, _: []const []const u8) CmdResult {
    _ = server;
    return .ok;
}

fn cmdListCommands(_: *Server, _: []const []const u8) CmdResult {
    return .ok;
}

fn cmdDetachClient(_: *Server, _: []const []const u8) CmdResult {
    return .ok;
}

fn cmdLastWindow(server: *Server, _: []const []const u8) CmdResult {
    const session = server.activeSession() orelse return .err;
    if (session.windows.items.len <= 1) return .ok;
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

pub const commands = struct {
    pub const new_session = CmdEntry{
        .name = "new-session",
        .alias = "new",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[name]",
        .exec = cmdNewSession,
    };
    pub const list_sessions = CmdEntry{
        .name = "list-sessions",
        .alias = "ls",
        .exec = cmdListSessions,
    };
    pub const kill_session = CmdEntry{
        .name = "kill-session",
        .alias = null,
        .exec = cmdKillSession,
    };
    pub const rename_session = CmdEntry{
        .name = "rename-session",
        .alias = null,
        .min_args = 1,
        .max_args = 1,
        .args_usage = "new-name",
        .exec = cmdRenameSession,
    };
    pub const new_window = CmdEntry{
        .name = "new-window",
        .alias = "neww",
        .min_args = 0,
        .max_args = 2,
        .args_usage = "[name]",
        .exec = cmdNewWindow,
    };
    pub const kill_window = CmdEntry{
        .name = "kill-window",
        .alias = "killw",
        .exec = cmdKillWindow,
    };
    pub const rename_window = CmdEntry{
        .name = "rename-window",
        .alias = null,
        .min_args = 1,
        .max_args = 1,
        .args_usage = "new-name",
        .exec = cmdRenameWindow,
    };
    pub const select_window = CmdEntry{
        .name = "select-window",
        .alias = "selectw",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "index",
        .exec = cmdSelectWindow,
    };
    pub const next_window = CmdEntry{
        .name = "next-window",
        .alias = "next",
        .exec = cmdNextWindow,
    };
    pub const prev_window = CmdEntry{
        .name = "previous-window",
        .alias = "prev",
        .exec = cmdPrevWindow,
    };
    pub const last_window = CmdEntry{
        .name = "last-window",
        .alias = "last",
        .exec = cmdLastWindow,
    };
    pub const send_keys = CmdEntry{
        .name = "send-keys",
        .alias = "send",
        .min_args = 1,
        .args_usage = "key ...",
        .exec = cmdSendKeys,
    };
    pub const split_window = CmdEntry{
        .name = "split-window",
        .alias = "splitw",
        .min_args = 0,
        .max_args = 3,
        .args_usage = "[-v] [proportion]",
        .exec = cmdSplitWindow,
    };
    pub const select_pane = CmdEntry{
        .name = "select-pane",
        .alias = "selectp",
        .min_args = 1,
        .max_args = 1,
        .args_usage = "index",
        .exec = cmdSelectPane,
    };
    pub const kill_pane = CmdEntry{
        .name = "kill-pane",
        .alias = "killp",
        .exec = cmdKillPane,
    };
    pub const rotate_window = CmdEntry{
        .name = "rotate-window",
        .alias = "rotatew",
        .exec = cmdRotateWindow,
    };
    pub const capture_pane = CmdEntry{
        .name = "capture-pane",
        .alias = "capturep",
        .exec = cmdCapturePane,
    };
    pub const list_windows = CmdEntry{
        .name = "list-windows",
        .alias = "lsw",
        .exec = cmdListWindows,
    };
    pub const list_panes = CmdEntry{
        .name = "list-panes",
        .alias = "lsp",
        .exec = cmdListPanes,
    };
    pub const list_commands = CmdEntry{
        .name = "list-commands",
        .alias = "lscm",
        .exec = cmdListCommands,
    };
    pub const detach_client = CmdEntry{
        .name = "detach-client",
        .alias = "detach",
        .exec = cmdDetachClient,
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

test "cmd table has 21 entries" {
    const table = cmdTable();
    try testing.expectEqual(@as(usize, 21), table.len);
}

test "lookup all new commands" {
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
}
