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
    fds: std.ArrayListUnmanaged(FdEntry) = .empty,
    running: bool = true,
    event_buf: std.ArrayListUnmanaged(PollEvent) = .empty,

    pub fn init() Loop {
        return Loop{};
    }

    pub fn deinit(self: *Loop, allocator: std.mem.Allocator) void {
        self.fds.deinit(allocator);
        self.event_buf.deinit(allocator);
    }

    pub fn addFd(self: *Loop, allocator: std.mem.Allocator, fd: i32, events: i16, udata: ?*anyopaque) Error!void {
        for (self.fds.items) |f| {
            if (f.fd == fd) return;
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
        const pollfds = try allocator.alloc(std.posix.pollfd, pollfd_count);
        defer allocator.free(pollfds);

        for (self.fds.items, 0..) |f, i| {
            pollfds[i] = std.posix.pollfd{
                .fd = f.fd,
                .events = f.events,
                .revents = 0,
            };
        }

        const ready = try std.posix.poll(pollfds[0..pollfd_count], timeout);
        if (ready == 0) return &[0]PollEvent{};

        self.event_buf.clearRetainingCapacity();
        try self.event_buf.ensureTotalCapacity(allocator, pollfd_count);

        for (pollfds[0..pollfd_count], 0..) |pfd, i| {
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
    var pipes = std.ArrayListUnmanaged([2]i32){ .items = &.{}, .capacity = 0 };
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
