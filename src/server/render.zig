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
const char_width = @import("../char_width.zig");

pub const PaneBounds = struct {
    pane: *Pane,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Error = tty.Error || error{OutOfMemory};

pub const ThemeColours = struct {
    status_fg: Colour,
    status_bg: Colour,
    pane_border_fg: Colour,
    pane_active_border_fg: Colour,
};

pub const Display = struct {
    fd: i32,
    sx: u32,
    sy: u32,
    capture: ?*std.ArrayList(u8) = null,
    capture_allocator: ?std.mem.Allocator = null,

    fn writeColourFg(self: Display, color: Colour) Error!void {
        switch (color.tag) {
            .default_, .terminal => {},
            .indexed => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{@as(u8, @truncate(color.value))}) catch return;
                try self.writeBytes(s);
            },
            .rgb => {
                const rgb = color.toRgb().?;
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch return;
                try self.writeBytes(s);
            },
        }
    }

    fn writeColourBg(self: Display, color: Colour) Error!void {
        switch (color.tag) {
            .default_, .terminal => {},
            .indexed => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[48;5;{}m", .{@as(u8, @truncate(color.value))}) catch return;
                try self.writeBytes(s);
            },
            .rgb => {
                const rgb = color.toRgb().?;
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch return;
                try self.writeBytes(s);
            },
        }
    }

    fn writeBytes(self: Display, bytes: []const u8) Error!void {
        if (self.capture) |cap| {
            try cap.appendSlice(self.capture_allocator.?, bytes);
        } else {
            var off: usize = 0;
            while (off < bytes.len) {
                const n = c.write(self.fd, bytes.ptr + off, bytes.len - off);
                if (n < 0) {
                    if (std.c.errno(n) == .INTR) continue;
                    return error.WriteFailed;
                }
                if (n == 0) return error.WriteFailed;
                off += @as(usize, @intCast(n));
            }
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
        try self.writeBytes("\x1b[>1u");
        try self.writeBytes("\x1b[?1000h\x1b[?1006h");
        try self.writeBytes("\x1b[?25l");
    }

    pub fn exitAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[<1u");
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
        theme: ThemeColours,
        message: ?[]const u8,
        command_mode: bool,
        command_buf: []const u8,
        pane_in_copy_mode: bool,
    ) Error!void {
        try self.writeBytes("\x1b[?25l");
        try self.writeBytes("\x1b[?2026h");

        const merged_w = self.sx;
        const merged_h = self.sy -| 1;

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

        const mode_border_fg = if (pane_in_copy_mode) Colour.fromIndexed(11) else theme.pane_active_border_fg;
        try drawLayoutBorders(layout_root, 0, 0, merged_w, merged_h, &merged_screen, active_pane, bounds, theme.pane_border_fg, mode_border_fg);

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
        try self.renderSixelImages(bounds);
        try self.renderStatusBar(session_name, windows, active_window, theme.status_fg, theme.status_bg, message, command_mode, command_buf, pane_in_copy_mode);

        if (merged_screen.cursor.visible) {
            try self.moveTo(merged_screen.cursor.x, merged_screen.cursor.y);
            try self.writeBytes("\x1b[?25h");
        }
        try self.writeBytes("\x1b[?2026l");
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
        border_fg: Colour,
        active_border_fg: Colour,
    ) !void {
        switch (node.*) {
            .leaf => {},
            .split => |s| {
                if (s.direction == .horizontal) {
                    const split_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lw)) * s.proportion)));
                    if (split_w > 0 and lx + split_w - 1 < merged_screen.grid.width) {
                        const border_x = lx + split_w - 1;

                        var y: u32 = ly;
                        while (y < ly + lh) : (y += 1) {
                            if (y >= merged_screen.grid.height) break;
                            const is_active = isBorderActiveAt(border_x, y, true, active_pane, bounds);
                            const border_col = if (is_active) active_border_fg else border_fg;
                            var cell = &merged_screen.grid.getLineMut(y).cells.items[border_x];
                            if (cell.char == 0x2500) {
                                cell.char = 0x253C; // '┼'
                            } else {
                                cell.char = 0x2502; // '│'
                            }
                            cell.fg = border_col;
                        }
                    }
                    try drawLayoutBorders(s.a, lx, ly, split_w -| 1, lh, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                    try drawLayoutBorders(s.b, lx + split_w, ly, lw -| split_w, lh, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                } else {
                    const split_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(lh)) * s.proportion)));
                    if (split_h > 0 and ly + split_h - 1 < merged_screen.grid.height) {
                        const border_y = ly + split_h - 1;

                        var x: u32 = lx;
                        while (x < lx + lw) : (x += 1) {
                            if (x >= merged_screen.grid.width) break;
                            const is_active = isBorderActiveAt(x, border_y, false, active_pane, bounds);
                            const border_col = if (is_active) active_border_fg else border_fg;
                            var cell = &merged_screen.grid.getLineMut(border_y).cells.items[x];
                            if (cell.char == 0x2502) {
                                cell.char = 0x253C; // '┼'
                            } else {
                                cell.char = 0x2500; // '─'
                            }
                            cell.fg = border_col;
                        }
                    }
                    try drawLayoutBorders(s.a, lx, ly, lw, split_h -| 1, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                    try drawLayoutBorders(s.b, lx, ly + split_h, lw, lh -| split_h, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                }
            },
        }
    }

    fn isBorderActiveAt(bx: u32, by: u32, is_vertical: bool, active_pane: *Pane, bounds: []const PaneBounds) bool {
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
            const overlap = by >= ab.y and by < ab.y + ab.h;
            return adj and overlap;
        } else {
            const adj = (ab.y + ab.h == by) or (ab.y == by + 1);
            const overlap = bx >= ab.x and bx < ab.x + ab.w;
            return adj and overlap;
        }
    }

    fn renderContent(self: Display, screen: *Screen) Error!void {
        const h = @min(screen.grid.height, self.sy -| 1);
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

            // Track the terminal cursor column within this row.
            // We start at column 0 via an absolute move, then advance cur_cx as
            // we write characters.  Before writing any non-padding cell we check
            // that the tracked position matches the grid column; if it has drifted
            // (e.g. after a wide-char encoding fallback) we re-anchor with a fresh
            // absolute moveTo.
            try self.moveTo(0, @intCast(y));
            var cur_cx: u32 = 0;

            for (0..w) |x| {
                var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                if (screen.copy_mode) |cm| {
                    if (cm.isSelected(@intCast(x), @intCast(y))) {
                        cell.attr.reverse = !cell.attr.reverse;
                    }
                }

                if (cell.is_padding) continue;

                // Re-anchor cursor if we have drifted from the expected column.
                if (cur_cx != @as(u32, @intCast(x))) {
                    try self.moveTo(@intCast(x), @intCast(y));
                    cur_cx = @intCast(x);
                }

                if (@as(u32, @bitCast(cell.fg)) != @as(u32, @bitCast(active_fg)) or
                    @as(u32, @bitCast(cell.bg)) != @as(u32, @bitCast(active_bg)) or
                    @as(u16, @bitCast(cell.attr)) != @as(u16, @bitCast(active_attr)))
                {
                    active_fg = cell.fg;
                    active_bg = cell.bg;
                    active_attr = cell.attr;

                    var sgr_buf: [256]u8 = undefined;
                    var sgr_pos: usize = 0;

                    if (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[m", .{})) |reset_str| {
                        sgr_pos += reset_str.len;
                    } else |_| {}

                    const attrFields = comptime blk: {
                        const all = std.meta.fields(Attr);
                        break :blk all[0 .. all.len - 1];
                    };
                    const attrCodes = [_][]const u8{
                        "1", // bold
                        "2", // dim
                        "3", // italic
                        "4", // underline
                        "5", // blink
                        "7", // reverse
                        "8", // concealed
                        "9", // strikethrough
                        "53", // overline
                        "4:2", // double_underline
                        "4:3", // curly_underline
                    };

                    inline for (attrFields, 0..) |field, idx| {
                        if (@field(active_attr, field.name)) {
                            const written = std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[{s}m", .{attrCodes[idx]}) catch break;
                            sgr_pos += written.len;
                        }
                    }

                    switch (active_fg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            if (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;5;{}m", .{@as(u8, @truncate(active_fg.value))})) |printed| {
                                sgr_pos += printed.len;
                            } else |_| {}
                        },
                        .rgb => {
                            const rgb = active_fg.toRgb().?;
                            if (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] })) |printed| {
                                sgr_pos += printed.len;
                            } else |_| {}
                        },
                    }

                    switch (active_bg.tag) {
                        .default_, .terminal => {},
                        .indexed => {
                            if (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;5;{}m", .{@as(u8, @truncate(active_bg.value))})) |printed| {
                                sgr_pos += printed.len;
                            } else |_| {}
                        },
                        .rgb => {
                            const rgb = active_bg.toRgb().?;
                            if (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] })) |printed| {
                                sgr_pos += printed.len;
                            } else |_| {}
                        },
                    }

                    try self.writeBytes(sgr_buf[0..sgr_pos]);
                }

                const cp = cell.char;
                if (cp == 0 or cp == ' ') {
                    try self.writeBytes(" ");
                    cur_cx += 1;
                } else if (cp >= 0x20 and cp != 0x7F) {
                    var buf: [4]u8 = undefined;
                    const cw = char_width.charWidth(@intCast(cp));
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                        try self.writeBytes("?");
                        cur_cx += 1;
                        continue;
                    };
                    try self.writeBytes(buf[0..len]);
                    cur_cx += if (cw > 0) @as(u32, cw) else 1;

                    if (cell.comb1 != 0) {
                        const ccp1 = char_width.combiningCodepoint(cell.comb1);
                        if (ccp1 != 0) {
                            const clen = std.unicode.utf8Encode(ccp1, &buf) catch continue;
                            try self.writeBytes(buf[0..clen]);
                        }
                    }
                    if (cell.comb2 != 0) {
                        const ccp2 = char_width.combiningCodepoint(cell.comb2);
                        if (ccp2 != 0) {
                            const clen = std.unicode.utf8Encode(ccp2, &buf) catch continue;
                            try self.writeBytes(buf[0..clen]);
                        }
                    }
                } else {
                    try self.writeBytes("?");
                    cur_cx += 1;
                }
            }
        }

        try self.writeBytes("\x1b[m");
    }

    fn renderStatusBar(self: Display, session_name: []const u8, windows: []const *Window, active_window: ?*Window, fg: Colour, bg: Colour, message: ?[]const u8, command_mode: bool, command_buf: []const u8, in_copy_mode: bool) Error!void {
        try self.moveTo(0, self.sy -| 1);

        try self.writeColourFg(if (in_copy_mode) Colour.fromIndexed(0) else fg);
        try self.writeColourBg(if (in_copy_mode) Colour.fromIndexed(11) else bg);

        var col: u32 = 0;

        if (in_copy_mode and !command_mode and message == null) {
            const indicator = "[copy-mode] ";
            try self.writeBytes(indicator);
            col +|= @as(u32, @intCast(indicator.len));
        }

        if (command_mode) {
            const prompt = ":: ";
            try self.writeBytes(prompt);
            col += prompt.len;
            const max_len = self.sx -| 1;
            const display_len = @min(command_buf.len, max_len -| col);
            if (display_len > 0) {
                try self.writeBytes(command_buf[0..display_len]);
                col += display_len;
            }
        } else if (message) |msg| {
            const max_len = self.sx -| 1;
            const display_len = @min(msg.len, max_len);
            try self.writeBytes(msg[0..display_len]);
            col = display_len;
        } else {
            try self.writeBytes(" [");
            try self.writeBytes(session_name);
            try self.writeBytes("]");
            col +|= 3 + @as(u32, @intCast(session_name.len));

            for (windows, 0..) |win, idx| {
                const is_active = (win == active_window);
                const suffix = if (is_active) "*" else "";

                if (is_active) {
                    try self.writeBytes("\x1b[4m");
                }

                var win_idx_buf: [32]u8 = undefined;
                const win_idx_str = std.fmt.bufPrint(&win_idx_buf, " {d}:", .{idx}) catch " win:";
                try self.writeBytes(win_idx_str);
                col +|= @intCast(win_idx_str.len);

                const remaining = (self.sx -| 1) -| col;
                const suffix_len: u32 = if (is_active) 1 else 0;
                const name_len = @min(win.name.len, remaining -| suffix_len);
                try self.writeBytes(win.name[0..name_len]);
                col +|= name_len;

                if (suffix.len > 0) {
                    try self.writeBytes(suffix);
                    col +|= @intCast(suffix.len);
                }

                if (is_active) {
                    try self.writeBytes("\x1b[24m");
                }
            }
        }

        const max_len = self.sx -| 1;
        while (col < max_len) : (col += 1) {
            try self.writeBytes(" ");
        }

        try self.writeBytes("\x1b[m");
    }

    fn moveTo(self: Display, x: u32, y: u32) Error!void {
        var buf: [64]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch {
            std.log.warn("CUP overflow: x={d}, y={d}", .{ x, y });
            return error.OutOfMemory;
        };
        try self.writeBytes(seq);
    }

    /// Re-emit sixel images from all panes at their absolute screen positions.
    /// Each pane contributes zero or more SixelImage entries stored in its
    /// Screen. We move the cursor to the image anchor, emit the raw DCS bytes,
    /// then reset SGR so subsequent character rendering is unaffected.
    fn renderSixelImages(self: Display, bounds: []const PaneBounds) Error!void {
        for (bounds) |pb| {
            for (pb.pane.screen.sixel_images.items) |img| {
                // Translate pane-local row/col to display-absolute row/col.
                const abs_col = pb.x + img.col;
                const abs_row = pb.y + img.row;
                // Skip images that would be outside the display area.
                if (abs_row >= self.sy -| 1 or abs_col >= self.sx) continue;
                try self.moveTo(abs_col, abs_row);
                // Emit the raw DCS bytes verbatim. The outer terminal renders pixels.
                try self.writeBytes(img.data);
                // Reset SGR after the DCS sequence so subsequent text is clean.
                try self.writeBytes("\x1b[m");
            }
        }
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

test "renderContent all attributes + RGB colours — no SGR buffer overflow — bug #164" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 1);
    defer screen.deinit();

    screen.grid.setCell(0, 0, Cell.withChar('A'));
    var cell = screen.grid.getCell(0, 0);
    cell.fg = Colour.fromRgb(255, 128, 0);
    cell.bg = Colour.fromRgb(0, 128, 255);
    cell.attr.bold = true;
    cell.attr.dim = true;
    cell.attr.italic = true;
    cell.attr.underline = true;
    cell.attr.blink = true;
    cell.attr.reverse = true;
    cell.attr.concealed = true;
    cell.attr.strikethrough = true;
    cell.attr.overline = true;
    cell.attr.double_underline = true;
    cell.attr.curly_underline = true;
    screen.grid.setCell(0, 0, cell);

    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(allocator);

    const display = Display{
        .fd = -1,
        .sx = 5,
        .sy = 2,
        .capture = &capture_buf,
        .capture_allocator = allocator,
    };

    try display.renderContent(&screen);

    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[38;2;255;128;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[48;2;0;128;255m") != null);
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

    try display.renderStatusBar("my-session", &windows, &win1, Colour.default_(), Colour.default_(), null, false, "", false);

    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "very_long_window_name_that_previously_would_have_failed") != null);
}

test "renderStatusBar truncates long name to fit terminal width — bug #185" {
    const allocator = std.testing.allocator;
    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(allocator);

    const display = Display{
        .fd = -1,
        .sx = 30,
        .sy = 24,
        .capture = &capture_buf,
        .capture_allocator = allocator,
    };

    var win1 = try Window.init(allocator, 1, "abcdefghijklmnopqrstuvwxyz0123456789", 80, 24, null);
    defer win1.deinit(allocator);

    const windows = [_]*Window{&win1};

    try display.renderStatusBar("ses", &windows, &win1, Colour.default_(), Colour.default_(), null, false, "", false);

    // Status bar should be exactly sx - 1 = 29 visible chars plus ESC sequences.
    // The long name must be truncated so the total emitted content does not
    // exceed 29 visible columns.
    const max_visible: usize = display.sx - 1;
    var visible_cols: u32 = 0;
    var in_esc = false;
    for (capture_buf.items) |ch| {
        if (ch == 0x1b) { in_esc = true; continue; }
        if (in_esc) { if (ch == 'm' or ch == 'H') in_esc = false; continue; }
        visible_cols += 1;
    }
    try testing.expect(visible_cols <= max_visible);
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

    try display.renderAll(allocator, &bounds, pane, "my-session", &windows, &win, &node, .{
        .status_fg = Colour.default_(),
        .status_bg = Colour.default_(),
        .pane_border_fg = Colour.fromIndexed(8),
        .pane_active_border_fg = Colour.fromIndexed(2),
    }, null, false, "", false);

    // Verify the cursor was NOT shown at the end
    const has_show_cursor = std.mem.indexOf(u8, capture_buf.items, "\x1b[?25h") != null;
    try std.testing.expect(!has_show_cursor);
}

test "renderSixelImages emits DCS at correct absolute position" {
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

    var win = try Window.init(allocator, 1, "test-sixel", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    // Inject a synthetic sixel image at pane cell (5, 3) with known DCS bytes.
    const raw_dcs = try allocator.dupe(u8, "\x1bPqA\x1b\\");
    const img = @import("../screen.zig").SixelImage{
        .data = raw_dcs,
        .col = 5,
        .row = 3,
        .px_width = 0,
        .px_height = 6,
    };
    try pane.screen.sixel_images.append(allocator, img);

    const bounds = [_]PaneBounds{.{
        .pane = pane,
        .x = 0,
        .y = 0,
        .w = 80,
        .h = 23,
    }};

    try display.renderSixelImages(&bounds);

    // The output must contain the cursor-move to row=4,col=6 (1-indexed) …
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[4;6H") != null);
    // … followed by the raw DCS bytes …
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqA\x1b\\") != null);
    // … and a SGR reset after it.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[m") != null);
}

test "sy saturating subtraction — bug #126" {
    try testing.expectEqual(@as(u32, 0), @as(u32, 0) -| 1);
    try testing.expectEqual(@as(u32, 0), @as(u32, 1) -| 1);
    try testing.expectEqual(@as(u32, 2), @as(u32, 3) -| 1);
}
