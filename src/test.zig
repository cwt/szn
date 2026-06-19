const std = @import("std");

comptime {
    _ = @import("colour.zig");
    _ = @import("grid.zig");
    _ = @import("screen.zig");
    _ = @import("key.zig");
    _ = @import("window.zig");
    _ = @import("session.zig");
    _ = @import("layout.zig");
    _ = @import("options.zig");
    _ = @import("cfg.zig");
    _ = @import("tty/tty.zig");
    _ = @import("tty/tty_key.zig");
}
