const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    WriteFailed,
};

pub const Level = enum(u3) {
    debug,
    info,
    warn,
    err,
};

extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c.mode_t) c_int;
extern "c" fn getuid() c.uid_t;

const O_WRONLY = 1;
const O_CREAT = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 0x0200,
    else => 0x0040,
};
const O_TRUNC = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 0x0400,
    else => 0x0200,
};

var log_fd: ?std.posix.fd_t = null;
var log_fd_failed: bool = false;
var log_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn resolveLogPath(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |xdg_raw| {
        const xdg = std.mem.span(xdg_raw);
        var dir_buf: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}/szn", .{xdg}) catch
            return try resolveHomeOrTmp(buf);
        const rc = c.mkdir(dir_z.ptr, 0o755);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                return try resolveHomeOrTmp(buf);
            }
        }
        return std.fmt.bufPrintZ(buf, "{s}/szn/szn.log", .{xdg}) catch
            return try resolveHomeOrTmp(buf);
    }
    return try resolveHomeOrTmp(buf);
}

fn resolveHomeOrTmp(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("HOME")) |home| {
        const home_str = std.mem.span(home);
        var dir_path: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_path, "{s}/.szn", .{home_str}) catch
            return try resolveTmp(buf);
        const rc = c.mkdir(dir_z.ptr, 0o700);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                return try resolveTmp(buf);
            }
        }
        return std.fmt.bufPrintZ(buf, "{s}/.szn/szn.log", .{home_str}) catch
            return try resolveTmp(buf);
    }
    return try resolveTmp(buf);
}

fn resolveTmp(buf: []u8) Error![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/szn-{d}.log", .{getuid()});
}

fn writeAllRaw(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = c.write(fd, remaining.ptr, @intCast(remaining.len));
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (!log_enabled.load(.seq_cst)) return;
    if (log_fd == null) {
        if (log_fd_failed) return;
        var path_buf: [256]u8 = undefined;
        const path = resolveLogPath(&path_buf) catch {
            log_fd_failed = true;
            return;
        };
        const fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
        if (fd < 0) {
            log_fd_failed = true;
            return;
        }
        log_fd = fd;
    }
    const fd = log_fd.?;
    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{s}] ", .{@tagName(level)}) catch return;
    const msg = std.fmt.bufPrint(buf[prefix.len..], format, args) catch {
        writeAllRaw(fd, buf[0..prefix.len]);
        writeAllRaw(fd, "log message too long\n");
        return;
    };
    const total_len = prefix.len + msg.len;
    if (total_len < buf.len) {
        buf[total_len] = '\n';
        writeAllRaw(fd, buf[0 .. total_len + 1]);
    } else {
        writeAllRaw(fd, buf[0..total_len]);
        writeAllRaw(fd, "\n");
    }
}

pub fn enable(path_or_default: []const u8) void {
    if (path_or_default.len == 0) return;
    const fd = if (std.mem.eql(u8, path_or_default, "default")) blk: {
        var buf: [256]u8 = undefined;
        const resolved = resolveLogPath(&buf) catch return;
        break :blk open(resolved, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
    } else blk2: {
        var path_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path_or_default}) catch return;
        break :blk2 open(path_z.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
    };
    if (fd < 0) return;
    if (log_fd) |old| _ = c.close(old);
    log_fd = fd;
    log_fd_failed = false;
    log_enabled.store(true, .seq_cst);
}

pub fn disable() void {
    if (log_fd) |fd| {
        _ = c.close(fd);
    }
    log_fd = null;
    log_fd_failed = false;
    log_enabled.store(false, .seq_cst);
}

pub fn isEnabled() bool {
    return log_enabled.load(.seq_cst);
}

pub fn log(comptime level: Level, comptime msg: []const u8, args: anytype) void {
    const zig_level: std.log.Level = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    std.log.scoped(.szn).log(zig_level, "[szn] " ++ msg, args);
}

test "errno retrieval via std.c.errno correctly reads EEXIST from mkdir" {
    const tmp_dir = "/tmp/szn_test_errno_eextst";
    defer _ = c.rmdir(tmp_dir);

    // Create the directory first
    var rc = c.mkdir(tmp_dir, 0o755);
    try std.testing.expect(rc == 0);

    // mkdir again should fail with EEXIST
    rc = c.mkdir(tmp_dir, 0o755);
    try std.testing.expect(rc < 0);

    const err = c.errno(rc);
    try std.testing.expectEqual(std.c.E.EXIST, err);
}

test "logFn writes single line atomically" {
    const sub_path = "/tmp/szn_test_log_atomic.log";
    const fd = std.c.open(sub_path, std.c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, @as(c_uint, 0o644));
    if (fd < 0) return error.FileOpen;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd = old_log_fd;
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd = fd;
    log_enabled.store(true, .seq_cst);

    logFn(.info, .default, "Test formatted log: {d} + {d} = {d}", .{ 1, 2, 3 });

    var buf: [1024]u8 = undefined;
    const n = std.c.pread(fd, &buf, buf.len, 0);
    if (n < 0) return error.ReadFailed;

    try std.testing.expectEqualStrings("[info] Test formatted log: 1 + 2 = 3\n", buf[0..@intCast(n)]);
}

test "logFn handles buffer overflow without writing garbage" {
    const sub_path = "/tmp/szn_test_log_overflow.log";
    const fd = std.c.open(sub_path, std.c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, @as(c_uint, 0o644));
    if (fd < 0) return error.FileOpen;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd = old_log_fd;
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd = fd;
    log_enabled.store(true, .seq_cst);

    var big_buf: [5000]u8 = undefined;
    @memset(big_buf[0..5000], 'X');
    const big_str = big_buf[0..4096];
    logFn(.info, .default, "{s}", .{big_str});

    var read_buf: [8192]u8 = undefined;
    const n = std.c.pread(fd, &read_buf, read_buf.len, 0);
    if (n < 0) return error.ReadFailed;

    try std.testing.expect(n > 0);
    try std.testing.expect(read_buf[@intCast(n - 1)] == '\n');
    try std.testing.expect(std.mem.indexOfScalar(u8, read_buf[0..@intCast(n)], @as(u8, 0)) == null);
}

test "logFn does not retry open after failure" {
    const old_log_fd = log_fd;
    const old_log_fd_failed = log_fd_failed;
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd = old_log_fd;
        log_fd_failed = old_log_fd_failed;
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd = null;
    log_fd_failed = true;
    log_enabled.store(true, .seq_cst);

    logFn(.info, .default, "should not retry", .{});
    try std.testing.expect(log_fd == null);
    try std.testing.expect(log_fd_failed);
}

test "logFn silently discards when not enabled" {
    const sub_path = "/tmp/szn_test_log_disabled.log";
    _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    const old_log_fd_failed = log_fd_failed;
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd = old_log_fd;
        log_fd_failed = old_log_fd_failed;
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd = null;
    log_fd_failed = false;
    log_enabled.store(false, .seq_cst);

    logFn(.info, .default, "this should not appear", .{});
    try std.testing.expect(log_fd == null);

    const fd = std.c.open(sub_path, std.c.O{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(fd < 0);
}

test "resolveLogPath fallback on invalid XDG_STATE_HOME" {
    const old_xdg = std.c.getenv("XDG_STATE_HOME");

    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;

    _ = setenv("XDG_STATE_HOME", "/nonexistent/invalid/dir/szn_test_log", 1);

    var path_buf: [256]u8 = undefined;
    const path = try resolveLogPath(&path_buf);

    // Should fall through to HOME or /tmp, not the invalid XDG dir
    try std.testing.expect(!std.mem.startsWith(u8, path, "/nonexistent"));

    if (old_xdg) |old| {
        _ = setenv("XDG_STATE_HOME", old, 1);
    } else {
        _ = setenv("XDG_STATE_HOME", "", 1);
    }
}

test "enable and disable cycle" {
    const sub_path = "/tmp/szn_test_log_enable.log";
    defer _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd;
    const old_log_fd_failed = log_fd_failed;
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd = old_log_fd;
        log_fd_failed = old_log_fd_failed;
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd = null;
    log_fd_failed = false;
    log_enabled.store(false, .seq_cst);

    enable(sub_path);
    try std.testing.expect(isEnabled());
    try std.testing.expect(log_fd != null);

    logFn(.info, .default, "enabled log", .{});

    disable();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(log_fd == null);
}
