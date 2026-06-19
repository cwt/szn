const std = @import("std");
const testing = std.testing;

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

    pub fn init() Loop {
        return Loop{};
    }

    pub fn deinit(self: *Loop, allocator: std.mem.Allocator) void {
        self.fds.deinit(allocator);
    }

    pub fn addFd(self: *Loop, allocator: std.mem.Allocator, fd: i32, events: i16, udata: ?*anyopaque) !void {
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

    pub fn pollOnce(self: *Loop, timeout: i32) ![]PollEvent {
        if (self.fds.items.len == 0) return &[0]PollEvent{};

        var pollfds: [64]std.posix.pollfd = undefined;
        for (self.fds.items, 0..) |f, i| {
            pollfds[i] = std.posix.pollfd{
                .fd = f.fd,
                .events = f.events,
                .revents = 0,
            };
        }

        const ready = try std.posix.poll(pollfds[0..self.fds.items.len], timeout);

        if (ready == 0) return &[0]PollEvent{};

        var out: [64]PollEvent = undefined;
        var out_count: usize = 0;
        for (pollfds[0..self.fds.items.len], 0..) |pfd, i| {
            if (pfd.revents != 0) {
                out[out_count] = PollEvent{
                    .fd = pfd.fd,
                    .revents = pfd.revents,
                    .udata = self.fds.items[i].udata,
                };
                out_count += 1;
            }
        }

        return out[0..out_count];
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
