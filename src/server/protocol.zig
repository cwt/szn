const std = @import("std");
const testing = std.testing;

pub const Error = error{
    InvalidPacket,
    SizeMismatch,
    InvalidData,
};

pub const MessageType = enum(u8) {
    identify_term = 0x01,
    identify_cwd = 0x02,
    identify_done = 0x03,
    command = 0x04,
    resize = 0x05,
    detach = 0x06,
    shell = 0x07,
    stdin_data = 0x08,

    ready = 0x80,
    output = 0x81,
    exit = 0x82,
    err = 0x83,
    notify = 0x84,

    pub fn isRequest(self: MessageType) bool {
        return @intFromEnum(self) < 0x80;
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
        return Packet{
            .header = .{
                .length = @as(u32, @intCast(5 + data.len)),
                .msg_type = @intFromEnum(msg_type),
            },
            .data = data,
        };
    }
};

pub const IdentifyTerm = struct {
    term: [64]u8 = undefined,
    term_len: u8 = 0,

    pub fn encode(self: IdentifyTerm, buf: []u8) []u8 {
        buf[0] = self.term_len;
        @memcpy(buf[1..][0..self.term_len], self.term[0..self.term_len]);
        return buf[0 .. 1 + self.term_len];
    }

    pub fn decode(data: []const u8) Error!IdentifyTerm {
        if (data.len < 1) return error.InvalidData;
        const len = data[0];
        if (len > 64) return error.InvalidData;
        if (data.len < 1 + len) return error.InvalidData;
        var result: IdentifyTerm = .{ .term_len = len };
        @memcpy(result.term[0..len], data[1 .. 1 + len]);
        return result;
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

test "identify term round trip" {
    var it: IdentifyTerm = .{ .term_len = 5 };
    @memcpy(it.term[0..5], "xterm");
    var buf: [128]u8 = undefined;
    const encoded = it.encode(&buf);
    const decoded = try IdentifyTerm.decode(encoded);
    try testing.expectEqual(@as(u8, 5), decoded.term_len);
    try testing.expectEqualStrings("xterm", decoded.term[0..decoded.term_len]);
}

test "identify term decode rejects len > 64" {
    // len=65, followed by 65 bytes of junk
    var buf: [66]u8 = undefined;
    buf[0] = 65;
    const decoded = IdentifyTerm.decode(buf[0..]);
    try testing.expectError(error.InvalidData, decoded);
}

test "message type request detection" {
    try testing.expect(MessageType.command.isRequest());
    try testing.expect(!MessageType.ready.isRequest());
}
