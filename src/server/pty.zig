const std = @import("std");
const testing = std.testing;

pub const Error = error{
    OutOfMemory,
    PtyOpenFailed,
    ForkFailed,
    ReadFailed,
    ProcessExited,
    WriteFailed,
    IoctlFailed,
};

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
extern "c" fn fork() c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]?[*:0]const u8) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn waitpid(pid: c_int, stat_loc: ?*c_int, options: c_int) c_int;
extern "c" fn login_tty(fd: c_int) c_int;

extern "c" fn tcgetpgrp(fd: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, size: c_int) void;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

const PROC_PIDVNODEPATHINFO: c_int = 9;
const MAXPATHLEN: usize = 1024;

const vinfo_stat = extern struct {
    dev: u32 = 0,
    mode: u16 = 0,
    nlink: u16 = 0,
    ino: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    atime: i64 = 0,
    atimensec: i64 = 0,
    mtime: i64 = 0,
    mtimensec: i64 = 0,
    ctime: i64 = 0,
    ctimensec: i64 = 0,
    birthtime: i64 = 0,
    birthtimensec: i64 = 0,
    size: i64 = 0,
    blocks: i64 = 0,
    blksize: i32 = 0,
    flags: u32 = 0,
    gen: u32 = 0,
    rdev: u32 = 0,
    qspare: [2]i64 = .{ 0, 0 },
};

const vnode_info = extern struct {
    stat: vinfo_stat = .{},
    vi_type: c_int = 0,
    vi_pad: c_int = 0,
    vi_fsid: [2]i32 = .{ 0, 0 },
};

const vnode_info_path = extern struct {
    info: vnode_info,
    path: [MAXPATHLEN]u8 = undefined,
};

const proc_vnodepathinfo = extern struct {
    cdir: vnode_info_path,
    rdir: vnode_info_path,
};

pub const F_SETFD: c_int = 2;
pub const FD_CLOEXEC: c_int = 1;

pub fn setCloexec(fd: i32) void {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC);
}

/// Best-effort raise of the soft RLIMIT_NOFILE to at least MIN_NOFILE_SOFT before
/// exec'ing a pane shell. The launchd session default on macOS is 256 (and gets
/// reset by OS upgrades), which is far too low for a terminal multiplexer. The
/// hard limit still caps us and any failure is non-fatal: we just keep whatever
/// the process already inherited.
/// Best-effort raise of the soft RLIMIT_NOFILE to at least `min_soft` before
/// exec'ing a pane shell. The launchd session default on macOS is 256 (and gets
/// reset by OS upgrades), which is far too low for a terminal multiplexer. The
/// hard limit still caps us and any failure is non-fatal: we just keep whatever
/// the process already inherited. `min_soft == 0` disables the raise.
fn raiseNoFileLimit(min_soft: u64) void {
    if (min_soft == 0) return;
    if (comptime @import("builtin").os.tag != .windows) {
        var rlim: std.c.rlimit = undefined;
        if (std.c.getrlimit(.NOFILE, &rlim) != 0) {
            std.log.warn("getrlimit(NOFILE) failed: {s}", .{@tagName(std.c.errno(-1))});
            return;
        }
        if (rlim.cur >= min_soft) return;

        const target: std.c.rlim_t = if (rlim.max < min_soft) rlim.max else @intCast(min_soft);
        rlim.cur = target;
        if (std.c.setrlimit(.NOFILE, &rlim) != 0) {
            std.log.warn("could not raise RLIMIT_NOFILE to {d}: {s}", .{ target, @tagName(std.c.errno(-1)) });
        }
    }
}

const TIOCSWINSZ: c_ulong = if (@import("builtin").os.tag == .macos) 0x80087467 else 0x5414;
const DEFAULT_SHELL: []const u8 = "/bin/zsh";
const WNOHANG: c_int = 1;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Pty = struct {
    master: i32,
    slave: i32,
    pid: i32,
    allocator: ?std.mem.Allocator = null,
    /// Keystrokes / input that could not be written to the (non-blocking) pty
    /// master because the child isn't reading its stdin (e.g. it is throttled
    /// by flow control). Drained when the master becomes writable again
    /// (POLLOUT) so keystrokes are never dropped under backpressure.
    input_buf: std.ArrayList(u8) = .empty,

    pub fn open() Error!Pty {
        var master: c_int = 0;
        var slave: c_int = 0;
        if (openpty(&master, &slave, null, null, null) < 0) return error.PtyOpenFailed;
        setCloexec(master);
        setCloexec(slave);

        const F_GETFL = 3;
        const F_SETFL = 4;
        const O_NONBLOCK = comptime switch (@import("builtin").os.tag) {
            .linux => @as(c_int, 0o4000),
            else => @as(c_int, 0x0004),
        };
        const flags = fcntl(master, F_GETFL, @as(c_int, 0));
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK);

        return Pty{ .master = master, .slave = slave, .pid = -1 };
    }

    pub fn spawn(self: *Pty, allocator: std.mem.Allocator, argv: ?[]const []const u8, szn_env: []const u8, szn_pane: []const u8, cwd: ?[]const u8, min_nofile_soft: u64) Error!void {
        self.allocator = allocator;
        const args = argv orelse &.{DEFAULT_SHELL};

        var argv_z = try allocator.alloc(?[*:0]const u8, args.len + 1);
        @memset(argv_z, null);
        errdefer {
            for (argv_z) |z| {
                if (z) |s| allocator.free(std.mem.span(s));
            }
            allocator.free(argv_z);
        }
        for (args, 0..) |arg, i| {
            argv_z[i] = try allocator.dupeZ(u8, arg);
        }
        argv_z[args.len] = null;

        const szn_env_z = try allocator.dupeZ(u8, szn_env);
        defer allocator.free(szn_env_z);

        const szn_pane_z = try allocator.dupeZ(u8, szn_pane);
        defer allocator.free(szn_pane_z);

        const cwd_z: ?[:0]const u8 = if (cwd) |c| try allocator.dupeZ(u8, c) else null;
        defer if (cwd_z) |c| allocator.free(c);

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            raiseNoFileLimit(min_nofile_soft);
            _ = close(self.master);
            _ = login_tty(self.slave);

            // Set sane terminal defaults so bare \n in cooked-mode output
            // is converted to \r\n before reaching the master.  openpty()
            // leaves c_oflag=0 which disables this conversion.
            {
                var term: std.c.termios = undefined;
                _ = std.c.tcgetattr(0, &term);
                term.oflag.OPOST = true;
                term.oflag.ONLCR = true;
                _ = std.c.tcsetattr(0, std.c.TCSA.FLUSH, &term);
            }

            if (cwd_z) |c| _ = chdir(c);

            _ = setenv("TERM", "tmux-256color", 1);
            _ = setenv("TERM_PROGRAM", "szn", 1);
            _ = setenv("SZN", szn_env_z, 1);
            _ = setenv("SZN_PANE", szn_pane_z, 1);

            const argv0 = argv_z[0] orelse std.process.exit(1);
            _ = execvp(argv0, @ptrCast(argv_z.ptr));
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

    pub fn getCwd(self: *const Pty, allocator: std.mem.Allocator) Error![]const u8 {
        const builtin = @import("builtin");
        const pgrp = tcgetpgrp(self.master);
        if (pgrp < 0) return error.ProcessExited;

        if (builtin.os.tag == .macos) {
            var buf: proc_vnodepathinfo = .{ .cdir = .{ .info = .{}, .path = undefined }, .rdir = .{ .info = .{}, .path = undefined } };
            const ret = proc_pidinfo(pgrp, PROC_PIDVNODEPATHINFO, 0, &buf, @sizeOf(proc_vnodepathinfo));
            if (ret < @sizeOf(proc_vnodepathinfo)) return error.ProcessExited;

            const path_bytes = &buf.cdir.path;
            const path_end = std.mem.indexOfScalar(u8, path_bytes, 0) orelse return error.ProcessExited;
            if (path_end == 0) return error.ProcessExited;

            return try allocator.dupe(u8, path_bytes[0..path_end]);
        } else if (builtin.os.tag == .linux) {
            var proc_path_buf: [64]u8 = undefined;
            const proc_path_z = std.fmt.bufPrintZ(&proc_path_buf, "/proc/{d}/cwd", .{pgrp}) catch return error.ProcessExited;

            var path_buf: [MAXPATHLEN]u8 = undefined;
            const n = readlink(proc_path_z, &path_buf, path_buf.len);
            if (n > 0) {
                return try allocator.dupe(u8, path_buf[0..@as(usize, @intCast(n))]);
            }
            return error.ProcessExited;
        } else {
            return error.ProcessExited;
        }
    }

    pub fn reap(self: *Pty) void {
        if (self.pid > 0) {
            var status: c_int = 0;
            const rc = waitpid(self.pid, &status, WNOHANG);
            if (rc > 0 or (rc == -1 and std.c.errno(rc) == .CHILD)) self.pid = -1;
        }
    }

    pub fn deinit(self: *Pty) void {
        if (self.allocator) |alloc| {
            if (self.input_buf.capacity > 0) {
                self.input_buf.deinit(alloc);
                self.input_buf = .empty;
            }
            self.allocator = null;
        }
        if (self.pid > 0) {
            _ = std.c.kill(self.pid, std.c.SIG.KILL);
        }
        if (self.master >= 0) {
            _ = close(self.master);
            self.master = -1;
        }
        if (self.slave >= 0) {
            _ = close(self.slave);
            self.slave = -1;
        }
        self.reap();
    }

    pub fn readOutput(self: *Pty, buf: []u8) Error!usize {
        const n = read(self.master, buf.ptr, buf.len);
        if (n < 0) {
            const err = std.c.errno(n);
            if (err == .AGAIN) return 0;
            return error.ReadFailed;
        }
        if (n == 0) return error.ProcessExited;
        return @as(usize, @intCast(n));
    }

    pub fn writeInput(self: *Pty, data: []const u8) Error!void {
        // The master is O_NONBLOCK, so this never blocks the server. The fast
        // path writes what fits; anything left over is queued and drained when
        // the child reads its stdin again (see flushInput / POLLOUT).
        var off: usize = 0;
        while (off < data.len) {
            const n = write(self.master, data.ptr + off, data.len - off);
            if (n < 0) {
                const err = std.c.errno(n);
                if (err == .INTR) continue;
                if (err == .AGAIN) break;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            off += @as(usize, @intCast(n));
        }
        if (off >= data.len) return;
        // Pty input buffer is full (child isn't reading stdin, e.g. it is
        // throttled by flow control). Queue the remainder so keystrokes are
        // not lost; the server drains it on POLLOUT.
        const rem = data[off..];
        const alloc = self.allocator orelse return error.WriteFailed;
        if (self.input_buf.items.len + rem.len > 1024 * 1024) return error.WriteFailed;
        self.input_buf.appendSlice(alloc, rem) catch return error.WriteFailed;
    }

    /// Non-blocking drain of queued keystrokes. Returns true when the whole
    /// queue was written (or the fd is unwritable for good, in which case the
    /// queue is dropped); false when the child is still not reading and the
    /// remainder stays queued for a later POLLOUT drain.
    pub fn flushInput(self: *Pty) bool {
        if (self.input_buf.items.len == 0) return true;
        var off: usize = 0;
        while (off < self.input_buf.items.len) {
            const n = write(self.master, self.input_buf.items.ptr + off, self.input_buf.items.len - off);
            if (n < 0) {
                const err = std.c.errno(n);
                if (err == .INTR) continue;
                if (err == .AGAIN) break;
                self.input_buf.clearRetainingCapacity();
                return true;
            }
            if (n == 0) break;
            off += @as(usize, @intCast(n));
        }
        if (off >= self.input_buf.items.len) {
            self.input_buf.clearRetainingCapacity();
            return true;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, self.input_buf.items[0 .. self.input_buf.items.len - off], self.input_buf.items[off..]);
            self.input_buf.items.len -= off;
        }
        return false;
    }

    pub fn setWinSize(self: *Pty, ws: *const std.c.winsize) Error!void {
        if (ioctl(self.master, TIOCSWINSZ, ws) < 0) return error.IoctlFailed;
    }

    pub fn getForegroundProcessName(self: *const Pty, buf: []u8) Error![]const u8 {
        const pgid = tcgetpgrp(self.master);
        if (pgid < 0) return error.ProcessExited;

        const builtin = @import("builtin");
        if (builtin.os.tag == .macos) {
            proc_name(pgid, buf.ptr, @intCast(buf.len));
            const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
            return buf[0..len];
        } else if (builtin.os.tag == .linux) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pgid}) catch return error.ReadFailed;
            const fd = std.c.open(path, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (fd < 0) return error.ReadFailed;
            defer _ = std.c.close(fd);
            const n = std.c.read(fd, buf.ptr, buf.len);
            if (n <= 0) return error.ReadFailed;
            const raw_name = buf[0..@as(usize, @intCast(n))];
            const name = std.mem.trimEnd(u8, raw_name, "\r\n\x00 ");
            return name;
        } else {
            return error.ReadFailed;
        }
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

test "spawn with multiple argv elements — bug #123" {
    var pty = try Pty.open();
    defer pty.deinit();

    const argv = [_][]const u8{ "sh", "-c", "true" };
    try pty.spawn(testing.allocator, &argv, "", "", null, 1024);
}

test "writeInput retries partial write — bug #124" {
    // Use a pipe as a fake PTY master
    var fds: [2]c_int = undefined;
    if (pipe(&fds) < 0) return error.PipeFailed;
    defer _ = close(fds[0]);
    defer _ = close(fds[1]);

    var pty = Pty{ .master = fds[1], .slave = -1, .pid = -1 };

    const data = "hello, pty!";
    try pty.writeInput(data);

    var buf: [64]u8 = undefined;
    const n = read(fds[0], &buf, buf.len);
    try testing.expect(n == data.len);
    try testing.expectEqualStrings(data, buf[0..@intCast(n)]);
}

test "reap only clears pid on actual child exit — bug #125" {
    var pty = try Pty.open();
    defer pty.deinit();

    const argv = [_][]const u8{ "sh", "-c", "exit 42" };
    try pty.spawn(testing.allocator, &argv, "", "", null, 1024);
    try testing.expect(pty.pid > 0);

    // reap immediately — child might not have exited yet
    pty.reap();
    // pid should either be >0 (still running) or -1 (reaped).
    // The key invariant: reap only clears pid after waitpid succeeds.
}

test "getCwd with zero-terminated stack buffer — bug #242" {
    var pty = try Pty.open();
    defer pty.deinit();

    const argv = [_][]const u8{"true"};
    try pty.spawn(testing.allocator, &argv, "", "", null, 1024);

    // Call getCwd: should return duplicated cwd or ProcessExited
    if (pty.getCwd(testing.allocator)) |cwd| {
        defer testing.allocator.free(cwd);
        try testing.expect(cwd.len > 0);
    } else |_| {}
}

test "writeInput queues remainder under backpressure and flushInput drains it — bug #298" {
    var fds: [2]c_int = undefined;
    if (pipe(&fds) < 0) return error.PipeFailed;
    defer _ = close(fds[0]);

    // Make the write end non-blocking so a full pipe returns EAGAIN.
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = comptime switch (@import("builtin").os.tag) {
        .linux => @as(c_int, 0o4000),
        else => @as(c_int, 0x0004),
    };
    const flags = fcntl(fds[1], F_GETFL, @as(c_int, 0));
    if (flags >= 0) _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK);

    var pty = Pty{ .master = fds[1], .slave = -1, .pid = -1, .allocator = testing.allocator };
    defer pty.deinit();

    // Fill the kernel pipe buffer so the next write EAGAINs immediately.
    var junk: [65536]u8 = undefined;
    @memset(&junk, 'x');
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const n = write(fds[1], &junk, junk.len);
        if (n <= 0) break;
    }

    // A write larger than what fits must queue the remainder instead of
    // dropping keystrokes (flow control, bug #298).
    const big = try testing.allocator.alloc(u8, 1 << 18);
    defer testing.allocator.free(big);
    @memset(big, 'y');
    try pty.writeInput(big);
    try testing.expect(pty.input_buf.items.len > 0);

    // Drain the read end and flush repeatedly until the queue empties.
    // flushInput makes forward progress but returns false when the pipe is
    // momentarily full (the real server retries on POLLOUT), so keep reading
    // to free pipe room until the whole queue is written.
    var drain: [16384]u8 = undefined;
    var dguard: usize = 0;
    while (pty.input_buf.items.len > 0 and dguard < 10000) : (dguard += 1) {
        _ = read(fds[0], &drain, drain.len);
        _ = pty.flushInput();
    }
    try testing.expectEqual(@as(usize, 0), pty.input_buf.items.len);
}

test "Pty.deinit is safe when unspawned and idempotent — bug #439" {
    var pty = try Pty.open();
    // deinit on unspawned Pty must not crash or use undefined allocator
    pty.deinit();
    // calling deinit a second time must be a safe no-op
    pty.deinit();
}
