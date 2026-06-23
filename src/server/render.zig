const std = @import("std");
const c = std.c;
const testing = std.testing;
const Screen = @import("../screen.zig").Screen;
const Cell = @import("../grid.zig").Cell;
const Colour = @import("../colour.zig").Colour;
const Attr = @import("../grid.zig").Attr;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const tty = @import("../tty/tty.zig");

pub const PaneBounds = struct {
    pane: *Pane,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Error = tty.Error || error{OutOfMemory};

pub const Display = struct {
    fd: i32,
    sx: u32,
    sy: u32,
    capture: ?*std.ArrayList(u8) = null,
    capture_allocator: ?std.mem.Allocator = null,

    fn writeBytes(self: Display, bytes: []const u8) Error!void {
        if (self.capture) |cap| {
            try cap.appendSlice(self.capture_allocator.?, bytes);
        } else {
            if (c.write(self.fd, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
        }
    }

    fn writeString(self: Display, str: []const u8) Error!void {
        try self.writeBytes(str);
    }

    fn writeStr(self2: Display, str: [*:0]const u8) Error!void {
        const len = std.mem.len(str);
        try self2.writeBytes(str[0..len]);
    }

    pub fn enterAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[?1049h");
        try self.writeBytes("\x1b[?1000h\x1b[?1006h");
        try self.writeBytes("\x1b[?25l");
    }

    pub fn exitAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[?1000l\x1b[?1006l");
        try self.writeBytes("\x1b[?25h");
        try self.writeBytes("\x1b[?1049l");
    }

    pub fn renderAll(
        self: Display,
        allocator: std.mem.Allocator,
        bounds: []const PaneBounds,
        active_pane: *Pane,
        session_name: []const u8,
        windows: []const *Window,
        active_window: ?*Window,
        layout_root: *const @import("../layout.zig").Node,
    ) Error!void {
        try self.writeBytes("\x1b[?25l");

        const merged_w = self.sx;
        const merged_h = self.sy - 1;

        var merged_screen = try Screen.init(allocator, merged_w, merged_h);
        defer merged_screen.deinit();

        for (merged_screen.grid.lines.items) |*line| {
            try line.cells.resize(allocator, merged_w);
            @memset(line.cells.items, Cell.empty());
        }

        for (bounds) |pb| {
            const pane_grid = &pb.pane.screen.grid;
            for (0..pb.h) |y| {
                if (pb.y + y >= merged_h) break;

                const combined_idx = (@as(isize, @intCast(pane_grid.history.items.len)) - @as(isize, @intCast(if (pb.pane.screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));
                const cells = if (combined_idx < 0)
                    @as(?*const std.ArrayListUnmanaged(Cell), null)
                else if (combined_idx < pane_grid.history.items.len)
                    &pane_grid.history.items[@intCast(combined_idx)].cells
                else blk: {
                    const visible_y = combined_idx - @as(isize, @intCast(pane_grid.history.items.len));
                    break :blk if (visible_y < pane_grid.height)
                        &pane_grid.getLine(@intCast(visible_y)).cells
                    else
                        @as(?*const std.ArrayListUnmanaged(Cell), null);
                };

                for (0..pb.w) |x| {
                    if (pb.x + x >= merged_w) break;
                    var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                    if (pb.pane.screen.copy_mode) |cm| {
                        if (cm.isSelected(@intCast(x), @intCast(y))) {
                            cell.attr.reverse = !cell.attr.reverse;
                        }
                    }
                    merged_screen.grid.getLineMut(@intCast(pb.y + y)).cells.items[pb.x + x] = cell;
                }
            }
        }

        try drawLayoutBorders(layout_root, 0, 0, merged_w, merged_h, &merged_screen, active_pane, bounds);

        var active_bounds: ?PaneBounds = null;
        for (bounds) |pb| {
            if (pb.pane == active_pane) {
                active_bounds = pb;
                break;
            }
        }

        if (active_bounds) |ab| {
            const cursor_visible = active_pane.screen.mode.cursor;
            merged_screen.cursor.visible = cursor_visible;
            if (cursor_visible) {
                const pane_cx = if (active_pane.screen.copy_mode) |cm| cm.cursor_x else active_pane.screen.cursor.x;
                const pane_cy = if (active_pane.screen.copy_mode) |cm| cm.cursor_y else active_pane.screen.cursor.y;
                merged_screen.cursor.x = ab.x + pane_cx;
                merged_screen.cursor.y = ab.y + pane_cy;
            }
        } else {
            merged_screen.cursor.visible = false;
        }

        try self.renderContent(&merged_screen);
        try self.renderStatusBar(session_name, windows, active_window);

        if (merged_screen.cursor.visible) {
            try self.moveTo(merged_screen.cursor.x, merged_screen.cursor.y);
            try self.writeBytes("\x1b[?25h");
        }
    }

    fn drawLayoutBorders(
        node: *const @import("../layout.zig").Node,
        lx: u32,
        ly: u32,
        lw: u32,
        lh: u32,
        merged_screen: *Screen,
        active_pane: *Pane,
        bounds: []const PaneBounds,
    ) !void {
        switch (node.*) {
            .leaf => {},
            .split => |s| {
                if (s.direction == .horizontal) {
                    const split_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lw)) * s.proportion)));
                    if (split_w > 0 and lx + split_w - 1 < merged_screen.grid.width) {
                        const border_x = lx + split_w - 1;
                        const is_active_border = isBorderActive(border_x, ly, lh, true, active_pane, bounds);
                        const border_fg = if (is_active_border) Colour.fromIndexed(2) else Colour.fromIndexed(8);

                        var y: u32 = ly;
                        while (y < ly + lh) : (y += 1) {
                            if (y >= merged_screen.grid.height) break;
                            var cell = &merged_screen.grid.getLineMut(y).cells.items[border_x];
                            if (cell.char == 0x2500) {
                                cell.char = 0x253C; // '┼'
                            } else {
                                cell.char = 0x2502; // '│'
                            }
                            cell.fg = border_fg;
                        }
                    }
                    try drawLayoutBorders(s.a, lx, ly, split_w -| 1, lh, merged_screen, active_pane, bounds);
                    try drawLayoutBorders(s.b, lx + split_w, ly, lw -| split_w, lh, merged_screen, active_pane, bounds);
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    if (split_h > 0 and ly + split_h - 1 < merged_screen.grid.height) {
                        const border_y = ly + split_h - 1;
                        const is_active_border = isBorderActive(lx, border_y, lw, false, active_pane, bounds);
                        const border_fg = if (is_active_border) Colour.fromIndexed(2) else Colour.fromIndexed(8);

                        var x: u32 = lx;
                        while (x < lx + lw) : (x += 1) {
                            if (x >= merged_screen.grid.width) break;
                            var cell = &merged_screen.grid.getLineMut(border_y).cells.items[x];
                            if (cell.char == 0x2502) {
                                cell.char = 0x253C; // '┼'
                            } else {
                                cell.char = 0x2500; // '─'
                            }
                            cell.fg = border_fg;
                        }
                    }
                    try drawLayoutBorders(s.a, lx, ly, lw, split_h -| 1, merged_screen, active_pane, bounds);
                    try drawLayoutBorders(s.b, lx, ly + split_h, lw, lh -| split_h, merged_screen, active_pane, bounds);
                }
            },
        }
    }

    fn isBorderActive(bx: u32, by: u32, blen: u32, is_vertical: bool, active_pane: *Pane, bounds: []const PaneBounds) bool {
        var active_bound: ?PaneBounds = null;
        for (bounds) |pb| {
            if (pb.pane == active_pane) {
                active_bound = pb;
                break;
            }
        }
        const ab = active_bound orelse return false;

        if (is_vertical) {
            const adj = (ab.x + ab.w == bx) or (ab.x == bx + 1);
            const overlap = (ab.y < by + blen) and (ab.y + ab.h > by);
            return adj and overlap;
        } else {
            const adj = (ab.y + ab.h == by) or (ab.y == by + 1);
            const overlap = (ab.x < bx + blen) and (ab.x + ab.w > bx);
            return adj and overlap;
        }
    }

    fn renderContent(self: Display, screen: *Screen) Error!void {
        const h = @min(screen.grid.height, self.sy - 1);
        const w = @min(screen.grid.width, self.sx);

        var active_fg = Colour.default_();
        var active_bg = Colour.default_();
        var active_attr = Attr{};

        try self.writeBytes("\x1b[m");

        for (0..h) |y| {
            const combined_idx = (@as(isize, @intCast(screen.grid.history.items.len)) - @as(isize, @intCast(if (screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));
            const cells = if (combined_idx < 0)
                @as(?*const std.ArrayListUnmanaged(Cell), null)
            else if (combined_idx < screen.grid.history.items.len)
                &screen.grid.history.items[@intCast(combined_idx)].cells
            else blk: {
                const visible_y = combined_idx - @as(isize, @intCast(screen.grid.history.items.len));
                break :blk if (visible_y < screen.grid.height)
                    &screen.grid.getLine(@intCast(visible_y)).cells
                else
                    @as(?*const std.ArrayListUnmanaged(Cell), null);
            };

            try self.moveTo(0, @intCast(y));
            for (0..w) |x| {
                var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                if (screen.copy_mode) |cm| {
                    if (cm.isSelected(@intCast(x), @intCast(y))) {
                        cell.attr.reverse = !cell.attr.reverse;
                    }
                }

                if (@as(u32, @bitCast(cell.fg)) != @as(u32, @bitCast(active_fg)) or
                    @as(u32, @bitCast(cell.bg)) != @as(u32, @bitCast(active_bg)) or
                    @as(u16, @bitCast(cell.attr)) != @as(u16, @bitCast(active_attr)))
                {
                    active_fg = cell.fg;
                    active_bg = cell.bg;
                    active_attr = cell.attr;

                    var sgr_buf: [128]u8 = undefined;
                    var sgr_pos: usize = 0;

                    sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[m", .{}) catch unreachable).len;

                    const attrFields = comptime blk: {
                        const all = std.meta.fields(Attr);
                        break :blk all[0 .. all.len - 1];
                    };
                    const attrCodes = [_][]const u8{
                        "1",   // bold
                        "2",   // dim
                        "3",   // italic
                        "4",   // underline
                        "5",   // blink
                        "7",   // reverse
                        "8",   // concealed
                        "9",   // strikethrough
                        "53",  // overline
                        "4:2", // double_underline
                        "4:3", // curly_underline
                    };

                    inline for (attrFields, 0..) |field, idx| {
                        if (@field(active_attr, field.name)) {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[{s}m", .{attrCodes[idx]}) catch unreachable).len;
                        }
                    }

                    switch (active_fg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;5;{}m", .{@as(u8, @truncate(active_fg.value))}) catch unreachable).len;
                        },
                        .rgb => {
                            const rgb = active_fg.toRgb().?;
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable).len;
                        },
                    }

                    switch (active_bg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;5;{}m", .{@as(u8, @truncate(active_bg.value))}) catch unreachable).len;
                        },
                        .rgb => {
                            const rgb = active_bg.toRgb().?;
                            sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable).len;
                        },
                    }

                    try self.writeBytes(sgr_buf[0..sgr_pos]);
                }

                const cp = cell.char;
                if (cp == 0 or cp == ' ') {
                    try self.writeBytes(" ");
                } else if (cp >= 0x20 and cp != 0x7F) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                        try self.writeBytes("?");
                        continue;
                    };
                    try self.writeBytes(buf[0..len]);
                } else {
                    try self.writeBytes("?");
                }
            }
        }

        try self.writeBytes("\x1b[m");
    }

    fn renderStatusBar(self: Display, session_name: []const u8, windows: []const *Window, active_window: ?*Window) Error!void {
        try self.moveTo(0, self.sy - 1);
        try self.writeBytes("\x1b[7m");

        var col: u32 = 0;

        try self.writeBytes(" [");
        try self.writeBytes(session_name);
        try self.writeBytes("]");
        col += 3 + @as(u32, @intCast(session_name.len));

        for (windows, 0..) |win, idx| {
            const is_active = (win == active_window);
            const suffix = if (is_active) "*" else "";

            if (is_active) {
                try self.writeBytes("\x1b[4m");
            }

            var win_idx_buf: [32]u8 = undefined;
            const win_idx_str = std.fmt.bufPrint(&win_idx_buf, " {d}:", .{idx}) catch " win:";
            try self.writeBytes(win_idx_str);
            col += @intCast(win_idx_str.len);

            try self.writeBytes(win.name);
            col += @intCast(win.name.len);

            if (suffix.len > 0) {
                try self.writeBytes(suffix);
                col += @intCast(suffix.len);
            }

            if (is_active) {
                try self.writeBytes("\x1b[24m");
            }
        }

        const max_len = self.sx -| 1;
        while (col < max_len) : (col += 1) {
            try self.writeBytes(" ");
        }

        try self.writeBytes("\x1b[m");
    }

    fn moveTo(self: Display, x: u32, y: u32) Error!void {
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch unreachable;
        try self.writeBytes(seq);
    }
};

test "renderContent double and curly underline" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 2);
    defer screen.deinit();

    // Set first cell to double underline, second to curly underline
    screen.grid.setCell(0, 0, Cell.withChar('A'));
    var cell_a = screen.grid.getCell(0, 0);
    cell_a.attr.double_underline = true;
    screen.grid.setCell(0, 0, cell_a);

    screen.grid.setCell(1, 0, Cell.withChar('B'));
    var cell_b = screen.grid.getCell(1, 0);
    cell_b.attr.curly_underline = true;
    screen.grid.setCell(1, 0, cell_b);

    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(allocator);

    const display = Display{
        .fd = -1,
        .sx = 10,
        .sy = 2,
        .capture = &capture_buf,
        .capture_allocator = allocator,
    };

    try display.renderContent(&screen);

    // Verify SGR escape sequences are in the output
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[4:2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[4:3m") != null);
}

test "renderStatusBar with long window name" {
    const allocator = std.testing.allocator;
    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(allocator);

    const display = Display{
        .fd = -1,
        .sx = 200,
        .sy = 24,
        .capture = &capture_buf,
        .capture_allocator = allocator,
    };

    var win1 = try Window.init(allocator, 1, "very_long_window_name_that_previously_would_have_failed_bufprint_because_it_exceeds_the_stack_buffer_limit_and_caused_overflow_or_fallback_to_win", 80, 24, null);
    defer win1.deinit(allocator);

    const windows = [_]*Window{&win1};

    try display.renderStatusBar("my-session", &windows, &win1);

    // Verify it renders the long window name successfully
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "very_long_window_name_that_previously_would_have_failed") != null);
}

test "renderAll cursor visibility hide" {
    const allocator = std.testing.allocator;
    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(allocator);

    const display = Display{
        .fd = -1,
        .sx = 80,
        .sy = 24,
        .capture = &capture_buf,
        .capture_allocator = allocator,
    };

    var win = try Window.init(allocator, 1, "test-win", 80, 23, null);
    defer win.deinit(allocator);

    const pane = win.active_pane.?;
    pane.screen.mode.cursor = false; // Hide cursor

    const bounds = [_]PaneBounds{.{
        .pane = pane,
        .x = 0,
        .y = 0,
        .w = 80,
        .h = 23,
    }};

    const windows = [_]*Window{&win};
    
    const Node = @import("../layout.zig").Node;
    const node = Node{ .leaf = pane };

    try display.renderAll(allocator, &bounds, pane, "my-session", &windows, &win, &node);

    // Verify the cursor was NOT shown at the end
    const has_show_cursor = std.mem.indexOf(u8, capture_buf.items, "\x1b[?25h") != null;
    try std.testing.expect(!has_show_cursor);
}



