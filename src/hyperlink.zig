const std = @import("std");
const testing = std.testing;

/// Upper bound on distinct hyperlinks kept per screen. Reaching the cap does
/// not invalidate earlier links: new OSC 8 sequences simply stop linking
/// cells (`put` returns `none`) and the store keeps every URI it already
/// handed out. This avoids the stale-ID problem a reset would create for
/// cells still on screen or in scrollback.
pub const MAX_LINKS = 4096;
/// URIs longer than this are ignored rather than allocated.
pub const MAX_URI_LEN = 4096;

pub const Id = u32;
pub const none: Id = 0;

pub const CloseSequence = "\x1b]8;;\x1b\\";

pub const Error = std.mem.Allocator.Error;

const Entry = struct {
    uri: []const u8,
    /// The OSC 8 parameter string to re-emit, e.g. `id=foo`.
    param: []const u8,
};

/// Per-screen registry of OSC 8 hyperlinks. Cell IDs are indices into this
/// store (1-based; 0 means "no link"), so cells can be copied between grids
/// as long as the destination store receives the same URI via `put`.
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    by_param: std.StringHashMapUnmanaged(Id) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.uri);
            self.allocator.free(entry.param);
        }
        var it = self.by_param.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit(self.allocator);
        self.by_param.deinit(self.allocator);
    }

    /// Extract the external ID name from an OSC 8 parameter list. Only the
    /// first `id=` parameter is honoured; trailing parameters (separated by
    /// `:`) are ignored, matching the common `id=foo` form.
    fn idName(params: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, params, "id=")) return null;
        const name = params[3..];
        if (name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, ':')) |i| return name[0..i];
        return name;
    }

    /// Register `uri` and return the ID cells should carry. An empty URI
    /// closes the link for subsequent cells. A named ID (`id=foo`) is reused
    /// and its URI updated; anonymous links always get a fresh ID.
    pub fn put(self: *Store, uri: []const u8, params: []const u8) Error!Id {
        if (uri.len == 0 or uri.len > MAX_URI_LEN) return none;
        if (self.entries.items.len >= MAX_LINKS) return none;

        const name = idName(params);
        if (name) |n| {
            if (self.by_param.get(n)) |existing| {
                const replacement = try self.allocator.dupe(u8, uri);
                self.allocator.free(self.entries.items[existing - 1].uri);
                self.entries.items[existing - 1].uri = replacement;
                return existing;
            }
        }

        const id: Id = @intCast(self.entries.items.len + 1);
        const param = if (name != null)
            try self.allocator.dupe(u8, params)
        else
            try std.fmt.allocPrint(self.allocator, "id={d}", .{id});
        const owned_uri = try self.allocator.dupe(u8, uri);
        try self.entries.append(self.allocator, .{ .uri = owned_uri, .param = param });
        if (name) |n| {
            try self.by_param.put(self.allocator, try self.allocator.dupe(u8, n), id);
        }
        return id;
    }

    pub fn getUri(self: *const Store, id: Id) ?[]const u8 {
        if (id == none or id > self.entries.items.len) return null;
        return self.entries.items[id - 1].uri;
    }

    pub fn getParam(self: *const Store, id: Id) ?[]const u8 {
        if (id == none or id > self.entries.items.len) return null;
        return self.entries.items[id - 1].param;
    }

    /// Write a complete OSC 8 open sequence into `buf`. Returns null when the
    /// ID is invalid or the buffer is too small.
    pub fn formatOsc(self: *const Store, id: Id, buf: []u8) ?[]const u8 {
        const uri = self.getUri(id) orelse return null;
        const param = self.getParam(id) orelse return null;
        return std.fmt.bufPrint(buf, "\x1b]8;{s};{s}\x1b\\", .{ param, uri }) catch null;
    }
};

test "empty URI closes a hyperlink without allocating" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(none, try store.put("", "id=foo"));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "anonymous OSC 8 links get distinct ids and round-trip" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const a = try store.put("https://example.com/a", "");
    const b = try store.put("https://example.com/b", "");
    try testing.expect(a != none);
    try testing.expect(b != none);
    try testing.expect(a != b);
    try testing.expectEqualStrings("https://example.com/a", store.getUri(a).?);
    try testing.expectEqualStrings("id=1", store.getParam(a).?);
    try testing.expectEqualStrings("id=2", store.getParam(b).?);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("\x1b]8;id=1;https://example.com/a\x1b\\", store.formatOsc(a, &buf).?);
}

test "named OSC 8 id is reused and its URI updated" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const first = try store.put("https://example.com/old", "id=docs");
    const second = try store.put("https://example.com/new", "id=docs");
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqualStrings("https://example.com/new", store.getUri(first).?);
    try testing.expectEqualStrings("id=docs", store.getParam(first).?);

    const anon = try store.put("https://example.com/other", "foo=bar");
    try testing.expect(anon != first);
}

test "invalid ids return no URI and emit no sequence" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(store.getUri(none) == null);
    try testing.expect(store.getUri(99) == null);
    var buf: [64]u8 = undefined;
    try testing.expect(store.formatOsc(none, &buf) == null);
}

test "oversized URIs are ignored" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var huge_buf: [MAX_URI_LEN + 1]u8 = undefined;
    @memset(&huge_buf, 'x');
    const huge: []const u8 = &huge_buf;
    try testing.expectEqual(none, try store.put(huge, ""));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
}
