const std = @import("std");
const testing = std.testing;
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const Pane = window_mod.Pane;
const layout_mod = @import("../layout.zig");
const Layout = layout_mod.Layout;
const SplitDir = layout_mod.SplitDir;

pub const Server = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(*Session) = .empty,
    next_session_id: u32 = 1,
    next_window_id: u32 = 1,
    next_pane_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) !Server {
        return Server{ .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        for (self.sessions.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn newSession(self: *Server, name: []const u8) !*Session {
        const session = try self.allocator.create(Session);
        session.* = try Session.init(self.allocator, self.next_session_id, name, 80, 24);
        self.next_session_id += 1;
        try self.sessions.append(self.allocator, session);
        return session;
    }

    pub fn killSession(self: *Server, name: []const u8) !void {
        const idx = for (self.sessions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) break i;
        } else return error.SessionNotFound;
        var session = self.sessions.swapRemove(idx);
        session.deinit(self.allocator);
        self.allocator.destroy(session);
    }

    pub fn killAllSessions(self: *Server) void {
        for (self.sessions.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.sessions.clearRetainingCapacity();
    }

    pub fn activeSession(self: *Server) ?*Session {
        return if (self.sessions.items.len > 0) self.sessions.items[0] else null;
    }

    pub fn getSession(self: *Server, name: []const u8) ?*Session {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

pub const ServerError = error{
    SessionNotFound,
};

test "create empty server" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "new session creates session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s = try server.newSession("test");
    try testing.expectEqualStrings("test", s.name);
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "kill session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("one");
    _ = try server.newSession("two");
    try testing.expectEqual(@as(usize, 2), server.sessions.items.len);
    try server.killSession("one");
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
    try testing.expectEqualStrings("two", server.sessions.items[0].name);
}

test "kill unknown session returns error" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expectError(error.SessionNotFound, server.killSession("nonexistent"));
}

test "active session returns first session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try testing.expect(server.activeSession() == null);
    _ = try server.newSession("first");
    const s = try server.newSession("second");
    _ = s;
    try testing.expectEqualStrings("first", server.activeSession().?.name);
}

test "get session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("alpha");
    _ = try server.newSession("beta");
    try testing.expect(server.getSession("alpha") != null);
    try testing.expect(server.getSession("beta") != null);
    try testing.expect(server.getSession("gamma") == null);
}

test "kill all sessions" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("a");
    _ = try server.newSession("b");
    _ = try server.newSession("c");
    try testing.expectEqual(@as(usize, 3), server.sessions.items.len);
    server.killAllSessions();
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "session windows have correct size" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s = try server.newSession("test");
    try testing.expectEqual(@as(u32, 80), s.windows.items[0].width);
    try testing.expectEqual(@as(u32, 24), s.windows.items[0].height);
}

test "new session increments id" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s1 = try server.newSession("a");
    const s2 = try server.newSession("b");
    try testing.expect(s1.id < s2.id);
}
