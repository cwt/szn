const std = @import("std");
const server_mod = @import("server/server.zig");
const Server = server_mod.Server;
const cmd_mod = @import("cmd/cmd.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    _ = try server.newSession("default");
    try server.listen();

    while (server.loop.running) {
        try server.run();
    }
}
