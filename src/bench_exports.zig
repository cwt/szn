//! Re-exports of core szn subsystems for standalone benchmark tools (`tools/bench_algo.zig`).
//! Not imported by `src/main.zig`, so it adds zero runtime or binary size overhead to `szn`.
pub const compat = @import("compat.zig");
pub const colour = @import("colour.zig");
pub const char_width = @import("char_width.zig");
pub const grid = @import("grid.zig");
pub const thai = @import("thai.zig");
pub const screen = @import("screen.zig");
pub const input = @import("input.zig");
pub const layout = @import("layout.zig");
pub const window = @import("window.zig");
pub const io = @import("io.zig");
pub const status = @import("status.zig");
pub const mode_copy = @import("mode_copy.zig");
pub const render = @import("server/render.zig");
pub const message_reader = @import("server/message_reader.zig");
pub const protocol = @import("server/protocol.zig");
