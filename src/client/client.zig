const std = @import("std");
const c = std.c;
const protocol = @import("../server/protocol.zig");
const connect = @import("connect.zig");

fn fdWrite(fd: i32, buf: []const u8) !usize {
    const n = std.c.write(fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @as(usize, @intCast(n));
}

fn fdRead(fd: i32, buf: []u8) !usize {
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @as(usize, @intCast(n));
}

pub const Client = struct {
    fd: i32,

    pub fn init() !Client {
        const fd = try connect.connectToServer();
        return Client{ .fd = fd };
    }

    pub fn deinit(self: *Client) void {
        _ = c.close(self.fd);
    }

    pub fn sendIdentify(self: *Client, term: []const u8) !void {
        var it: protocol.IdentifyTerm = .{ .term_len = @intCast(term.len) };
        @memcpy(it.term[0..term.len], term);
        var buf: [128]u8 = undefined;
        const data = it.encode(&buf);
        try self.sendPacket(.identify_term, data);
    }

    pub fn sendCommand(self: *Client, cmd: []const u8) !void {
        try self.sendPacket(.command, cmd);
    }

    fn sendPacket(self: *Client, msg_type: protocol.MessageType, data: []const u8) !void {
        const pkt = protocol.Packet.make(msg_type, data);
        var buf: [4096]u8 = undefined;
        const serialized = pkt.serialize(&buf);
        const n = try fdWrite(self.fd, serialized);
        if (n != serialized.len) return error.WriteFailed;
    }

    pub fn recvPacket(self: *Client) !protocol.Packet {
        var hdr: [5]u8 = undefined;
        var off: usize = 0;
        while (off < 5) {
            off += try fdRead(self.fd, hdr[off..]);
        }

        const len = std.mem.readInt(u32, hdr[0..4], .little);
        if (len < 5) return error.InvalidPacket;
        const body_len = len - 5;
        if (body_len > 4096) return error.PacketTooLarge;

        var body: [4096]u8 = undefined;
        off = 0;
        while (off < body_len) {
            off += try fdRead(self.fd, body[off..body_len]);
        }

        return protocol.Packet{
            .header = .{
                .length = len,
                .msg_type = hdr[4],
            },
            .data = body[0..body_len],
        };
    }
};
