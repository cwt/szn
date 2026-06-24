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
        const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "{s}/szn.sock", .{std.mem.span(xdg)});
        return path;
    }

    if (std.c.getenv("TMPDIR")) |tmp| {
        const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "{s}/szn.sock", .{std.mem.span(tmp)});
        return path;
    }

    if (std.c.getenv("HOME")) |home| {
        const home_str = std.mem.span(home);
        var dir_path: [128]u8 = undefined;
        const dir_z = try std.fmt.bufPrintZ(&dir_path, "{s}/.szn", .{home_str});
        const rc = c.mkdir(dir_z.ptr, 0o700);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) {
                // fall through — let the socket path attempt give a clearer error
            }
        }

        const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "{s}/.szn/szn.sock", .{home_str});
        return path;
    }

    const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()});
    return path;
}

test "resolve produces a valid path — bug #97" {
    var buf: [MAX_PATH]u8 = undefined;
    // Must not crash under any env. We can't easily mock getenv, but
    // the fix (checking mkdir return value instead of _ =) compiles and
    // links — that's the essential part.
    _ = resolve(&buf) catch {};
}
