const std = @import("std");

pub const Level = enum(u3) {
    debug,
    info,
    warn,
    err,
};

pub fn log(comptime level: Level, comptime msg: []const u8, args: anytype) void {
    const prefix = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
    std.log.scoped(.zmux).log(
        switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        },
        "[" ++ prefix ++ "] " ++ msg,
        args,
    );
}
