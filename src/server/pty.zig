const std = @import("std");
const testing = std.testing;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
extern "c" fn fork() c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]?[*:0]const u8) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn waitpid(pid: c_int, stat_loc: ?*c_int, options: c_int) c_int;
extern "c" fn login_tty(fd: c_int) c_int;

pub const F_SETFD: c_int = 2;
pub const FD_CLOEXEC: c_int = 1;

pub fn setCloexec(fd: i32) void {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC);
}

const TIOCSWINSZ: c_ulong = 0x80087467;
const DEFAULT_SHELL: []const u8 = "/bin/zsh";

pub const Pty = struct {
    master: i32,
    slave: i32,
    pid: i32,

    pub fn open() !Pty {
        var master: c_int = 0;
        var slave: c_int = 0;
        if (openpty(&master, &slave, null, null, null) < 0) return error.PtyOpenFailed;
        setCloexec(master);
        setCloexec(slave);
        return Pty{ .master = master, .slave = slave, .pid = -1 };
    }

    pub fn spawn(self: *Pty, allocator: std.mem.Allocator, argv: ?[]const []const u8) !void {
        const args = argv orelse &.{DEFAULT_SHELL};

        var argv_z = try allocator.alloc(?[*:0]const u8, args.len + 1);
        for (args, 0..) |arg, i| {
            argv_z[i] = try allocator.dupeZ(u8, arg);
        }
        argv_z[args.len] = null;

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = close(self.master);
            _ = login_tty(self.slave);
            _ = execvp(argv_z[0].?, @ptrCast(argv_z.ptr));
            std.process.exit(1);
        }
        self.pid = pid;
        _ = close(self.slave);
        self.slave = -1;
        for (argv_z) |z| {
            if (z) |s| allocator.free(std.mem.span(s));
        }
        allocator.free(argv_z);
    }

    pub fn reap(self: *Pty) void {
        if (self.pid > 0) {
            var status: c_int = 0;
            _ = waitpid(self.pid, &status, 0);
            self.pid = -1;
        }
    }

    pub fn deinit(self: *Pty) void {
        if (self.pid > 0) {
            _ = std.c.kill(self.pid, std.c.SIG.KILL);
        }
        _ = close(self.master);
        if (self.slave >= 0) _ = close(self.slave);
        self.reap();
    }

    pub fn readOutput(self: *Pty, buf: []u8) !usize {
        const n = read(self.master, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.ProcessExited;
        return @as(usize, @intCast(n));
    }

    pub fn writeInput(self: *Pty, data: []const u8) !void {
        const n = write(self.master, data.ptr, data.len);
        if (n < 0) return error.WriteFailed;
    }

    pub fn setWinSize(self: *Pty, ws: *const std.c.winsize) !void {
        if (ioctl(self.master, TIOCSWINSZ, ws) < 0) return error.IoctlFailed;
    }
};

test "openpty creates master and slave" {
    var pty = try Pty.open();
    defer pty.deinit();
    try testing.expect(pty.master >= 0);
    try testing.expect(pty.slave >= 0);
}

test "pty master has FD_CLOEXEC set" {
    var pty = try Pty.open();
    defer pty.deinit();

    // F_GETFD = 1
    const flags = fcntl(pty.master, @as(c_int, 1), @as(c_int, 0));
    try testing.expect(flags >= 0);
    try testing.expect((flags & FD_CLOEXEC) != 0);
}

test "pty slave has FD_CLOEXEC set" {
    var pty = try Pty.open();
    defer pty.deinit();

    const flags = fcntl(pty.slave, @as(c_int, 1), @as(c_int, 0));
    try testing.expect(flags >= 0);
    try testing.expect((flags & FD_CLOEXEC) != 0);
}
