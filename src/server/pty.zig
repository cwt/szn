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

const PROC_PIDVNODEPATHINFO: c_int = 11;
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

const TIOCSWINSZ: c_ulong = 0x80087467;
const DEFAULT_SHELL: []const u8 = "/bin/zsh";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Pty = struct {
    master: i32,
    slave: i32,
    pid: i32,

    pub fn open() Error!Pty {
        var master: c_int = 0;
        var slave: c_int = 0;
        if (openpty(&master, &slave, null, null, null) < 0) return error.PtyOpenFailed;
        setCloexec(master);
        setCloexec(slave);
        return Pty{ .master = master, .slave = slave, .pid = -1 };
    }

    pub fn spawn(self: *Pty, allocator: std.mem.Allocator, argv: ?[]const []const u8, szn_env: []const u8, szn_pane: []const u8, cwd: ?[]const u8) Error!void {
        const args = argv orelse &.{DEFAULT_SHELL};

        var argv_z = try allocator.alloc(?[*:0]const u8, args.len + 1);
        for (args, 0..) |arg, i| {
            argv_z[i] = try allocator.dupeZ(u8, arg);
        }
        argv_z[args.len] = null;

        const szn_env_z = try allocator.dupeZ(u8, szn_env);
        defer allocator.free(szn_env_z);
        const szn_pane_z = try allocator.dupeZ(u8, szn_pane);
        defer allocator.free(szn_pane_z);

        const cwd_z = if (cwd) |c| try allocator.dupeZ(u8, c) else null;
        defer if (cwd_z) |c| allocator.free(c);

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = close(self.master);
            _ = login_tty(self.slave);

            if (cwd_z) |c| _ = chdir(c);

            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("TERM_PROGRAM", "szn", 1);
            _ = setenv("SZN", szn_env_z, 1);
            _ = setenv("SZN_PANE", szn_pane_z, 1);

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
            const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pgrp}) catch return error.ProcessExited;
            const proc_path_z = try allocator.dupeZ(u8, proc_path);
            defer allocator.free(proc_path_z);

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

    pub fn readOutput(self: *Pty, buf: []u8) Error!usize {
        const n = read(self.master, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.ProcessExited;
        return @as(usize, @intCast(n));
    }

    pub fn writeInput(self: *Pty, data: []const u8) Error!void {
        const n = write(self.master, data.ptr, data.len);
        if (n < 0) return error.WriteFailed;
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
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pgid}) catch return error.ReadFailed;
            const file = std.fs.openFileAbsolute(path, .{}) catch return error.ReadFailed;
            defer file.close();
            const bytes_read = file.readAll(buf) catch return error.ReadFailed;
            var name = buf[0..bytes_read];
            name = std.mem.trimRight(u8, name, "\r\n\x00 ");
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
