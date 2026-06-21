const std = @import("std");
const c = std.c;

extern "c" fn getuid() c.uid_t;

pub const MAX_PATH = blk: {
    const addr: c.sockaddr.un = undefined;
    break :blk @sizeOf(@TypeOf(addr.path));
};

pub fn resolve(buf: []u8) ![:0]const u8 {
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
        _ = c.mkdir(dir_z.ptr, 0o700);

        const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "{s}/.szn/szn.sock", .{home_str});
        return path;
    }

    const path = try std.fmt.bufPrintZ(buf[0..MAX_PATH], "/tmp/szn-{d}.sock", .{getuid()});
    return path;
}
