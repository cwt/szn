const std = @import("std");
const testing = std.testing;

pub const Error = error{
    InvalidPacket,
    SizeMismatch,
    InvalidData,
};

pub const MAX_PACKET_SIZE = 1024 * 1024; // 1 MiB (server-to-client maximum)
pub const MAX_CLIENT_PACKET_SIZE = 8192; // 8 KiB (client-to-server maximum)

pub const MessageType = enum(u8) {
    identify_term = 0x01, // Payload: Opaque terminal name string (e.g. "xterm-256color")
    command = 0x04,
    resize = 0x05,
    detach = 0x06,
    stdin_data = 0x08,

    ready = 0x80,
    output = 0x81,
    exit = 0x82,
    err = 0x83,

    pub fn isRequest(self: MessageType) bool {
        return @intFromEnum(self) < 0x80;
    }

    pub fn fromByte(byte: u8) ?MessageType {
        return switch (byte) {
            0x01 => .identify_term,
            0x04 => .command,
            0x05 => .resize,
            0x06 => .detach,
            0x08 => .stdin_data,
            0x80 => .ready,
            0x81 => .output,
            0x82 => .exit,
            0x83 => .err,
            else => return null,
        };
    }
};

pub const Header = struct {
    length: u32,
    msg_type: u8,

    pub fn encode(self: Header, buf: *[5]u8) void {
        std.mem.writeInt(u32, buf[0..4], self.length, .little);
        buf[4] = self.msg_type;
    }
};

pub const Packet = struct {
    header: Header,
    data: []const u8,
    is_owned: bool = false,

    pub fn deinit(self: *Packet, allocator: std.mem.Allocator) void {
        if (self.is_owned) {
            allocator.free(self.data);
            self.is_owned = false;
        }
    }

    pub fn serialize(self: Packet, buf: []u8) []u8 {
        var hdr_buf: [5]u8 = undefined;
        self.header.encode(&hdr_buf);
        @memcpy(buf[0..5], &hdr_buf);
        if (self.data.len > 0) {
            @memcpy(buf[5..][0..self.data.len], self.data);
        }
        return buf[0 .. 5 + self.data.len];
    }

    pub fn deserialize(buf: []const u8) Error!Packet {
        if (buf.len < 5) return error.InvalidPacket;
        const len = std.mem.readInt(u32, buf[0..4], .little);
        if (len != buf.len) return error.SizeMismatch;
        return Packet{
            .header = .{
                .length = len,
                .msg_type = buf[4],
            },
            .data = buf[5..],
        };
    }

    pub fn make(msg_type: MessageType, data: []const u8) Packet {
        const total_len = 5 + data.len;
        return Packet{
            .header = .{
                .length = if (total_len > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(total_len)),
                .msg_type = @intFromEnum(msg_type),
            },
            .data = data,
        };
    }
};

test "header encode" {
    var buf: [5]u8 = undefined;
    const hdr = Header{ .length = 0x01020304, .msg_type = 0xAA };
    hdr.encode(&buf);
    try testing.expectEqual(@as(u8, 0x04), buf[0]);
    try testing.expectEqual(@as(u8, 0xAA), buf[4]);
}

test "packet round trip" {
    const original = Packet.make(.command, "hello");
    var buf: [128]u8 = undefined;
    const serialized = original.serialize(&buf);
    const parsed = try Packet.deserialize(serialized);
    try testing.expectEqual(@as(u8, @intFromEnum(MessageType.command)), parsed.header.msg_type);
    try testing.expectEqual(@as(u32, 10), parsed.header.length);
    try testing.expectEqualStrings("hello", parsed.data);
}

test "packet with no data" {
    const p = Packet.make(.ready, "");
    try testing.expectEqual(@as(u32, 5), p.header.length);
}

test "packet deinit frees owned data and is idempotent" {
    var pkt = Packet{
        .header = .{ .length = 6, .msg_type = @intFromEnum(MessageType.ready) },
        .data = try testing.allocator.dupe(u8, "hello"),
        .is_owned = true,
    };
    pkt.deinit(testing.allocator);
    pkt.deinit(testing.allocator);
}

test "message type fromByte rejects invalid values" {
    try testing.expect(MessageType.fromByte(0x00) == null);
    try testing.expect(MessageType.fromByte(0x02) == null); // identify_cwd removed
    try testing.expect(MessageType.fromByte(0x03) == null); // identify_done removed
    try testing.expect(MessageType.fromByte(0x07) == null); // shell removed
    try testing.expect(MessageType.fromByte(0x09) == null);
    try testing.expect(MessageType.fromByte(0x7F) == null);
    try testing.expect(MessageType.fromByte(0x84) == null); // notify removed
    try testing.expect(MessageType.fromByte(0xFF) == null);
    try testing.expectEqual(MessageType.command, MessageType.fromByte(0x04).?);
    try testing.expectEqual(MessageType.ready, MessageType.fromByte(0x80).?);
    try testing.expectEqual(MessageType.detach, MessageType.fromByte(0x06).?);
    try testing.expectEqual(MessageType.output, MessageType.fromByte(0x81).?);
}

test "message type request detection" {
    try testing.expect(MessageType.command.isRequest());
    try testing.expect(!MessageType.ready.isRequest());
}

test "packet layout byte-exact structure" {
    const pkt = Packet.make(.command, "A");
    var buf: [16]u8 = undefined;
    const serialized = pkt.serialize(&buf);

    try testing.expectEqual(@as(usize, 6), serialized.len);
    try testing.expectEqual(@as(u8, 0x06), serialized[0]);
    try testing.expectEqual(@as(u8, 0x00), serialized[1]);
    try testing.expectEqual(@as(u8, 0x00), serialized[2]);
    try testing.expectEqual(@as(u8, 0x00), serialized[3]);
    try testing.expectEqual(@as(u8, 0x04), serialized[4]);
    try testing.expectEqual(@as(u8, 0x41), serialized[5]);
}
