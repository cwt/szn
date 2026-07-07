const std = @import("std");
const c = std.c;
const protocol = @import("../server/protocol.zig");
const connect = @import("connect.zig");

pub const Error = protocol.Error || connect.Error || error{ ConnectionClosed, ReadFailed, WriteFailed, InvalidPacket, TermTooLong, PacketTooLarge };

fn fdWrite(fd: i32, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.write(fd, buf.ptr + off, buf.len - off);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        off += @as(usize, @intCast(n));
    }
}

fn fdRead(fd: i32, buf: []u8) Error!usize {
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @as(usize, @intCast(n));
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: i32,

    pub fn init(allocator: std.mem.Allocator) Error!Client {
        const fd = try connect.connectToServer();
        return Client{ .allocator = allocator, .fd = fd };
    }

    pub fn deinit(self: *Client) void {
        _ = c.close(self.fd);
    }

    pub fn sendIdentify(self: *Client, term: []const u8) Error!void {
        if (term.len > 64) return error.TermTooLong;
        try self.sendPacket(.identify_term, term);
    }

    pub fn sendCommand(self: *Client, cmd: []const u8) Error!void {
        try self.sendPacket(.command, cmd);
    }

    fn sendPacket(self: *Client, msg_type: protocol.MessageType, data: []const u8) Error!void {
        if (5 + data.len > protocol.MAX_CLIENT_PACKET_SIZE) return error.PacketTooLarge;
        const pkt = protocol.Packet.make(msg_type, data);
        var buf: [protocol.MAX_CLIENT_PACKET_SIZE]u8 = undefined;
        const serialized = pkt.serialize(&buf);
        try fdWrite(self.fd, serialized);
    }

    pub fn recvPacket(self: *Client) Error!protocol.Packet {
        var hdr: [5]u8 = undefined;
        var off: usize = 0;
        while (off < 5) {
            const n = try fdRead(self.fd, hdr[off..]);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }

        const len = std.mem.readInt(u32, hdr[0..4], .little);
        if (len < 5) return error.InvalidPacket;
        if (len > protocol.MAX_PACKET_SIZE) return error.PacketTooLarge;
        const body_len = len - 5;

        // Dynamically allocate body buffer to support arbitrary reply sizes
        const body = try self.allocator.alloc(u8, body_len);
        errdefer self.allocator.free(body);

        off = 0;
        while (off < body_len) {
            const n = try fdRead(self.fd, body[off..body_len]);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }

        const msg_type_byte = hdr[4];
        _ = protocol.MessageType.fromByte(msg_type_byte) orelse return error.InvalidPacket;
        return protocol.Packet{
            .header = .{
                .length = len,
                .msg_type = msg_type_byte,
            },
            .data = body,
            .is_owned = true,
        };
    }
};

test "sendPacket rejects oversized data" {
    const testing = std.testing;

    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client{ .allocator = testing.allocator, .fd = fds[1] };

    const big_data = try testing.allocator.alloc(u8, protocol.MAX_CLIENT_PACKET_SIZE);
    defer testing.allocator.free(big_data);
    @memset(big_data, 'A');

    try testing.expectError(error.PacketTooLarge, client.sendPacket(.command, big_data));
}

test "recvPacket rejects oversized length" {
    const testing = std.testing;

    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client{ .allocator = testing.allocator, .fd = fds[0] };

    // Write a header with a huge length (MAX_PACKET_SIZE + 1)
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], protocol.MAX_PACKET_SIZE + 1, .little);
    hdr[4] = @intFromEnum(protocol.MessageType.output);
    const n = std.c.write(fds[1], &hdr, hdr.len);
    try testing.expectEqual(@as(isize, 5), n);

    try testing.expectError(error.PacketTooLarge, client.recvPacket());
}

test "fdWrite retries on partial write — bug #93" {
    const testing = std.testing;

    // Use a pipe — partial writes on pipes are rare with small buffers,
    // but we test that fdWrite handles the full data correctly.
    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    // Write data that fits in the pipe buffer
    const data = "hello world";
    try fdWrite(fds[1], data);

    // Read it back
    var buf: [64]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try testing.expectEqual(@as(isize, @intCast(data.len)), n);
    try testing.expectEqualStrings(data, buf[0..@as(usize, @intCast(n))]);
}

test "sendIdentify transmits raw term and rejects term longer than 64 bytes" {
    const testing = std.testing;

    var fds: [2]i32 = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client{ .allocator = testing.allocator, .fd = fds[1] };

    // 1. Verify too long term rejection
    const long_term = try testing.allocator.alloc(u8, 100);
    defer testing.allocator.free(long_term);
    @memset(long_term, 'x');
    try testing.expectError(error.TermTooLong, client.sendIdentify(long_term));

    // 2. Verify raw term string is sent correctly
    try client.sendIdentify("xterm-256color");
    var buf: [128]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try testing.expect(n > 0);
    const read_bytes = buf[0..@as(usize, @intCast(n))];
    const parsed = try protocol.Packet.deserialize(read_bytes);
    try testing.expectEqual(@as(u8, @intFromEnum(protocol.MessageType.identify_term)), parsed.header.msg_type);
    try testing.expectEqualStrings("xterm-256color", parsed.data);
}
