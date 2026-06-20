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
    pub const list_windows = CmdEntry{
        .name = "list-windows",
        .alias = "lsw",
        .exec = cmdListWindows,
    };
};

fn cmdTable() []const *const CmdEntry {
    return comptime blk: {
        const entries = [_]*const CmdEntry{
            &commands.new_session,
            &commands.list_sessions,
            &commands.kill_session,
            &commands.new_window,
            &commands.kill_window,
            &commands.send_keys,
            &commands.split_window,
            &commands.list_windows,
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
