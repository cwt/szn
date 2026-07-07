const std = @import("std");
const testing = std.testing;

pub const Error = error{
    OutOfMemory,
    NetworkDown,
    SystemResources,
    Unexpected,
};

pub const FdEntry = struct {
    fd: i32,
    events: i16,
    udata: ?*anyopaque,
};

pub const PollEvent = struct {
    fd: i32,
    revents: i16,
    udata: ?*anyopaque,
};

pub const Loop = struct {
    fds: std.ArrayList(FdEntry) = .empty,
    running: bool = true,
    event_buf: std.ArrayList(PollEvent) = .empty,
    pollfds: std.ArrayList(std.posix.pollfd) = .empty,

    pub fn init() Loop {
        return Loop{};
    }

    pub fn deinit(self: *Loop, allocator: std.mem.Allocator) void {
        self.fds.deinit(allocator);
        self.event_buf.deinit(allocator);
        self.pollfds.deinit(allocator);
    }

    pub fn addFd(self: *Loop, allocator: std.mem.Allocator, fd: i32, events: i16, udata: ?*anyopaque) Error!void {
        for (self.fds.items) |*f| {
            if (f.fd == fd) {
                f.* = FdEntry{ .fd = fd, .events = events, .udata = udata };
                return;
            }
        }
        try self.fds.append(allocator, FdEntry{
            .fd = fd,
            .events = events,
            .udata = udata,
        });
    }

    pub fn removeFd(self: *Loop, fd: i32) void {
        for (self.fds.items, 0..) |f, i| {
            if (f.fd == fd) {
                _ = self.fds.swapRemove(i);
                return;
            }
        }
    }

    pub fn pollOnce(self: *Loop, allocator: std.mem.Allocator, timeout: i32) Error![]PollEvent {
        if (self.fds.items.len == 0) return &[0]PollEvent{};

        const pollfd_count = self.fds.items.len;
        try self.pollfds.resize(allocator, pollfd_count);

        for (self.fds.items, 0..) |f, i| {
            self.pollfds.items[i] = std.posix.pollfd{
                .fd = f.fd,
                .events = f.events,
                .revents = 0,
            };
        }

        const ready = try std.posix.poll(self.pollfds.items[0..pollfd_count], timeout);
        if (ready == 0) return &[0]PollEvent{};

        self.event_buf.clearRetainingCapacity();
        try self.event_buf.ensureTotalCapacity(allocator, pollfd_count);

        for (self.pollfds.items[0..pollfd_count], 0..) |pfd, i| {
            if (pfd.revents != 0) {
                self.event_buf.appendAssumeCapacity(.{
                    .fd = pfd.fd,
                    .revents = pfd.revents,
                    .udata = self.fds.items[i].udata,
                });
            }
        }

        return self.event_buf.items;
    }

    pub fn stop(self: *Loop) void {
        self.running = false;
    }
};

test "loop init" {
    var loop = Loop.init();
    defer loop.deinit(testing.allocator);
    try testing.expect(loop.running);
}

test "loop handles more than 64 fds without stack overflow" {
    var pipes = std.ArrayList([2]i32){ .items = &.{}, .capacity = 0 };
    defer pipes.deinit(testing.allocator);

    var loop = Loop.init();
    defer {
        for (pipes.items) |p| {
            _ = std.c.close(p[0]);
            _ = std.c.close(p[1]);
        }
        loop.deinit(testing.allocator);
    }

    try pipes.ensureTotalCapacity(testing.allocator, 100);
    for (0..100) |i| {
        var p: [2]i32 = undefined;
        if (std.c.pipe(&p) < 0) return error.Unexpected;
        pipes.appendAssumeCapacity(p);
        try loop.addFd(testing.allocator, p[0], @as(i16, @intCast(std.posix.POLL.IN)), @ptrFromInt(i));
    }

    const events = try loop.pollOnce(testing.allocator, 0);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "addFd updates existing fd events and udata — bug #132" {
    var loop = Loop.init();
    defer loop.deinit(testing.allocator);

    try loop.addFd(testing.allocator, 42, @as(i16, @intCast(std.posix.POLL.IN)), @as(?*anyopaque, @ptrFromInt(@as(usize, 1))));
    try testing.expectEqual(@as(usize, 1), loop.fds.items.len);
    try testing.expectEqual(@as(i32, 42), loop.fds.items[0].fd);

    // Re-add same fd with different events and udata
    try loop.addFd(testing.allocator, 42, @as(i16, @intCast(std.posix.POLL.OUT)), @as(?*anyopaque, @ptrFromInt(@as(usize, 2))));
    try testing.expectEqual(@as(usize, 1), loop.fds.items.len); // no duplicate
    try testing.expectEqual(@as(i16, @intCast(std.posix.POLL.OUT)), loop.fds.items[0].events);
    try testing.expectEqual(@as(?*anyopaque, @ptrFromInt(@as(usize, 2))), loop.fds.items[0].udata);
}
