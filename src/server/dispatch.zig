const std = @import("std");
const testing = std.testing;
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const cmd_mod = @import("../cmd/cmd.zig");
const protocol = @import("protocol.zig");
const Packet = protocol.Packet;
const MessageType = protocol.MessageType;
const message_reader = @import("message_reader.zig");

pub const DispatchResult = struct {
    response_type: MessageType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DispatchResult) void {
        self.allocator.free(self.data);
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
            .data = allocator.dupe(u8, msg) catch "error",
            .allocator = allocator,
        };
    };
    defer parsed.deinit(allocator);

    const result = parsed.exec(server);
    return switch (result) {
        .ok => .{
            .response_type = .ready,
            .data = if (server.response_buf.items.len > 0)
                allocator.dupe(u8, server.response_buf.items) catch allocator.dupe(u8, "ok") catch "ok"
            else
                allocator.dupe(u8, "ok") catch "ok",
            .allocator = allocator,
        },
        .err => .{
            .response_type = .err,
            .data = if (server.response_buf.items.len > 0)
                allocator.dupe(u8, server.response_buf.items) catch allocator.dupe(u8, "command failed") catch "error"
            else
                allocator.dupe(u8, "command failed") catch "error",
            .allocator = allocator,
        },
        .wait => .{
            .response_type = .ready,
            .data = allocator.dupe(u8, "waiting") catch "waiting",
            .allocator = allocator,
        },
        .stop => .{
            .response_type = .exit,
            .data = allocator.dupe(u8, &[_]u8{0}) catch &[0]u8{},
            .allocator = allocator,
        },
    };
}

pub fn sendResponse(fd: i32, result: *const DispatchResult) !void {
    const pkt = Packet.make(result.response_type, result.data);
    var hdr_buf: [5]u8 = undefined;
    pkt.header.encode(&hdr_buf);
    
    // Write header
    var n = std.c.write(fd, &hdr_buf, 5);
    if (n < 5) return error.WriteFailed;
    
    // Write data body directly from slice
    if (result.data.len > 0) {
        n = std.c.write(fd, result.data.ptr, result.data.len);
        if (n < @as(isize, @intCast(result.data.len))) return error.WriteFailed;
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
