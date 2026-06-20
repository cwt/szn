const std = @import("std");
const c = std.c;
const testing = std.testing;
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const Pane = window_mod.Pane;
const loop_mod = @import("loop.zig");
const Loop = loop_mod.Loop;
const socket_mod = @import("socket.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(*Session) = .empty,
    next_session_id: u32 = 1,
    next_window_id: u32 = 1,
    next_pane_id: u32 = 1,
    listener_fd: ?i32 = null,
    client_fds: std.ArrayListUnmanaged(i32) = .empty,
    stdin_fd: ?i32 = null,
    loop: Loop = .{},

    pub fn init(allocator: std.mem.Allocator) !Server {
        return Server{ .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        self.loop.deinit(self.allocator);
        for (self.sessions.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.sessions.deinit(self.allocator);
        for (self.client_fds.items) |fd| {
            _ = c.close(fd);
        }
        self.client_fds.deinit(self.allocator);
        if (self.listener_fd) |fd| {
            socket_mod.closeAndUnlink(fd);
        }
    }

    pub fn listen(self: *Server) !void {
        const fd = try socket_mod.createListener();
        self.listener_fd = fd;
        try self.loop.addFd(self.allocator, fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(self));
    }

    pub fn run(self: *Server) !void {
        const events = try self.loop.pollOnce(100);
        for (events) |ev| {
            if (self.handlePtyEvent(ev)) continue;

            const has_in = (ev.revents & @as(i16, @intCast(std.posix.POLL.IN))) != 0;
            const has_hup = (ev.revents & @as(i16, @intCast(std.posix.POLL.HUP))) != 0;
            const has_err = (ev.revents & @as(i16, @intCast(std.posix.POLL.ERR))) != 0;

            if (self.stdin_fd) |sfd| {
                if (ev.fd == sfd) {
                    if (has_in) {
                        self.handleStdin() catch |err| {
                            std.log.err("stdin error: {any}", .{err});
                        };
                    } else if (has_hup or has_err) {
                        self.loop.running = false;
                        self.loop.removeFd(ev.fd);
                    }
                    continue;
                }
            }

            if (self.listener_fd) |lfd| {
                if (ev.fd == lfd) {
                    if (has_in) {
                        self.handleAccept() catch |err| {
                            std.log.err("accept failed: {any}", .{err});
                        };
                    } else if (has_hup or has_err) {
                        self.loop.removeFd(ev.fd);
                    }
                    continue;
                }
            }

            var is_client = false;
            for (self.client_fds.items) |cfd| {
                if (ev.fd == cfd) {
                    is_client = true;
                    if (has_in) {
                        self.handleClient(cfd) catch |err| {
                            std.log.err("client {d} error: {any}", .{ cfd, err });
                        };
                    } else if (has_hup or has_err) {
                        self.removeClient(cfd);
                    }
                    break;
                }
            }
            if (is_client) continue;
        }
    }

    fn handlePtyEvent(self: *Server, ev: loop_mod.PollEvent) bool {
        if (ev.fd == self.listener_fd or ev.fd == self.stdin_fd) return false;
        for (self.client_fds.items) |cfd| {
            if (ev.fd == cfd) return false;
        }
        const pane: *Pane = @alignCast(@ptrCast(ev.udata orelse return false));
        const has_in = (ev.revents & @as(i16, @intCast(std.posix.POLL.IN))) != 0;
        const has_hup = (ev.revents & @as(i16, @intCast(std.posix.POLL.HUP))) != 0;
        const has_err = (ev.revents & @as(i16, @intCast(std.posix.POLL.ERR))) != 0;

        if (has_in) {
            pane.feedPty() catch |err| {
                if (err == error.ProcessExited) {
                    self.loop.removeFd(ev.fd);
                } else {
                    std.log.warn("pty feed error: {any}", .{err});
                    self.loop.removeFd(ev.fd);
                }
            };
        } else if (has_hup or has_err) {
            if (pane.pty) |*pty| {
                pty.deinit();
            }
            pane.pty = null;
            self.loop.removeFd(ev.fd);
        }
        return true;
    }

    fn handleStdin(self: *Server) !void {
        var buf: [4096]u8 = undefined;
        const n = c.read(std.c.STDIN_FILENO, &buf, buf.len);
        if (n <= 0) {
            self.loop.running = false;
            return;
        }
        const session = self.activeSession() orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        if (pane.pty) |*pty| {
            pty.writeInput(buf[0..@intCast(n)]) catch |err| {
                if (err == error.WriteFailed) return;
                return err;
            };
        }
    }

    pub fn watchPanePty(self: *Server, pane: *Pane) !void {
        const pty = pane.pty orelse return;
        try self.loop.addFd(self.allocator, pty.master, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(pane));
    }

    fn handleAccept(self: *Server) !void {
        const fd = try socket_mod.acceptClient(self.listener_fd.?);
        try self.client_fds.append(self.allocator, fd);
        try self.loop.addFd(self.allocator, fd, @as(i16, @intCast(std.posix.POLL.IN)), @ptrCast(self));
    }

    fn handleClient(self: *Server, fd: i32) !void {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| {
            self.removeClient(fd);
            return err;
        };
        if (n == 0) {
            self.removeClient(fd);
            return;
        }
        _ = buf[0..n];
    }

    fn removeClient(self: *Server, fd: i32) void {
        self.loop.removeFd(fd);
        for (self.client_fds.items, 0..) |cfd, i| {
            if (cfd == fd) {
                _ = self.client_fds.swapRemove(i);
                break;
            }
        }
        _ = c.close(fd);
    }

    pub fn newSession(self: *Server, name: []const u8, width: u32, height: u32) !*Session {
        const session = try self.allocator.create(Session);
        session.* = try Session.init(self.allocator, self.next_session_id, name, width, height);
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
    const s = try server.newSession("test", 80, 24);
    try testing.expectEqualStrings("test", s.name);
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "kill session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("one", 80, 24);
    _ = try server.newSession("two", 80, 24);
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
    _ = try server.newSession("first", 80, 24);
    const s = try server.newSession("second", 80, 24);
    _ = s;
    try testing.expectEqualStrings("first", server.activeSession().?.name);
}

test "get session by name" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("alpha", 80, 24);
    _ = try server.newSession("beta", 80, 24);
    try testing.expect(server.getSession("alpha") != null);
    try testing.expect(server.getSession("beta") != null);
    try testing.expect(server.getSession("gamma") == null);
}

test "kill all sessions" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    _ = try server.newSession("a", 80, 24);
    _ = try server.newSession("b", 80, 24);
    _ = try server.newSession("c", 80, 24);
    try testing.expectEqual(@as(usize, 3), server.sessions.items.len);
    server.killAllSessions();
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "session windows have correct size" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s = try server.newSession("test", 80, 24);
    try testing.expectEqual(@as(u32, 80), s.windows.items[0].width);
    try testing.expectEqual(@as(u32, 24), s.windows.items[0].height);
}

test "new session increments id" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    const s1 = try server.newSession("a", 80, 24);
    const s2 = try server.newSession("b", 80, 24);
    try testing.expect(s1.id < s2.id);
}

test "server listen creates socket" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();
    try server.listen();
    try testing.expect(server.listener_fd != null);
}
