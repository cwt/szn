const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const Packet = protocol.Packet;
const MessageType = protocol.MessageType;

pub const ReadError = error{
    InvalidPacket,
    PacketTooLarge,
    ConnectionClosed,
    ReadFailed,
    BufferFull,
};

pub const MessageReader = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    pub fn reset(self: *MessageReader) void {
        self.pos = 0;
    }

    pub fn feed(self: *MessageReader, data: []const u8) ReadError!void {
        if (data.len > self.buf.len - self.pos) return error.BufferFull;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn tryParse(self: *MessageReader) ReadError!?Packet {
        if (self.pos < 5) return null;

        const len = std.mem.readInt(u32, self.buf[0..4], .little);
        if (len < 5) return error.InvalidPacket;
        if (len > self.buf.len) return error.PacketTooLarge;

        if (self.pos < len) return null;

        const pkt = Packet{
            .header = .{
                .length = len,
                .msg_type = self.buf[4],
            },
            .data = self.buf[5..len],
        };

        return pkt;
    }

    pub fn consume(self: *MessageReader, pkt: Packet) void {
        const consumed = pkt.header.length;
        if (consumed >= self.pos) {
            self.pos = 0;
        } else {
            const remaining = self.pos - consumed;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[consumed..self.pos]);
            self.pos = remaining;
        }
    }
};

pub fn serializePacket(pkt: Packet, out: []u8) []u8 {
    return pkt.serialize(out);
}

pub fn makeCommandPacket(cmd: []const u8) Packet {
    return Packet.make(.command, cmd);
}

pub fn makeReadyPacket() Packet {
    return Packet.make(.ready, "");
}

pub fn makeOutputPacket(data: []const u8) Packet {
    return Packet.make(.output, data);
}

pub fn makeErrorPacket(msg: []const u8) Packet {
    return Packet.make(.err, msg);
}

const exit_codes = init: {
    var arr: [256]u8 = undefined;
    for (&arr, 0..) |*item, i| {
        item.* = @intCast(i);
    }
    break :init arr;
};

pub fn makeExitPacket(code: u8) Packet {
    return Packet.make(.exit, exit_codes[code..][0..1]);
}

pub fn packetType(pkt: Packet) MessageType {
    return @enumFromInt(pkt.header.msg_type);
}

test "message reader empty buffer" {
    var reader = MessageReader{};
    const pkt = try reader.tryParse();
    try testing.expect(pkt == null);
}

test "message reader partial header" {
    var reader = MessageReader{};
    try reader.feed(&[_]u8{ 0x06, 0x00, 0x00 });
    const pkt = try reader.tryParse();
    try testing.expect(pkt == null);
}

test "message reader complete packet" {
    var reader = MessageReader{};
    const original = Packet.make(.command, "hello");
    var buf: [128]u8 = undefined;
    const serialized = original.serialize(&buf);
    try reader.feed(serialized);

    const pkt = (try reader.tryParse()).?;
    try testing.expectEqual(@as(u8, @intFromEnum(MessageType.command)), pkt.header.msg_type);
    try testing.expectEqualStrings("hello", pkt.data);

    reader.consume(pkt);
    try testing.expectEqual(@as(usize, 0), reader.pos);
}

test "message reader partial body" {
    var reader = MessageReader{};
    const original = Packet.make(.command, "hello");
    var buf: [128]u8 = undefined;
    const serialized = original.serialize(&buf);

    try reader.feed(serialized[0..5]);
    const pkt1 = try reader.tryParse();
    try testing.expect(pkt1 == null);

    try reader.feed(serialized[5..]);
    const pkt2 = (try reader.tryParse()).?;
    try testing.expectEqualStrings("hello", pkt2.data);
}

test "message reader two packets" {
    var reader = MessageReader{};

    const pkt1 = Packet.make(.command, "cmd1");
    const pkt2 = Packet.make(.ready, "ok");
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const s1 = pkt1.serialize(&buf1);
    const s2 = pkt2.serialize(&buf2);

    try reader.feed(s1);
    try reader.feed(s2);

    const parsed1 = (try reader.tryParse()).?;
    try testing.expectEqualStrings("cmd1", parsed1.data);
    reader.consume(parsed1);

    const parsed2 = (try reader.tryParse()).?;
    try testing.expectEqualStrings("ok", parsed2.data);
    reader.consume(parsed2);
}

test "message reader invalid packet" {
    var reader = MessageReader{};
    try reader.feed(&[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x01 });
    try testing.expectError(error.InvalidPacket, reader.tryParse());
}

test "message reader reset" {
    var reader = MessageReader{};
    try reader.feed("some data");
    reader.reset();
    try testing.expectEqual(@as(usize, 0), reader.pos);
}

test "make command packet" {
    const pkt = makeCommandPacket("new-session test");
    try testing.expectEqual(@as(u8, @intFromEnum(MessageType.command)), pkt.header.msg_type);
    try testing.expectEqualStrings("new-session test", pkt.data);
}

test "make ready packet" {
    const pkt = makeReadyPacket();
    try testing.expectEqual(@as(u8, @intFromEnum(MessageType.ready)), pkt.header.msg_type);
    try testing.expectEqual(@as(u32, 5), pkt.header.length);
}

test "make output packet" {
    const pkt = makeOutputPacket("session created");
    try testing.expectEqualStrings("session created", pkt.data);
}

test "make error packet" {
    const pkt = makeErrorPacket("unknown command");
    try testing.expectEqualStrings("unknown command", pkt.data);
}

test "make exit packet" {
    const pkt = makeExitPacket(0);
    try testing.expectEqual(@as(usize, 1), pkt.data.len);
    try testing.expectEqual(@as(u8, 0), pkt.data[0]);
}

test "packet type helper" {
    const pkt = Packet.make(.command, "test");
    try testing.expectEqual(MessageType.command, packetType(pkt));
}

test "serialize and parse round trip" {
    var reader = MessageReader{};

    const original = makeCommandPacket("split-window -v");
    var buf: [128]u8 = undefined;
    const serialized = serializePacket(original, &buf);
    try reader.feed(serialized);

    const parsed = (try reader.tryParse()).?;
    try testing.expectEqual(MessageType.command, packetType(parsed));
    try testing.expectEqualStrings("split-window -v", parsed.data);
}

test "message reader large packet" {
    var reader = MessageReader{};

    var data: [256]u8 = undefined;
    @memset(&data, 'A');
    const pkt = Packet.make(.output, &data);
    var buf: [512]u8 = undefined;
    const serialized = pkt.serialize(&buf);
    try reader.feed(serialized);

    const parsed = (try reader.tryParse()).?;
    try testing.expectEqual(@as(usize, 256), parsed.data.len);
}

test "message reader consume partial remaining" {
    var reader = MessageReader{};

    const pkt1 = Packet.make(.command, "a");
    const pkt2 = Packet.make(.ready, "b");
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const s1 = pkt1.serialize(&buf1);
    const s2 = pkt2.serialize(&buf2);

    var combined: [128]u8 = undefined;
    @memcpy(combined[0..s1.len], s1);
    @memcpy(combined[s1.len..][0..s2.len], s2);
    try reader.feed(combined[0 .. s1.len + s2.len]);

    const p1 = (try reader.tryParse()).?;
    try testing.expectEqualStrings("a", p1.data);
    reader.consume(p1);

    try testing.expect(reader.pos > 0);

    const p2 = (try reader.tryParse()).?;
    try testing.expectEqualStrings("b", p2.data);
    reader.consume(p2);

    try testing.expectEqual(@as(usize, 0), reader.pos);
}
