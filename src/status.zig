const std = @import("std");
const testing = std.testing;
const format_mod = @import("format.zig");
const Context = format_mod.Context;
const expand = format_mod.expand;
const colour = @import("colour.zig");
const Colour = colour.Colour;

pub const Alignment = enum(u8) {
    left,
    centre,
    right,
};

pub const StatusBar = struct {
    left: []const u8 = "[#{session_name}] ",
    centre: []const u8 = "#{window_index}:#{window_name}",
    right: []const u8 = "%H:%M",
    fg: Colour = Colour.default_(),
    bg: Colour = Colour.default_(),
    justify: Alignment = .left,

    pub fn init() StatusBar {
        return .{};
    }

    pub fn render(
        self: *const StatusBar,
        allocator: std.mem.Allocator,
        ctx: *const Context,
        width: u32,
    ) !RenderedStatus {
        const left = try expand(allocator, self.left, ctx);
        errdefer allocator.free(left);

        const centre = try expand(allocator, self.centre, ctx);
        errdefer allocator.free(centre);

        const right = try expand(allocator, self.right, ctx);
        errdefer allocator.free(right);

        var line = try allocator.alloc(u8, width);
        @memset(line, ' ');

        const left_len = @min(left.len, width);
        @memcpy(line[0..left_len], left[0..left_len]);

        const right_len = @min(right.len, width);
        const right_start = if (width > right_len) width - right_len else 0;
        @memcpy(line[right_start..][0..right_len], right[right.len - right_len ..][0..right_len]);

        const centre_len = centre.len;
        const avail_start = left_len;
        const avail_end = right_start;
        const avail_width = if (avail_end > avail_start) avail_end - avail_start else 0;

        if (centre_len > 0 and avail_width > 0) {
            const centre_pos = switch (self.justify) {
                .left => avail_start,
                .right => if (avail_width > centre_len) avail_end - centre_len else avail_start,
                .centre => avail_start + (avail_width -| @min(centre_len, avail_width)) / 2,
            };
            const write_len = @min(centre_len, avail_width);
            const write_start = @min(centre_pos, width -| write_len);
            @memcpy(line[write_start..][0..write_len], centre[0..write_len]);
        }

        allocator.free(left);
        allocator.free(centre);
        allocator.free(right);

        return .{ .line = line };
    }
};

pub const RenderedStatus = struct {
    line: []const u8,

    pub fn deinit(self: *RenderedStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
    }
};

test "status bar default init" {
    const sb = StatusBar.init();
    try testing.expectEqualStrings("[#{session_name}] ", sb.left);
    try testing.expectEqual(.left, sb.justify);
}

test "render basic status bar" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "dev");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "editor");

    const sb = StatusBar.init();
    var rendered = try sb.render(testing.allocator, &ctx, 80);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 80), rendered.line.len);
    try testing.expect(std.mem.startsWith(u8, rendered.line, "[dev] "));
}

test "render right aligned" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "w");

    var sb = StatusBar.init();
    sb.right = "RIGHT";
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), rendered.line.len);
    try testing.expect(std.mem.endsWith(u8, rendered.line, "RIGHT"));
}

test "render centre justified" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "MID");

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "#{window_name}";
    sb.right = "";
    sb.justify = .centre;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), rendered.line.len);
    const mid_start = std.mem.indexOf(u8, rendered.line, "MID").?;
    try testing.expect(mid_start >= 7 and mid_start <= 9);
}

test "render truncates when too wide" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "very-long-session-name");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "w");

    const sb = StatusBar.init();
    var rendered = try sb.render(testing.allocator, &ctx, 10);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 10), rendered.line.len);
}

test "render empty sections" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "";
    sb.right = "";
    var rendered = try sb.render(testing.allocator, &ctx, 40);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 40), rendered.line.len);
    for (rendered.line) |c| {
        try testing.expectEqual(@as(u8, ' '), c);
    }
}

test "render with conditional" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "main");
    try ctx.set("window_index", "1");
    try ctx.set("window_name", "shell");
    try ctx.set("window_active", "1");

    var sb = StatusBar.init();
    sb.centre = "#{window_index}:#{window_name}#{?window_active,*,}";
    var rendered = try sb.render(testing.allocator, &ctx, 40);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.line, "1:shell*") != null);
}

test "render left justify" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "LEFT");

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "#{window_name}";
    sb.right = "";
    sb.justify = .left;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, rendered.line, "LEFT"));
}

test "render right justify" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "RIGHT");

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "#{window_name}";
    sb.right = "";
    sb.justify = .right;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    const idx = std.mem.indexOf(u8, rendered.line, "RIGHT").?;
    try testing.expect(idx >= 13);
}

test "render width 1" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "w");

    const sb = StatusBar.init();
    var rendered = try sb.render(testing.allocator, &ctx, 1);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), rendered.line.len);
}

test "render custom colours" {
    var sb = StatusBar.init();
    sb.fg = Colour.fromRgb(255, 255, 255);
    sb.bg = Colour.fromRgb(0, 0, 128);

    try testing.expectEqual(colour.Tag.rgb, sb.fg.tag);
    try testing.expectEqual(colour.Tag.rgb, sb.bg.tag);
}

test "render with format escapes" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "test");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "w");

    var sb = StatusBar.init();
    sb.left = "###{session_name}";
    var rendered = try sb.render(testing.allocator, &ctx, 40);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, rendered.line, "#test"));
}
