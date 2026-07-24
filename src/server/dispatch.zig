const std = @import("std");
const testing = std.testing;
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const cmd_mod = @import("../cmd/cmd.zig");
const protocol = @import("protocol.zig");
const Packet = protocol.Packet;
const MessageType = protocol.MessageType;
const message_reader = @import("message_reader.zig");

pub const Error = protocol.Error || error{ WriteFailed, ConnectionClosed };

pub const DispatchResult = struct {
    response_type: MessageType,
    data: []const u8,
    allocator: std.mem.Allocator,
    is_owned: bool,

    pub fn deinit(self: *DispatchResult) void {
        if (self.is_owned) {
            self.allocator.free(self.data);
        }
    }
};

pub fn dispatchCommand(allocator: std.mem.Allocator, server: *Server, cmd_line: []const u8) DispatchResult {
    // Log command line
    var cmd_log_buf: [256]u8 = undefined;
    const log_msg = std.fmt.bufPrint(&cmd_log_buf, "command: {s}", .{cmd_line}) catch "command: unknown";
    server.addLogMessage(log_msg) catch {};

    server.response_buf.clearRetainingCapacity();
    var parsed = cmd_mod.parse(cmd_line, allocator) catch |err| {
        const msg = switch (err) {
            error.UnknownCommand => "unknown command",
            error.MissingArgs => "missing arguments",
            error.TooManyArgs => "too many arguments",
            error.OutOfMemory => "out of memory",
        };
        return .{
            .response_type = .err,
            .data = msg,
            .allocator = allocator,
            .is_owned = false,
        };
    };
    defer parsed.deinit(allocator);

    const result = parsed.exec(server);
    return switch (result) {
        .ok => blk: {
            const has_buf = server.response_buf.items.len > 0;
            const duped: ?[]const u8 = if (has_buf)
                allocator.dupe(u8, server.response_buf.items) catch null
            else
                null;
            break :blk .{
                .response_type = .ready,
                .data = duped orelse "ok",
                .allocator = allocator,
                .is_owned = duped != null,
            };
        },
        .err => blk: {
            const duped: ?[]const u8 = if (server.response_buf.items.len > 0)
                allocator.dupe(u8, server.response_buf.items) catch null
            else
                null;
            break :blk .{
                .response_type = .err,
                .data = duped orelse "command failed",
                .allocator = allocator,
                .is_owned = duped != null,
            };
        },
        .wait => .{
            .response_type = .ready,
            .data = "waiting",
            .allocator = allocator,
            .is_owned = false,
        },
        .stop => .{
            .response_type = .exit,
            .data = &[1]u8{0},
            .allocator = allocator,
            .is_owned = false,
        },
    };
}

pub fn sendResponse(fd: i32, result: *const DispatchResult) Error!void {
    const pkt = Packet.make(result.response_type, result.data);
    var hdr_buf: [5]u8 = undefined;
    pkt.header.encode(&hdr_buf);

    // Write header — retry partial writes
    var hdr_remaining: []const u8 = hdr_buf[0..];
    while (hdr_remaining.len > 0) {
        const n = std.c.write(fd, hdr_remaining.ptr, hdr_remaining.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.ConnectionClosed;
        hdr_remaining = hdr_remaining[@intCast(n)..];
    }

    // Write data body — retry partial writes
    if (result.data.len > 0) {
        var body_remaining: []const u8 = result.data;
        while (body_remaining.len > 0) {
            const n = std.c.write(fd, body_remaining.ptr, body_remaining.len);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.ConnectionClosed;
            body_remaining = body_remaining[@intCast(n)..];
        }
    }
}

test "dispatch new-session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var result = dispatchCommand(testing.allocator, &server, "new-session test");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
    try testing.expectEqualStrings("ok", result.data);
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "dispatch unknown command" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var result = dispatchCommand(testing.allocator, &server, "foobar");
    defer result.deinit();

    try testing.expectEqual(MessageType.err, result.response_type);
    try testing.expectEqualStrings("unknown command", result.data);
}

test "dispatch kill-session" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r = dispatchCommand(testing.allocator, &server, "new-session test");
        defer r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);

    var result = dispatchCommand(testing.allocator, &server, "kill-session test");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
    try testing.expectEqual(@as(usize, 0), server.sessions.items.len);
}

test "dispatch new-window" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r = dispatchCommand(testing.allocator, &server, "new-session test");
        defer r.deinit();
    }

    var result = dispatchCommand(testing.allocator, &server, "new-window edit");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
    try testing.expectEqual(@as(usize, 2), server.sessions.items[0].windows.items.len);
}

test "dispatch split-window" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r = dispatchCommand(testing.allocator, &server, "new-session test");
        defer r.deinit();
    }

    var result = dispatchCommand(testing.allocator, &server, "split-window");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
    const window = server.sessions.items[0].active_window.?;
    try testing.expectEqual(@as(usize, 2), window.panes.items.len);
}

test "dispatch missing args" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    var result = dispatchCommand(testing.allocator, &server, "send-keys");
    defer result.deinit();

    try testing.expectEqual(MessageType.err, result.response_type);
    try testing.expectEqualStrings("missing arguments", result.data);
}

test "dispatch send-keys" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r = dispatchCommand(testing.allocator, &server, "new-session test");
        defer r.deinit();
    }

    var result = dispatchCommand(testing.allocator, &server, "send-keys hello");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
}

test "dispatch multiple commands in sequence" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r1 = dispatchCommand(testing.allocator, &server, "new-session alpha");
        defer r1.deinit();
        try testing.expectEqual(MessageType.ready, r1.response_type);
    }

    {
        var r2 = dispatchCommand(testing.allocator, &server, "new-session beta");
        defer r2.deinit();
        try testing.expectEqual(MessageType.ready, r2.response_type);
    }

    try testing.expectEqual(@as(usize, 2), server.sessions.items.len);

    {
        var r3 = dispatchCommand(testing.allocator, &server, "kill-session alpha");
        defer r3.deinit();
        try testing.expectEqual(MessageType.ready, r3.response_type);
    }

    try testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "dispatch result deinit handles non-owned data" {
    var result = DispatchResult{
        .response_type = .err,
        .data = "static string literal",
        .allocator = testing.allocator,
        .is_owned = false,
    };
    result.deinit();
}

test "sendResponse writes header and data" {
    var pipe_fds: [2]i32 = undefined;
    if (std.c.pipe(&pipe_fds) < 0) return error.Skip;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    const result = DispatchResult{
        .response_type = .ready,
        .data = "hello",
        .allocator = testing.allocator,
        .is_owned = false,
    };
    try sendResponse(pipe_fds[1], &result);

    var buf: [256]u8 = undefined;
    const n = std.c.read(pipe_fds[0], &buf, buf.len);
    if (n < 0) return error.Skip;
    // header: 4-byte little-endian len (5 + 5 = 10) + 1-byte type
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u8, @intFromEnum(MessageType.ready)), buf[4]);
    // body follows
    try testing.expectEqualStrings("hello", buf[5..10]);
}

test "dispatch kill-window" {
    var server = try Server.init(testing.allocator);
    defer server.deinit();

    {
        var r = dispatchCommand(testing.allocator, &server, "new-session test");
        defer r.deinit();
    }
    {
        var r = dispatchCommand(testing.allocator, &server, "new-window edit");
        defer r.deinit();
    }

    try testing.expectEqual(@as(usize, 2), server.sessions.items[0].windows.items.len);

    var result = dispatchCommand(testing.allocator, &server, "kill-window 0");
    defer result.deinit();

    try testing.expectEqual(MessageType.ready, result.response_type);
}

test "sendResponse write failure handles 0 or negative return — bug #227" {
    const result = DispatchResult{
        .response_type = .ready,
        .data = "hello",
        .allocator = testing.allocator,
        .is_owned = false,
    };
    // Passing invalid / closed fd (-1) must fail immediately without spinning
    try testing.expectError(error.WriteFailed, sendResponse(-1, &result));
}
