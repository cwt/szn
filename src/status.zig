const std = @import("std");
const testing = std.testing;
const format_mod = @import("format.zig");
const Context = format_mod.Context;
const expand = format_mod.expand;
const TemplateCache = format_mod.TemplateCache;
const colour = @import("colour.zig");
const Colour = colour.Colour;

pub const Error = error{
    OutOfMemory,
    InvalidFormat,
    UnterminatedBrace,
};

pub const Alignment = enum(u8) {
    left,
    centre,
    right,

    pub fn fromString(s: []const u8) Alignment {
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "centre") or std.mem.eql(u8, s, "center")) return .centre;
        return .left;
    }
};

pub const StatusBar = struct {
    left: []const u8 = "[#{session_name}] ",
    /// Pre-built window-list text (already expanded). Empty → no centre.
    centre: []const u8 = "",
    right: []const u8 = "\"#{=21:pane_title}\" %H:%M %d-%b-%y",
    left_length: u32 = 10,
    right_length: u32 = 40,
    fg: Colour = Colour.default_(),
    bg: Colour = Colour.default_(),
    justify: Alignment = .left,

    pub fn init() StatusBar {
        return .{};
    }

    /// Expand left/right templates and pack with a pre-built centre into a
    /// CSI-aware status line of exactly `width` visible columns.
    pub fn render(
        self: *const StatusBar,
        allocator: std.mem.Allocator,
        ctx: *const Context,
        width: u32,
    ) Error!RenderedStatus {
        return self.renderWithCache(allocator, ctx, width, null, null);
    }

    pub fn renderWithCache(
        self: *const StatusBar,
        allocator: std.mem.Allocator,
        ctx: *const Context,
        width: u32,
        left_cache: ?*TemplateCache,
        right_cache: ?*TemplateCache,
    ) Error!RenderedStatus {
        const left = try expandCached(allocator, self.left, ctx, left_cache);
        defer allocator.free(left);
        const right = try expandCached(allocator, self.right, ctx, right_cache);
        defer allocator.free(right);

        return try packLine(
            allocator,
            width,
            left,
            self.centre,
            right,
            self.left_length,
            self.right_length,
            self.justify,
        );
    }
};

fn expandCached(
    allocator: std.mem.Allocator,
    template: []const u8,
    ctx: *const Context,
    cache: ?*TemplateCache,
) Error![]const u8 {
    if (cache) |c| {
        const ops = try c.getOrCompile(allocator, template);
        return try format_mod.expandOps(allocator, ops, ctx);
    }
    return try expand(allocator, template, ctx);
}

pub const RenderedStatus = struct {
    line: []const u8,

    pub fn deinit(self: *const RenderedStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
    }
};

/// Count visible columns, skipping CSI / OSC escape sequences.
pub fn visibleLen(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEscape(s, i);
            continue;
        }
        // UTF-8: count one column per codepoint (status bar uses ASCII mostly;
        // wide chars still count as 1 here — good enough for packing).
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        cols += 1;
        i += cp_len;
    }
    return cols;
}

fn skipEscape(s: []const u8, start: usize) usize {
    if (start + 1 >= s.len) return s.len;
    if (s[start + 1] == '[') {
        // CSI: ESC [ ... final-byte @-~
        var i = start + 2;
        while (i < s.len) : (i += 1) {
            if (s[i] >= 0x40 and s[i] <= 0x7e) return i + 1;
        }
        return s.len;
    }
    if (s[start + 1] == ']') {
        // OSC: ESC ] ... BEL or ST
        var i = start + 2;
        while (i < s.len) : (i += 1) {
            if (s[i] == 0x07) return i + 1;
            if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') return i + 2;
        }
        return s.len;
    }
    // Other ESC sequences: skip ESC + one byte
    return start + 2;
}

/// Truncate `s` to at most `max_cols` visible columns, preserving CSI.
pub fn truncateVisible(allocator: std.mem.Allocator, s: []const u8, max_cols: usize) Error![]const u8 {
    if (max_cols == 0) return try allocator.dupe(u8, "");
    if (visibleLen(s) <= max_cols) return try allocator.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len and cols < max_cols) {
        if (s[i] == 0x1b) {
            const end = skipEscape(s, i);
            try out.appendSlice(allocator, s[i..end]);
            i = end;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        try out.appendSlice(allocator, s[i..end]);
        cols += 1;
        i = end;
    }
    return try out.toOwnedSlice(allocator);
}

fn packLine(
    allocator: std.mem.Allocator,
    width: u32,
    left_raw: []const u8,
    centre_raw: []const u8,
    right_raw: []const u8,
    left_max: u32,
    right_max: u32,
    justify: Alignment,
) Error!RenderedStatus {
    if (width == 0) return .{ .line = try allocator.dupe(u8, "") };

    const left = try truncateVisible(allocator, left_raw, left_max);
    defer allocator.free(left);
    const right = try truncateVisible(allocator, right_raw, right_max);
    defer allocator.free(right);

    const left_cols = visibleLen(left);
    const right_cols = visibleLen(right);
    const avail: usize = if (width > left_cols + right_cols)
        width - left_cols - right_cols
    else
        0;

    const centre = try truncateVisible(allocator, centre_raw, avail);
    defer allocator.free(centre);
    const centre_cols = visibleLen(centre);

    const pad_total = avail -| centre_cols;
    const pad_left: usize = switch (justify) {
        .left => 0,
        .right => pad_total,
        .centre => pad_total / 2,
    };
    const pad_right = pad_total -| pad_left;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, left);
    try appendSpaces(allocator, &out, pad_left);
    try out.appendSlice(allocator, centre);
    try appendSpaces(allocator, &out, pad_right);
    try out.appendSlice(allocator, right);

    // Ensure exactly `width` visible columns (fill if left+right overflowed).
    const used = visibleLen(out.items);
    if (used < width) {
        try appendSpaces(allocator, &out, width - used);
    } else if (used > width) {
        // left+right alone exceeded width — hard-truncate whole line
        const trimmed = try truncateVisible(allocator, out.items, width);
        defer allocator.free(trimmed);
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, trimmed);
    }

    return .{ .line = try out.toOwnedSlice(allocator) };
}

fn appendSpaces(allocator: std.mem.Allocator, out: *std.ArrayList(u8), n: usize) Error!void {
    try out.appendNTimes(allocator, ' ', n);
}

pub const WindowInfo = struct {
    index: u32,
    name: []const u8,
    flags: []const u8,
    is_active: bool,
};

pub const BuildInput = struct {
    session_name: []const u8,
    windows: []const WindowInfo,
    pane_title: []const u8 = "",
    pane_index: []const u8 = "0",
    host: []const u8 = "",
    host_short: []const u8 = "",
    left: []const u8 = "[#{session_name}] ",
    right: []const u8 = "\"#{=21:pane_title}\" %H:%M %d-%b-%y",
    left_length: u32 = 10,
    right_length: u32 = 40,
    justify: Alignment = .left,
    window_status_format: []const u8 = "#I:#W#{?window_flags,#{window_flags}, }",
    window_status_current_format: []const u8 = "#I:#W#{?window_flags,#{window_flags}, }",
    width: u32,
    left_cache: ?*TemplateCache = null,
    right_cache: ?*TemplateCache = null,
    win_fmt_cache: ?*TemplateCache = null,
    win_cur_cache: ?*TemplateCache = null,
};

/// Build a full tmux-style status line: left | window-list | right.
pub fn buildLine(allocator: std.mem.Allocator, input: BuildInput) Error!RenderedStatus {
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.set("session_name", input.session_name);
    try ctx.set("pane_title", input.pane_title);
    try ctx.set("pane_index", input.pane_index);
    try ctx.set("host", input.host);
    try ctx.set("host_short", input.host_short);

    var centre_buf: std.ArrayList(u8) = .empty;
    defer centre_buf.deinit(allocator);

    for (input.windows) |w| {
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{w.index}) catch "0";
        try ctx.set("window_index", idx_str);
        try ctx.set("window_name", w.name);
        try ctx.set("window_flags", w.flags);
        try ctx.set("window_active", if (w.is_active) "1" else "0");

        const tmpl = if (w.is_active) input.window_status_current_format else input.window_status_format;
        const cache = if (w.is_active) input.win_cur_cache else input.win_fmt_cache;
        const piece = try expandCached(allocator, tmpl, &ctx, cache);
        defer allocator.free(piece);
        try centre_buf.appendSlice(allocator, piece);
    }

    // The centre loop (above) overwrote window_index/name/flags/active for every
    // window, leaving the LAST window's values in the ctx. The active-window vars
    // used by the left/right templates must be restored before we expand them.
    for (input.windows) |w| {
        if (w.is_active) {
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{w.index}) catch "0";
            try ctx.set("window_index", idx_str);
            try ctx.set("window_name", w.name);
            try ctx.set("window_flags", w.flags);
            try ctx.set("window_active", "1");
            break;
        }
    }

    var sb = StatusBar.init();
    sb.left = input.left;
    sb.right = input.right;
    sb.centre = centre_buf.items;
    sb.left_length = input.left_length;
    sb.right_length = input.right_length;
    sb.justify = input.justify;

    return try sb.renderWithCache(allocator, &ctx, input.width, input.left_cache, input.right_cache);
}

pub const WindowRange = struct {
    /// Position (index into `input.windows`) of the window.
    pos: u32,
    /// Visible column where this window's status entry begins.
    start_col: u32,
    /// One past the last visible column of the entry (exclusive).
    end_col: u32,
};

/// Mirror `buildLine`'s left/centre/right packing and report the visible
/// column range of each window entry in the centre region. This lets mouse
/// hit-testing match clicks to windows using exactly what would be rendered,
/// instead of re-deriving the layout by hand (bug #290).
pub fn windowRanges(allocator: std.mem.Allocator, input: BuildInput) Error![]WindowRange {
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.set("session_name", input.session_name);
    try ctx.set("pane_title", input.pane_title);
    try ctx.set("pane_index", input.pane_index);
    try ctx.set("host", input.host);
    try ctx.set("host_short", input.host_short);

    const left = try expandCached(allocator, input.left, &ctx, input.left_cache);
    defer allocator.free(left);
    const right = try expandCached(allocator, input.right, &ctx, input.right_cache);
    defer allocator.free(right);

    const left_trim = try truncateVisible(allocator, left, input.left_length);
    defer allocator.free(left_trim);
    const right_trim = try truncateVisible(allocator, right, input.right_length);
    defer allocator.free(right_trim);

    const left_cols = visibleLen(left_trim);
    const right_cols = visibleLen(right_trim);
    const avail: usize = if (input.width > left_cols + right_cols)
        input.width - left_cols - right_cols
    else
        0;

    // Build each window's rendered piece and record its visible length, so the
    // centre region can be sub-divided exactly as buildLine lays it out.
    const Piece = struct { pos: usize, cols: usize };
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(allocator);

    for (input.windows, 0..) |w, pos| {
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{w.index}) catch "0";
        try ctx.set("window_index", idx_str);
        try ctx.set("window_name", w.name);
        try ctx.set("window_flags", w.flags);
        try ctx.set("window_active", if (w.is_active) "1" else "0");

        const tmpl = if (w.is_active) input.window_status_current_format else input.window_status_format;
        const cache = if (w.is_active) input.win_cur_cache else input.win_fmt_cache;
        const piece = try expandCached(allocator, tmpl, &ctx, cache);
        defer allocator.free(piece);
        try pieces.append(allocator, .{ .pos = pos, .cols = visibleLen(piece) });
    }

    // Same centre-packing arithmetic as packLine.
    var centre_cols: usize = 0;
    for (pieces.items) |p| centre_cols += p.cols;
    centre_cols = @min(centre_cols, avail);

    const pad_total = avail -| centre_cols;
    const pad_left: usize = switch (input.justify) {
        .left => 0,
        .right => pad_total,
        .centre => pad_total / 2,
    };
    const centre_start = left_cols + pad_left;

    var ranges: std.ArrayList(WindowRange) = .empty;
    errdefer ranges.deinit(allocator);
    var cursor: usize = 0;
    for (pieces.items) |p| {
        const start = @min(centre_start + cursor, centre_start + centre_cols);
        cursor += p.cols;
        const end = @min(centre_start + cursor, centre_start + centre_cols);
        if (end > start) {
            try ranges.append(allocator, .{
                .pos = @intCast(p.pos),
                .start_col = @intCast(start),
                .end_col = @intCast(end),
            });
        }
    }

    return try ranges.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "status bar default init" {
    const sb = StatusBar.init();
    try testing.expectEqualStrings("[#{session_name}] ", sb.left);
    try testing.expectEqual(.left, sb.justify);
}

test "render basic status bar" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "dev");

    var sb = StatusBar.init();
    sb.centre = "0:editor";
    sb.right = "";
    var rendered = try sb.render(testing.allocator, &ctx, 80);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 80), visibleLen(rendered.line));
    try testing.expect(std.mem.indexOf(u8, rendered.line, "[dev]") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.line, "0:editor") != null);
}

test "render right aligned" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "s");

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "";
    sb.right = "RIGHT";
    sb.right_length = 40;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), visibleLen(rendered.line));
    try testing.expect(std.mem.endsWith(u8, rendered.line, "RIGHT"));
}

test "render centre justified" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "MID";
    sb.right = "";
    sb.justify = .centre;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), visibleLen(rendered.line));
    const mid_start = std.mem.indexOf(u8, rendered.line, "MID").?;
    try testing.expect(mid_start >= 7 and mid_start <= 9);
}

test "render truncates when too wide" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "very-long-session-name");

    var sb = StatusBar.init();
    sb.left_length = 10;
    sb.centre = "";
    sb.right = "";
    var rendered = try sb.render(testing.allocator, &ctx, 10);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 10), visibleLen(rendered.line));
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

    try testing.expectEqual(@as(usize, 40), visibleLen(rendered.line));
    for (rendered.line) |c| {
        try testing.expectEqual(@as(u8, ' '), c);
    }
}

test "render with conditional" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("window_index", "1");
    try ctx.set("window_name", "shell");
    try ctx.set("window_active", "1");

    var sb = StatusBar.init();
    sb.left = "";
    sb.right = "";
    // centre is pre-expanded in production; expand here for the test
    const centre = try expand(testing.allocator, "#{window_index}:#{window_name}#{?window_active,*,}", &ctx);
    defer testing.allocator.free(centre);
    sb.centre = centre;
    var rendered = try sb.render(testing.allocator, &ctx, 40);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.line, "1:shell*") != null);
}

test "render left justify" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "LEFT";
    sb.right = "";
    sb.justify = .left;
    var rendered = try sb.render(testing.allocator, &ctx, 20);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, rendered.line, "LEFT"));
}

test "render right justify" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var sb = StatusBar.init();
    sb.left = "";
    sb.centre = "RIGHT";
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

    const sb = StatusBar.init();
    var rendered = try sb.render(testing.allocator, &ctx, 1);
    defer rendered.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), visibleLen(rendered.line));
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

    var sb = StatusBar.init();
    sb.left = "###{session_name}";
    sb.left_length = 40;
    sb.centre = "";
    sb.right = "";
    var rendered = try sb.render(testing.allocator, &ctx, 40);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, rendered.line, "#test"));
}

test "visibleLen skips CSI" {
    try testing.expectEqual(@as(usize, 3), visibleLen("\x1b[31mabc\x1b[m"));
}

test "truncateVisible keeps styles" {
    const s = "\x1b[31mabcdef\x1b[m";
    const t = try truncateVisible(testing.allocator, s, 3);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 3), visibleLen(t));
    try testing.expect(std.mem.indexOf(u8, t, "\x1b[31m") != null);
}

test "windowRanges reports exact columns for each window entry — bug #290" {
    const windows = [_]WindowInfo{
        .{ .index = 0, .name = "one", .flags = "", .is_active = false },
        .{ .index = 1, .name = "two", .flags = "", .is_active = true },
    };
    const ranges = try windowRanges(testing.allocator, .{
        .session_name = "s",
        .windows = &windows,
        .left = "",
        .right = "",
        .left_length = 0,
        .right_length = 0,
        .width = 40,
    });
    defer testing.allocator.free(ranges);

    // Default formats "#I:#W#{?window_flags,...}" render as "0:one1:two".
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual(@as(u32, 0), ranges[0].pos);
    try testing.expectEqual(@as(u32, 0), ranges[0].start_col);
    try testing.expectEqual(@as(u32, 5), ranges[0].end_col); // "0:one"
    try testing.expectEqual(@as(u32, 1), ranges[1].pos);
    try testing.expectEqual(@as(u32, 5), ranges[1].start_col);
    try testing.expectEqual(@as(u32, 10), ranges[1].end_col); // "1:two"
}

test "windowRanges honours left prefix and justify — bug #290" {
    const windows = [_]WindowInfo{
        .{ .index = 0, .name = "win", .flags = "", .is_active = false },
    };
    // Left template "[s] " -> 4 cols, then entry "0:win".
    const ranges = try windowRanges(testing.allocator, .{
        .session_name = "s",
        .windows = &windows,
        .left = "[#{session_name}] ",
        .right = "",
        .left_length = 10,
        .right_length = 0,
        .width = 40,
    });
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(u32, 0), ranges[0].pos);
    try testing.expectEqual(@as(u32, 4), ranges[0].start_col);
    try testing.expectEqual(@as(u32, 9), ranges[0].end_col); // "0:win"
}

test "windowRanges truncates centre to available width — bug #290" {
    const windows = [_]WindowInfo{
        .{ .index = 0, .name = "first", .flags = "", .is_active = false },
        .{ .index = 1, .name = "second", .flags = "", .is_active = false },
    };
    // Width 8: left+right empty, so centre gets 8 cols. First entry "0:first"
    // (7 cols) fits; the second entry's first column ("1:second") is cut to
    // exactly the remaining 1 column.
    const ranges = try windowRanges(testing.allocator, .{
        .session_name = "s",
        .windows = &windows,
        .left = "",
        .right = "",
        .left_length = 0,
        .right_length = 0,
        .width = 8,
    });
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual(@as(u32, 0), ranges[0].pos);
    try testing.expectEqual(@as(u32, 0), ranges[0].start_col);
    try testing.expectEqual(@as(u32, 7), ranges[0].end_col);
    try testing.expectEqual(@as(u32, 1), ranges[1].pos);
    try testing.expectEqual(@as(u32, 7), ranges[1].start_col);
    try testing.expectEqual(@as(u32, 8), ranges[1].end_col);
}
