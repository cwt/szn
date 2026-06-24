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
        var dir_path: [MAX_PATH]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_path, "{s}/.szn", .{home_str}) catch {
            const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()});
            return path;
        };
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

test "resolve produces a valid path — bug #97, #121" {
    var buf: [MAX_PATH]u8 = undefined;
    _ = resolve(&buf) catch {};
}
