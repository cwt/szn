const std = @import("std");
const testing = std.testing;

const Server = @import("server/server.zig").Server;
const parse = @import("cmd/cmd.zig").parse;
const lookup = @import("cmd/cmd.zig").lookup;

/// Helper: create a server with one session and return it
fn setupServer(allocator: std.mem.Allocator) !Server {
    var server = try Server.init(allocator);
    {
        var c = try parse("new-session test", allocator);
        defer c.deinit(allocator);
        if (c.exec(&server) != .ok) return error.ExecFailed;
    }
    return server;
}

test "full session lifecycle" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);

    {
        var c = try parse("new-session work", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
    try testing.expectEqualStrings("work", server.sessions.items[0].name);

    {
        var c = try parse("rename-session project", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("project", server.sessions.items[0].name);

    {
        var c = try parse("kill-session", testing.allocator);
        defer c.deinit(testing.allocator);
        const result = c.exec(&server);
        try testing.expectEqual(.ok, result);
    }
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "multi-window navigation" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();

    {
        var c = try parse("new-window editor", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window terminal", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    try testing.expectEqual(@as(usize, 3), session.windows.items.len);

    try testing.expectEqualStrings("terminal", session.active_window.?.name);

    {
        var c = try parse("rename-window shell", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("shell", session.active_window.?.name);

    {
        var c = try parse("select-window 0", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("test", session.active_window.?.name);

    {
        var c = try parse("next-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("editor", session.active_window.?.name);

    {
        var c = try parse("previous-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("test", session.active_window.?.name);

    {
        var c = try parse("last-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqualStrings("editor", session.active_window.?.name);

    {
        var c = try parse("kill-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);
}

test "pane split and select cycle" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();

    const window = server.sessions.items[0].active_window.?;
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);

    {
        var c = try parse("split-window -v 50", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);

    {
        var c = try parse("split-window -h 30", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 3), window.panes.items.len);

    {
        var c = try parse("select-pane 0", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(window.panes.items[0], window.active_pane.?);

    {
        var c = try parse("select-pane 1", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const second_pane = window.active_pane;
    {
        var c = try parse("rotate-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(window.panes.items[0], second_pane);
    try testing.expectEqual(window.panes.items[0], window.active_pane.?);

    {
        var c = try parse("kill-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);

    {
        var c = try parse("kill-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 1), window.panes.items.len);
}

test "send-keys writes to grid and output integrates with screen" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();

    const pane = server.sessions.items[0].active_window.?.active_pane.?;

    {
        var c = try parse("send-keys Hello", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }

    try testing.expectEqual(@as(u21, 'H'), pane.screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), pane.screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'l'), pane.screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'l'), pane.screen.grid.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'o'), pane.screen.grid.getCell(4, 0).char);

    {
        var c = try parse("send-keys World", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }

    try testing.expectEqual(@as(u21, 'W'), pane.screen.grid.getCell(5, 0).char);
    try testing.expectEqual(@as(u21, 'o'), pane.screen.grid.getCell(6, 0).char);
    try testing.expectEqual(@as(u21, 'd'), pane.screen.grid.getCell(9, 0).char);
}

test "kill-window triggers active_window update" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();

    {
        var c = try parse("new-window second", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-window third", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    try testing.expectEqual(@as(usize, 3), session.windows.items.len);

    session.setActiveWindow(session.windows.items[1]);

    {
        var c = try parse("kill-window", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);
}

test "command table completeness" {
    try testing.expect(lookup("new-session") != null);
    try testing.expect(lookup("kill-session") != null);
    try testing.expect(lookup("rename-session") != null);
    try testing.expect(lookup("new-window") != null);
    try testing.expect(lookup("kill-window") != null);
    try testing.expect(lookup("rename-window") != null);
    try testing.expect(lookup("select-window") != null);
    try testing.expect(lookup("next-window") != null);
    try testing.expect(lookup("previous-window") != null);
    try testing.expect(lookup("last-window") != null);
    try testing.expect(lookup("split-window") != null);
    try testing.expect(lookup("select-pane") != null);
    try testing.expect(lookup("kill-pane") != null);
    try testing.expect(lookup("rotate-window") != null);
    try testing.expect(lookup("send-keys") != null);
    try testing.expect(lookup("capture-pane") != null);
    try testing.expect(lookup("list-sessions") != null);
    try testing.expect(lookup("list-windows") != null);
    try testing.expect(lookup("list-panes") != null);
    try testing.expect(lookup("list-commands") != null);
    try testing.expect(lookup("detach-client") != null);

    try testing.expect(lookup("new") != null);
    try testing.expect(lookup("ls") != null);
    try testing.expect(lookup("neww") != null);
    try testing.expect(lookup("killw") != null);
    try testing.expect(lookup("selectw") != null);
    try testing.expect(lookup("next") != null);
    try testing.expect(lookup("prev") != null);
    try testing.expect(lookup("last") != null);
    try testing.expect(lookup("send") != null);
    try testing.expect(lookup("splitw") != null);
    try testing.expect(lookup("selectp") != null);
    try testing.expect(lookup("killp") != null);
    try testing.expect(lookup("rotatew") != null);
    try testing.expect(lookup("capturep") != null);
    try testing.expect(lookup("lsw") != null);
    try testing.expect(lookup("lsp") != null);
    try testing.expect(lookup("lscm") != null);
    try testing.expect(lookup("detach") != null);
}

test "error on invalid command" {
    if (parse("nonexistent-command", testing.allocator)) |_| {
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(error.UnknownCommand, err);
    }
}

test "error on missing args" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();
    inline for (&.{ "send-keys", "rename-session", "select-window", "select-pane" }) |name| {
        if (parse(name, testing.allocator)) |_| {
            try testing.expect(false);
        } else |err| {
            try testing.expectEqual(error.MissingArgs, err);
        }
    }
}

test "select-window out of range" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("select-window 99", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(.err, c.exec(&server));
    }
    {
        var c = try parse("select-pane 99", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(.err, c.exec(&server));
    }
}

test "double new-session creates two sessions" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    {
        var c = try parse("new-session a", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    {
        var c = try parse("new-session b", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    try testing.expectEqual(@as(usize, 2), server.sessions.items.len);
    try testing.expectEqualStrings("b", server.sessions.items[0].name);
    try testing.expectEqualStrings("a", server.sessions.items[1].name);
}

test "kill non-last pane in multi-window" {
    var server = try setupServer(testing.allocator);
    defer server.deinit();

    {
        var c = try parse("new-window extra", testing.allocator);
        defer c.deinit(testing.allocator);
        _ = c.exec(&server);
    }
    const session = server.sessions.items[0];
    try testing.expectEqual(@as(usize, 2), session.windows.items.len);

    session.setActiveWindow(session.windows.items[0]);
    {
        var c = try parse("kill-pane", testing.allocator);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(.err, c.exec(&server));
    }
}
