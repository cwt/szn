const std = @import("std");
const testing = std.testing;

pub const BufferEntry = struct {
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: *BufferEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

pub const BufferList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(BufferEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) BufferList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BufferList) void {
        for (self.items.items) |*b| b.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn pushOwned(self: *BufferList, name: []const u8, data: []const u8) !void {
        try self.items.insert(self.allocator, 0, .{ .name = name, .data = data });
    }

    pub fn push(self: *BufferList, name: []const u8, data: []const u8) !void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        const d = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(d);
        try self.items.insert(self.allocator, 0, .{ .name = n, .data = d });
    }

    pub fn get(self: *const BufferList, name: ?[]const u8) ?[]const u8 {
        if (name) |n| {
            for (self.items.items) |b| {
                if (std.mem.eql(u8, b.name, n)) return b.data;
            }
            return null;
        }
        if (self.items.items.len == 0) return null;
        return self.items.items[0].data;
    }

    pub fn delete(self: *BufferList, name: []const u8) bool {
        for (self.items.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, name)) {
                var entry = self.items.swapRemove(i);
                entry.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn generateName(self: *const BufferList) ![]const u8 {
        var name_buf: [64]u8 = undefined;
        var idx: u32 = 0;
        while (idx < 10000) : (idx += 1) {
            const n = std.fmt.bufPrint(&name_buf, "buffer{}", .{idx}) catch
                std.fmt.bufPrint(&name_buf, "buf{}", .{idx}) catch
                    "buffer";
            var found = false;
            for (self.items.items) |b| {
                if (std.mem.eql(u8, b.name, n)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return try self.allocator.dupe(u8, n);
            }
        }
        return try self.allocator.dupe(u8, name_buf[0..0]);
    }

    pub fn appendToList(self: *const BufferList, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        var line_buf: [256]u8 = undefined;
        for (self.items.items) |b| {
            const line = try std.fmt.bufPrint(&line_buf, "{s}: {d} bytes\n", .{ b.name, b.data.len });
            try buf.appendSlice(allocator, line);
        }
    }
};

test "push and get latest" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();

    try bl.push("b0", "hello");
    try bl.push("b1", "world");

    try testing.expectEqualStrings("world", bl.get(null).?);
    try testing.expectEqualStrings("hello", bl.get("b0").?);
}

test "get returns null for missing name" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();

    try testing.expect(bl.get("nope") == null);
    try testing.expect(bl.get(null) == null);
}

test "delete removes entry" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();

    try bl.push("b0", "data");
    try testing.expect(bl.delete("b0"));
    try testing.expect(bl.get("b0") == null);
}

test "delete returns false for missing" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();
    try testing.expect(!bl.delete("nope"));
}

test "generateName produces unique names" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();

    const n1 = try bl.generateName();
    try bl.pushOwned(n1, try testing.allocator.dupe(u8, "a"));
    const n2 = try bl.generateName();
    try testing.expect(!std.mem.eql(u8, n1, n2));
    bl.allocator.free(n2);
}

test "appendToList writes formatted output" {
    var bl = BufferList.init(testing.allocator);
    defer bl.deinit();

    try bl.push("b0", "hello");
    try bl.push("b1", "world");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try bl.appendToList(testing.allocator, &buf);

    const output = buf.items;
    try testing.expect(std.mem.indexOf(u8, output, "b1: 5 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, output, "b0: 5 bytes") != null);
}
