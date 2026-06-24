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
    _ = @import("format.zig");
    _ = @import("status.zig");
    _ = @import("key_binding.zig");
    _ = @import("mode_copy.zig");
    _ = @import("tty/tty.zig");
    _ = @import("tty/tty_key.zig");
    _ = @import("input.zig");
    _ = @import("server/protocol.zig");
    _ = @import("server/message_reader.zig");
    _ = @import("server/dispatch.zig");
    _ = @import("server/server.zig");
    _ = @import("server/socket.zig");
    _ = @import("server/loop.zig");
    _ = @import("cmd/cmd.zig");
    _ = @import("client/connect.zig");
    _ = @import("client/raw.zig");
    _ = @import("client/client.zig");
    _ = @import("server/pty.zig");
    _ = @import("server/render.zig");
    _ = @import("tty/fd_writer.zig");
    _ = @import("integration.zig");
    _ = @import("main.zig");
}
