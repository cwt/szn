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
extern "c" fn fchmod(fd: c_int, mode: c.mode_t) c_int;
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
const O_APPEND = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 0x0008,
    else => 0x0400,
};

/// Sentinel stored in `log_fd` when no log file is open. An `std.posix.fd_t` is
/// only ever a valid descriptor when >= 0, so -1 is unambiguous and avoids the
/// optional payload that a plain `?fd_t` would need.
const NO_LOG_FD: std.posix.fd_t = -1;

// The fd is atomic for the same reason the two flags beside it are: it is the
// value those flags guard. A plain global would be read by `logFn` while
// `enable`/`disable` swap it, which is a data race under the Zig memory model
// and could let a writer reach a descriptor that has already been closed (and
// possibly recycled). Making the guarded value atomic gives it the same
// discipline as the guard. See bug #510 for the residual ordering window and
// why it is unreachable today.
var log_fd: std.atomic.Value(std.posix.fd_t) = std.atomic.Value(std.posix.fd_t).init(NO_LOG_FD);
var log_fd_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var log_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// True when `fd` no longer refers to an open descriptor.
///
/// Probes with F_GETFD rather than calling close() on an already-closed fd:
/// a second close can land on a descriptor the OS has already recycled.
fn isClosed(fd: std.posix.fd_t) bool {
    return std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0)) < 0;
}

/// Read the current log descriptor, or `null` when logging has no file open.
fn currentLogFd() ?std.posix.fd_t {
    const fd = log_fd.load(.seq_cst);
    return if (fd == NO_LOG_FD) null else fd;
}

fn resolveLogPath(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |xdg_raw| {
        const xdg = std.mem.span(xdg_raw);
        var dir_buf: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}/szn", .{xdg}, 0) catch
            return try resolveHomeOrTmp(buf);
        const rc = c.mkdir(dir_z.ptr, 0o755);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                return try resolveHomeOrTmp(buf);
            }
        }
        return std.fmt.bufPrintSentinel(buf, "{s}/szn/szn.log", .{xdg}, 0) catch
            return try resolveHomeOrTmp(buf);
    }
    return try resolveHomeOrTmp(buf);
}

fn resolveHomeOrTmp(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("HOME")) |home| {
        const home_str = std.mem.span(home);
        var dir_path: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_path, "{s}/.szn", .{home_str}, 0) catch
            return try resolveTmp(buf);
        const rc = c.mkdir(dir_z.ptr, 0o700);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                return try resolveTmp(buf);
            }
        }
        return std.fmt.bufPrintSentinel(buf, "{s}/.szn/szn.log", .{home_str}, 0) catch
            return try resolveTmp(buf);
    }
    return try resolveTmp(buf);
}

fn resolveTmp(buf: []u8) Error![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "/tmp/szn-{d}.log", .{getuid()}, 0);
}

/// Dedicated log path for the interactive client (the "default" target of
/// `enableClientLog`): ~/.szn/szn-client.log (or /tmp fallback). Kept separate
/// from the server's resolveLogPath so the two logs never collide.
fn resolveClientPath(buf: []u8) Error![:0]const u8 {
    if (std.c.getenv("HOME")) |home| {
        const home_str = std.mem.span(home);
        var dir_path: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_path, "{s}/.szn", .{home_str}, 0) catch
            return std.fmt.bufPrintSentinel(buf, "/tmp/szn-client-{d}.log", .{getuid()}, 0) catch error.NoSpaceLeft;
        const rc = c.mkdir(dir_z.ptr, 0o700);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                return std.fmt.bufPrintSentinel(buf, "/tmp/szn-client-{d}.log", .{getuid()}, 0) catch error.NoSpaceLeft;
            }
        }
        return std.fmt.bufPrintSentinel(buf, "{s}/.szn/szn-client.log", .{home_str}, 0) catch error.NoSpaceLeft;
    }
    return std.fmt.bufPrintSentinel(buf, "/tmp/szn-client-{d}.log", .{getuid()}, 0) catch error.NoSpaceLeft;
}

fn writeAllRaw(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = c.write(fd, remaining.ptr, @intCast(remaining.len));
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

var runtime_log_level: Level = .info;

/// Called once from enable() / enableClientLog() after the fd is published.
/// Reads SZN_LOG env var (values: "debug", "info", "warn", "err") and sets
/// runtime_log_level accordingly so callers can override without recompiling.
fn applyEnvLogLevel() void {
    const val = std.c.getenv("SZN_LOG") orelse return;
    const s = std.mem.span(val);
    if (std.mem.eql(u8, s, "debug")) {
        runtime_log_level = .debug;
    } else if (std.mem.eql(u8, s, "info")) {
        runtime_log_level = .info;
    } else if (std.mem.eql(u8, s, "warn")) {
        runtime_log_level = .warn;
    } else if (std.mem.eql(u8, s, "err")) {
        runtime_log_level = .err;
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
    // Runtime level filter: suppresses noisy debug/info lines unless SZN_LOG
    // overrides it.  The comptime log_level in std_options is .debug so that
    // Zig doesn't eliminate any call sites at compile time.
    const my_level: Level = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    if (@intFromEnum(my_level) < @intFromEnum(runtime_log_level)) return;
    if (log_fd.load(.seq_cst) == NO_LOG_FD) {
        if (log_fd_failed.load(.seq_cst)) return;
        var path_buf: [256]u8 = undefined;
        const path = resolveLogPath(&path_buf) catch {
            log_fd_failed.store(true, .seq_cst);
            return;
        };
        const fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
        if (fd < 0) {
            log_fd_failed.store(true, .seq_cst);
            return;
        }
        // Publish before the write so a concurrent reader never sees a null fd
        // while logging is enabled.
        log_fd.store(fd, .seq_cst);
    }
    const fd = log_fd.load(.seq_cst);
    if (fd == NO_LOG_FD) return;
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
        break :blk open(resolved, O_WRONLY | O_CREAT | O_APPEND, 0o600);
    } else blk2: {
        var path_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path_or_default}, 0) catch return;
        break :blk2 open(path_z.ptr, O_WRONLY | O_CREAT | O_APPEND, 0o600);
    };
    if (fd < 0) return;
    _ = fchmod(fd, 0o600);
    const old = log_fd.swap(fd, .seq_cst);
    if (old != NO_LOG_FD) _ = c.close(old);
    log_fd_failed.store(false, .seq_cst);
    log_enabled.store(true, .seq_cst);
    applyEnvLogLevel();
}

pub fn disable() void {
    // Clear the gate before closing, so no writer can start after the close.
    log_enabled.store(false, .seq_cst);
    const old = log_fd.swap(NO_LOG_FD, .seq_cst);
    if (old != NO_LOG_FD) _ = c.close(old);
    log_fd_failed.store(false, .seq_cst);
}

/// Enable the interactive client's log. Mirrors `enable` but resolves the
/// "default" value to the client's own well-known path (~/.szn/szn-client.log)
/// instead of the server's. An empty `path_or_default` leaves logging disabled.
/// The client receives this path from the server via the `client_log` message
/// (driven by the `client-log-file` config option), since it never loads the
/// server config itself (bug #298 diagnostics).
pub fn enableClientLog(path_or_default: []const u8) void {
    if (path_or_default.len == 0) return;
    const fd = if (std.mem.eql(u8, path_or_default, "default")) blk: {
        var buf: [256]u8 = undefined;
        const resolved = resolveClientPath(&buf) catch return;
        break :blk open(resolved, O_WRONLY | O_CREAT | O_APPEND, 0o600);
    } else blk2: {
        var path_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path_or_default}, 0) catch return;
        break :blk2 open(path_z.ptr, O_WRONLY | O_CREAT | O_APPEND, 0o600);
    };
    if (fd < 0) return;
    _ = fchmod(fd, 0o600);
    const old = log_fd.swap(fd, .seq_cst);
    if (old != NO_LOG_FD) _ = c.close(old);
    log_fd_failed.store(false, .seq_cst);
    log_enabled.store(true, .seq_cst);
    applyEnvLogLevel();
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

    const old_log_fd = log_fd.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd.store(old_log_fd, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(fd, .seq_cst);
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

    const old_log_fd = log_fd.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd.store(old_log_fd, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(fd, .seq_cst);
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
    const old_log_fd = log_fd.load(.seq_cst);
    const old_log_fd_failed = log_fd_failed.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd.store(old_log_fd, .seq_cst);
        log_fd_failed.store(old_log_fd_failed, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(NO_LOG_FD, .seq_cst);
    log_fd_failed.store(true, .seq_cst);
    log_enabled.store(true, .seq_cst);

    logFn(.info, .default, "should not retry", .{});
    try std.testing.expect(currentLogFd() == null);
    try std.testing.expect(log_fd_failed.load(.seq_cst));
}

test "logFn silently discards when not enabled" {
    const sub_path = "/tmp/szn_test_log_disabled.log";
    _ = std.c.unlink(sub_path);

    const old_log_fd = log_fd.load(.seq_cst);
    const old_log_fd_failed = log_fd_failed.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd.store(old_log_fd, .seq_cst);
        log_fd_failed.store(old_log_fd_failed, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(NO_LOG_FD, .seq_cst);
    log_fd_failed.store(false, .seq_cst);
    log_enabled.store(false, .seq_cst);

    logFn(.info, .default, "this should not appear", .{});
    try std.testing.expect(currentLogFd() == null);

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

    const old_log_fd = log_fd.load(.seq_cst);
    const old_log_fd_failed = log_fd_failed.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        log_fd.store(old_log_fd, .seq_cst);
        log_fd_failed.store(old_log_fd_failed, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(NO_LOG_FD, .seq_cst);
    log_fd_failed.store(false, .seq_cst);
    log_enabled.store(false, .seq_cst);

    enable(sub_path);
    try std.testing.expect(isEnabled());
    try std.testing.expect(currentLogFd() != null);

    logFn(.info, .default, "enabled log", .{});

    disable();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(currentLogFd() == null);
}

test "enable/disable swap the fd exactly once and disable is idempotent — bug #510" {
    const path_a = "/tmp/szn_test_log_swap_a.log";
    const path_b = "/tmp/szn_test_log_swap_b.log";
    defer _ = std.c.unlink(path_a);
    defer _ = std.c.unlink(path_b);

    const old_log_fd = log_fd.load(.seq_cst);
    const old_log_fd_failed = log_fd_failed.load(.seq_cst);
    const old_enabled = log_enabled.load(.seq_cst);
    defer {
        if (currentLogFd()) |fd| _ = c.close(fd);
        log_fd.store(old_log_fd, .seq_cst);
        log_fd_failed.store(old_log_fd_failed, .seq_cst);
        log_enabled.store(old_enabled, .seq_cst);
    }
    log_fd.store(NO_LOG_FD, .seq_cst);
    log_fd_failed.store(false, .seq_cst);
    log_enabled.store(false, .seq_cst);

    // First enable publishes an fd.
    enable(path_a);
    try std.testing.expect(isEnabled());
    const fd_a = currentLogFd().?;
    try std.testing.expect(!isClosed(fd_a));

    // Re-enabling replaces it, and the retired descriptor is closed exactly
    // once -- so no double-close can land on an unrelated, recycled fd.
    enable(path_b);
    try std.testing.expect(isEnabled());
    const fd_b = currentLogFd().?;
    try std.testing.expect(fd_b != fd_a);
    try std.testing.expect(isClosed(fd_a));
    try std.testing.expect(!isClosed(fd_b));

    // The write goes to the currently published descriptor. `enable` opens
    // O_WRONLY, so read the file back through a separate descriptor.
    logFn(.info, .default, "after re-enable", .{});
    const rfd = std.c.open(path_b, std.c.O{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(rfd >= 0);
    defer _ = std.c.close(rfd);
    var buf: [512]u8 = undefined;
    const n = std.c.pread(rfd, &buf, buf.len, 0);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(n)], "after re-enable") != null);

    // disable() clears the gate before retiring the fd.
    disable();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(currentLogFd() == null);
    try std.testing.expect(isClosed(fd_b));

    // Idempotent: a second disable must not close an already-closed fd.
    disable();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(currentLogFd() == null);
}
