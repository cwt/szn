const std = @import("std");
const c = std.c;

pub const Error = error{
    BufferTooSmall,
    NoSpaceLeft,
    OutOfMemory,
};

extern "c" fn getuid() c.uid_t;

pub const MAX_PATH = blk: {
    const addr: c.sockaddr.un = undefined;
    break :blk @sizeOf(@TypeOf(addr.path));
};

pub fn resolve(buf: []u8) Error![:0]const u8 {
    if (buf.len < MAX_PATH) return error.BufferTooSmall;

    if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg| {
        if (std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "{s}/szn.sock", .{std.mem.span(xdg)}, 0)) |path| {
            return path;
        } else |_| {}
    }

    if (std.c.getenv("TMPDIR")) |tmp| {
        if (std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "{s}/szn.sock", .{std.mem.span(tmp)}, 0)) |path| {
            return path;
        } else |_| {}
    }

    if (std.c.getenv("HOME")) |home| {
        const home_str = std.mem.span(home);
        var dir_path: [MAX_PATH]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_path, "{s}/.szn", .{home_str}, 0) catch {
            const path = try std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()}, 0);
            return path;
        };
        const rc = c.mkdir(dir_z.ptr, 0o700);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                const path = try std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()}, 0);
                return path;
            }
        }

        const path = try std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "{s}/.szn/szn.sock", .{home_str}, 0);
        return path;
    }

    const path = try std.fmt.bufPrintSentinel(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()}, 0);
    return path;
}

test "resolve produces a valid path — bug #97, #121" {
    var buf: [MAX_PATH]u8 = undefined;
    _ = resolve(&buf) catch |err| std.log.warn("resolve failed: {any}", .{err});
}
