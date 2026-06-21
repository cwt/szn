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

test "dispatch result deinit handles non-owned data" {
    var result = DispatchResult{
        .response_type = .err,
        .data = "static string literal",
        .allocator = testing.allocator,
        .is_owned = false,
    };
    result.deinit();
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
