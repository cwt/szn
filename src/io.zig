const std = @import("std");

/// Result of a single `writeOnce` attempt.
pub const WriteOutcome = union(enum) {
    wrote: usize,
    would_block,
    closed,
    failed,
};

/// Perform one write(2) of `buf` to `fd`, retrying EINTR internally. The result
/// is classified so each caller can apply its own buffering policy — synchronous
/// inline-retry versus non-blocking stash-and-arm-POLLOUT — without re-deriving
/// the errno interpretation.
///
/// This is the fragment the five hand-rolled write loops in dispatch.zig,
/// server.zig and pty.zig used to copy independently. Copy-paste is exactly how
/// `sendRequestCellSize` drifted into bugs #262, #403 and #472 (bug #520): each
/// site re-implemented INTR/AGAIN/closed/fatal handling with subtly different
/// bugs. Centralising it here means there is one place to get it right.
pub fn writeOnce(fd: i32, buf: []const u8) WriteOutcome {
    if (buf.len == 0) return .{ .wrote = 0 };
    var res: isize = undefined;
    while (true) {
        res = std.c.write(fd, buf.ptr, buf.len);
        if (res >= 0) break;
        const err = std.c.errno(res);
        if (err == .INTR) continue;
        if (err == .AGAIN) return .would_block;
        return .failed;
    }
    if (res == 0) return .closed;
    return .{ .wrote = @as(usize, @intCast(res)) };
}

pub fn writeAll(fd: i32, buf: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < buf.len) {
        switch (writeOnce(fd, buf[off..])) {
            .wrote => |n| off += n,
            .would_block => {
                var req: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
                _ = std.c.nanosleep(&req, null);
            },
            .closed, .failed => return error.WriteFailed,
        }
    }
}

extern "c" fn gettimeofday(tv: *std.c.timeval, tz: ?*anyopaque) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const O_NONBLOCK: c_int = switch (@import("builtin").os.tag) {
    .linux => @as(c_int, 0o4000),
    else => @as(c_int, 0x0004),
};

pub fn currentMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divFloor(@as(i64, @intCast(tv.usec)), 1000);
}

pub fn setNonBlocking(fd: i32) void {
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

pub fn setBlocking(fd: i32) void {
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) {
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    }
}

/// Amortized O(1)-per-byte FIFO queue backed by `std.ArrayList(u8)` with a
/// moving `head` cursor. Replaces repeated `std.mem.copyForwards` shifts on
/// partial non-blocking writes and incremental socket reads (eliminating
/// Theta(N^2 / C) memmove storms on large sixel frames and slow PTY links).
pub const ByteQueue = struct {
    /// When a queue that grew past this threshold drains completely empty,
    /// `clearAndReclaim` / `consumeReclaiming` releases the oversized backing
    /// allocation so transient multi-MiB sixel frames don't pin RSS forever.
    pub const RECLAIM_THRESHOLD: usize = 256 * 1024;

    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,

    pub fn deinit(self: *ByteQueue, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.buf = .empty;
        self.head = 0;
    }

    pub fn len(self: *const ByteQueue) usize {
        return self.buf.items.len - self.head;
    }

    pub fn isEmpty(self: *const ByteQueue) bool {
        return self.head >= self.buf.items.len;
    }

    pub fn capacity(self: *const ByteQueue) usize {
        return self.buf.capacity;
    }

    pub fn unreadSlice(self: *const ByteQueue) []const u8 {
        return self.buf.items[self.head..];
    }

    pub fn clearRetainingCapacity(self: *ByteQueue) void {
        self.head = 0;
        self.buf.clearRetainingCapacity();
    }

    /// Empty the queue and release its backing buffer if it grew past
    /// `RECLAIM_THRESHOLD`, otherwise retain capacity for fast reuse.
    pub fn clearAndReclaim(self: *ByteQueue, allocator: std.mem.Allocator) void {
        self.head = 0;
        if (self.buf.capacity > RECLAIM_THRESHOLD) {
            self.buf.deinit(allocator);
            self.buf = .empty;
        } else {
            self.buf.clearRetainingCapacity();
        }
    }

    /// Advance the read cursor by `n` bytes in O(1) without shifting memory.
    /// Resets `head` and `items.len` to 0 when the queue becomes empty.
    pub fn consume(self: *ByteQueue, n: usize) void {
        const unread = self.len();
        if (n >= unread) {
            self.clearRetainingCapacity();
        } else {
            self.head += n;
        }
    }

    /// Like `consume`, and also reclaims oversized (>256 KiB) backing buffers
    /// once the queue drains completely empty.
    pub fn consumeReclaiming(self: *ByteQueue, allocator: std.mem.Allocator, n: usize) void {
        const unread = self.len();
        if (n >= unread) {
            self.clearAndReclaim(allocator);
        } else {
            self.head += n;
        }
    }

    /// Snapshot current unread length for rollback across potential compaction.
    /// Precondition: callers must not invoke `consume` / `consumeReclaiming`
    /// between `checkpoint()` and the matching `rollback()`.
    pub fn checkpoint(self: *const ByteQueue) usize {
        return self.len();
    }

    /// Roll back appended tail bytes to a previous `checkpoint()` unread length.
    /// Precondition: no `consume` occurred since `checkpoint()`.
    pub fn rollback(self: *ByteQueue, saved_unread_len: usize) void {
        if (saved_unread_len < self.len()) {
            self.buf.items.len = self.head + saved_unread_len;
        }
        if (self.head >= self.buf.items.len) {
            self.clearRetainingCapacity();
        }
    }

    /// Ensure at least `additional` writable bytes exist at the tail of `buf`.
    /// Compacts unread bytes to index 0 only when dead prefix >= unread bytes
    /// (at least 50% consumed) or when reallocation is unavoidable anyway,
    /// guaranteeing amortized O(1) bytes moved per enqueued byte.
    pub fn ensureUnusedCapacity(self: *ByteQueue, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        if (self.head >= self.buf.items.len) {
            self.clearRetainingCapacity();
        }
        if (self.buf.capacity - self.buf.items.len >= additional) return;

        const unread = self.buf.items.len - self.head;
        if (self.head > 0 and (self.head >= unread or additional > self.buf.capacity - unread)) {
            if (unread > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..unread], self.buf.items[self.head..]);
            }
            self.buf.items.len = unread;
            self.head = 0;
            if (self.buf.capacity - self.buf.items.len >= additional) return;
        }
        try self.buf.ensureUnusedCapacity(allocator, additional);
    }

    pub fn unusedCapacitySlice(self: *ByteQueue) []u8 {
        return self.buf.unusedCapacitySlice();
    }

    pub fn advanceTail(self: *ByteQueue, n: usize) void {
        self.buf.items.len += n;
    }

    pub fn appendSlice(self: *ByteQueue, allocator: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error!void {
        if (data.len == 0) return;
        try self.ensureUnusedCapacity(allocator, data.len);
        self.buf.appendSliceAssumeCapacity(data);
    }

    pub fn appendSliceAssumeCapacity(self: *ByteQueue, data: []const u8) void {
        if (data.len == 0) return;
        self.buf.appendSliceAssumeCapacity(data);
    }
};

const testing = std.testing;

test "ByteQueue pure drain advances head without shifting and reclaims oversized cap" {
    var q: ByteQueue = .{};
    defer q.deinit(testing.allocator);

    const payload = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    try q.appendSlice(testing.allocator, payload);
    try testing.expectEqual(payload.len, q.len());
    try testing.expect(q.capacity() > ByteQueue.RECLAIM_THRESHOLD);

    var off: usize = 0;
    while (off < payload.len) {
        const take = @min(@as(usize, 4096), q.len());
        try testing.expectEqualSlices(u8, payload[off .. off + take], q.unreadSlice()[0..take]);
        q.consumeReclaiming(testing.allocator, take);
        off += take;
        if (off < payload.len) {
            try testing.expectEqual(off, q.head);
        }
    }
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expectEqual(@as(usize, 0), q.head);
    try testing.expectEqual(@as(usize, 0), q.capacity());
}

test "ByteQueue interleaved append and drain preserves FIFO order with bounded memmove" {
    var q: ByteQueue = .{};
    defer q.deinit(testing.allocator);

    const total: usize = 128 * 1024;
    var sent: usize = 0;
    var recvd: usize = 0;
    var memmoved: usize = 0;

    var chunk: [1024]u8 = undefined;
    // Seed 32 KiB
    while (sent < 32 * 1024) : (sent += chunk.len) {
        for (&chunk, 0..) |*b, i| b.* = @truncate((sent + i) & 0xFF);
        try q.appendSlice(testing.allocator, &chunk);
    }

    while (recvd < total) {
        if (q.len() > 0) {
            const take = @min(@as(usize, 1024), q.len());
            const slice = q.unreadSlice();
            for (slice[0..take], 0..) |b, i| {
                try testing.expectEqual(@as(u8, @truncate((recvd + i) & 0xFF)), b);
            }
            q.consume(take);
            recvd += take;
        }
        if (sent < total) {
            for (&chunk, 0..) |*b, i| b.* = @truncate((sent + i) & 0xFF);
            const head_before = q.head;
            const unread_before = q.len();
            try q.appendSlice(testing.allocator, &chunk);
            if (head_before > 0 and q.head == 0) memmoved += unread_before;
            sent += chunk.len;
        }
    }
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expect(memmoved <= total);
}

test "ByteQueue checkpoint and rollback remain valid across compaction" {
    var q: ByteQueue = .{};
    defer q.deinit(testing.allocator);

    try q.appendSlice(testing.allocator, "0123456789ABCDEF");
    q.consume(12); // head=12, unread="CDEF" (len 4)
    const cp = q.checkpoint();
    try testing.expectEqual(@as(usize, 4), cp);

    // Append more than the remaining tail slack to guarantee compaction (head 12 >= unread 4).
    const need = q.unusedCapacitySlice().len + 1;
    const filler = try testing.allocator.alloc(u8, need);
    defer testing.allocator.free(filler);
    @memset(filler, 'x');
    try q.appendSlice(testing.allocator, filler);
    try testing.expectEqual(@as(usize, 0), q.head);
    q.rollback(cp);
    try testing.expectEqualStrings("CDEF", q.unreadSlice());
}
