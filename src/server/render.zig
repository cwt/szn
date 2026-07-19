const std = @import("std");
const c = std.c;
const testing = std.testing;
const Screen = @import("../screen.zig").Screen;
const SixelAnchor = @import("../screen.zig").SixelAnchor;
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
    last_cells: ?*std.ArrayList(Cell) = null,
    last_sx: ?*u32 = null,
    last_sy: ?*u32 = null,
    merged_screen: ?*?Screen = null,
    last_paste: ?*?bool = null,

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

    pub fn writeBytes(self: Display, bytes: []const u8) Error!void {
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
        try self.writeBytes("\x1b[?1000h\x1b[?1002h\x1b[?1006h");
        try self.writeBytes("\x1b[?25l");
    }

    pub fn exitAltScreen(self: Display) Error!void {
        try self.writeBytes("\x1b[<1u");
        try self.writeBytes("\x1b[?1000l\x1b[?1002l\x1b[?1006l");
        try self.writeBytes("\x1b[?2004l");
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
        search_prefix: u8,
        pane_in_copy_mode: bool,
        full_rebuild: bool,
    ) Error!void {
        try self.writeBytes("\x1b[?25l");
        try self.writeBytes("\x1b[?2026h");

        if (self.last_paste) |lp| {
            const wants_paste = if (command_mode or pane_in_copy_mode or active_pane.choose_mode.active)
                false
            else
                active_pane.screen.mode.paste;
            if (lp.* == null or lp.*.? != wants_paste) {
                if (wants_paste) {
                    try self.writeBytes("\x1b[?2004h");
                } else {
                    try self.writeBytes("\x1b[?2004l");
                }
                lp.* = wants_paste;
            }
        }

        const merged_w = self.sx;
        const merged_h = self.sy -| 1;

        var local_merged_screen: Screen = undefined;
        var merged_screen = &local_merged_screen;

        if (self.merged_screen) |ms_ptr| {
            if (ms_ptr.* == null or ms_ptr.*.?.grid.width != merged_w or ms_ptr.*.?.grid.height != merged_h) {
                if (ms_ptr.*) |*ms| {
                    ms.deinit();
                }
                ms_ptr.* = try Screen.init(allocator, merged_w, merged_h);
            }
            merged_screen = &(ms_ptr.*.?);
        } else {
            local_merged_screen = try Screen.init(allocator, merged_w, merged_h);
        }
        // force_clear must be honoured for ANY pane, not just the active one.
        // A non-active pane that triggers eraseDisplay/resetHard would otherwise
        // lose its flag and never force a full repaint.
        var force_clear_any = active_pane.screen.force_clear;
        for (bounds) |pb| {
            force_clear_any = force_clear_any or pb.pane.screen.force_clear;
            pb.pane.screen.force_clear = false;
        }
        merged_screen.force_clear = force_clear_any;
        defer if (self.merged_screen == null) {
            local_merged_screen.deinit();
        };

        if (full_rebuild) {
            for (merged_screen.grid.lines.items) |*line| {
                @memset(line.cells.items, Cell.empty());
                line.wrapped = false;
                line.dirty = true;
            }
        }

        for (bounds) |pb| {
            if (!full_rebuild and !pb.pane.dirty) continue;
            const pane_grid = &pb.pane.screen.grid;
            const pane_has_sixels = blk: {
                var found = false;
                for (&pb.pane.screen.sixel_images) |opt| {
                    if (opt != null) { found = true; break; }
                }
                break :blk found;
            };
            for (0..pb.h) |y| {
                if (pb.y + y >= merged_h) break;

                const hist_len = pane_grid.history.items.len - pane_grid.history_start;
                const combined_idx = (@as(isize, @intCast(hist_len)) - @as(isize, @intCast(if (pb.pane.screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));
                const cells = if (combined_idx < 0)
                    @as(?*const std.ArrayList(Cell), null)
                else if (combined_idx < hist_len)
                    &pane_grid.history.items[pane_grid.history_start + @as(usize, @intCast(combined_idx))].cells
                else blk: {
                    const visible_y = combined_idx - @as(isize, @intCast(hist_len));
                    break :blk if (visible_y < pane_grid.height)
                        &pane_grid.getLine(@intCast(visible_y)).cells
                    else
                        @as(?*const std.ArrayList(Cell), null);
                };

                for (0..pb.w) |x| {
                    if (pb.x + x >= merged_w) break;
                    var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                    if (pane_has_sixels and cell.attr.sixel) {
                        const image_id = cell.char;
                        if (pb.pane.screen.findSixelImage(image_id)) |img| {
                            const cell_rows = if (img.px_height > 0) (img.px_height + pb.pane.screen.cell_px_height - 1) / pb.pane.screen.cell_px_height else 1;
                            const cell_cols = if (img.px_width > 0) (img.px_width + pb.pane.screen.cell_px_width - 1) / pb.pane.screen.cell_px_width else 1;

                            // Position derived from the image's stored anchor
                            // (bug #200), not per-cell comb offsets.
                            const img_pane_col = @as(i32, @intCast(img.anchor_col));
                            const img_pane_row = @as(i32, @intCast(img.anchor_row));

                            // Mark the cell as sixel only when the image is
                            // *fully contained* in this pane, matching the
                            // rule used by renderSixelImages for the actual
                            // sixel draw. When the two disagree you get
                            // artifacts: either text drawn over the sixel
                            // overlay, or blank cells without sixel — which
                            // appears as a "tail" / ghost on screen (bug #202).
                            const contained_img = img_pane_col >= 0 and
                                img_pane_col + @as(i32, @intCast(cell_cols)) <= @as(i32, @intCast(pb.w)) and
                                img_pane_row >= 0 and
                                img_pane_row + @as(i32, @intCast(cell_rows)) <= @as(i32, @intCast(pb.h));

                            if (!contained_img) {
                                cell.attr.sixel = false;
                                cell.char = 0;
                                cell.comb1 = 0;
                                cell.comb2 = 0;
                            }
                        } else {
                            cell.attr.sixel = false;
                            cell.char = 0;
                            cell.comb1 = 0;
                            cell.comb2 = 0;
                        }
                    }
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
        try drawLayoutBorders(layout_root, 0, 0, merged_w, merged_h, merged_screen, active_pane, bounds, theme.pane_border_fg, mode_border_fg);

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

        try self.renderContent(merged_screen);
        try self.renderSixelImages(bounds);
        try self.renderStatusBar(session_name, windows, active_window, theme.status_fg, theme.status_bg, message, command_mode, command_buf, search_prefix, pane_in_copy_mode);

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
                    const available_w = lw -| 1;
                    const split_w = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_w)) * s.proportion));
                    const w1 = @max(1, split_w);
                    const w2 = @max(1, available_w -| w1);
                    const border_x = lx + w1;

                    if (border_x < merged_screen.grid.width) {
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
                    try drawLayoutBorders(s.a, lx, ly, w1, lh, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                    try drawLayoutBorders(s.b, lx + w1 + 1, ly, w2, lh, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                } else {
                    const available_h = lh -| 1;
                    const split_h = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_h)) * s.proportion));
                    const h1 = @max(1, split_h);
                    const h2 = @max(1, available_h -| h1);
                    const border_y = ly + h1;

                    if (border_y < merged_screen.grid.height) {
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
                    try drawLayoutBorders(s.a, lx, ly, lw, h1, merged_screen, active_pane, bounds, border_fg, active_border_fg);
                    try drawLayoutBorders(s.b, lx, ly + h1 + 1, lw, h2, merged_screen, active_pane, bounds, border_fg, active_border_fg);
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

        if (self.last_cells) |lc| {
            const expected_len = w * h;
            if (self.last_sx.?.* != self.sx or self.last_sy.?.* != self.sy or lc.items.len != expected_len) {
                if (self.capture_allocator) |alloc| {
                    lc.clearRetainingCapacity();
                    lc.resize(alloc, expected_len) catch {};
                    var inv = Cell.empty();
                    inv.char = 0x1FFFFF; // invalid Unicode to force redraw
                    @memset(lc.items, inv);
                }
                self.last_sx.?.* = self.sx;
                self.last_sy.?.* = self.sy;
            }
        }

        if (screen.force_clear) {
            screen.force_clear = false;
            try self.writeBytes("\x1b[2J");
            if (self.last_cells) |lc| {
                var inv = Cell.empty();
                inv.char = 0x1FFFFF; // invalid Unicode to force redraw
                @memset(lc.items, inv);
            }
        }

        var active_fg = Colour.default_();
        var active_bg = Colour.default_();
        var active_attr = Attr{};

        try self.writeBytes("\x1b[m");

        for (0..h) |y| {
            const hist_len = screen.grid.history.items.len - screen.grid.history_start;
            const combined_idx = (@as(isize, @intCast(hist_len)) - @as(isize, @intCast(if (screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));
            const cells = if (combined_idx < 0)
                @as(?*const std.ArrayList(Cell), null)
            else if (combined_idx < hist_len)
                &screen.grid.history.items[screen.grid.history_start + @as(usize, @intCast(combined_idx))].cells
            else blk: {
                const visible_y = combined_idx - @as(isize, @intCast(hist_len));
                break :blk if (visible_y < screen.grid.height)
                    &screen.grid.getLine(@intCast(visible_y)).cells
                else
                    @as(?*const std.ArrayList(Cell), null);
            };

            // Track the terminal cursor column within this row.
            // We start as not anchored and only issue a moveTo when we actually write a changed cell.
            var cur_cx: u32 = 0;
            var anchored = false;

            for (0..w) |x| {
                var cell = if (cells) |cls| (if (x < cls.items.len) cls.items[x] else Cell.empty()) else Cell.empty();
                if (screen.copy_mode) |cm| {
                    if (cm.isSelected(@intCast(x), @intCast(y))) {
                        cell.attr.reverse = !cell.attr.reverse;
                    }
                }

                var force_erase = false;
                if (self.last_cells) |lc| {
                    const cell_idx = y * w + x;
                    if (cell_idx < lc.items.len) {
                        const last_cell = lc.items[cell_idx];
                        if (cell.eql(last_cell)) {
                            anchored = false;
                            continue;
                        }
                        if (last_cell.attr.sixel and !cell.attr.sixel) {
                            force_erase = true;
                        }
                        lc.items[cell_idx] = cell;
                    }
                }

                if (cell.is_padding) continue;

                // Re-anchor cursor if we have drifted from the expected column.
                if (!anchored or cur_cx != @as(u32, @intCast(x))) {
                    try self.moveTo(@intCast(x), @intCast(y));
                    cur_cx = @intCast(x);
                    anchored = true;
                }

                if (force_erase) {
                    try self.writeBytes("\x1b[X");
                }

                var fg_changed = @as(u32, @bitCast(cell.fg)) != @as(u32, @bitCast(active_fg));
                var bg_changed = @as(u32, @bitCast(cell.bg)) != @as(u32, @bitCast(active_bg));
                const attr_changed = @as(u16, @bitCast(cell.attr)) != @as(u16, @bitCast(active_attr));

                if (fg_changed or bg_changed or attr_changed) {
                    var sgr_buf: [256]u8 = undefined;
                    var sgr_pos: usize = 0;

                    if (attr_changed) {
                        sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[m", .{}) catch break).len;

                        const attrFields = comptime blk: {
                            const all = std.meta.fields(Attr);
                            break :blk all[0 .. all.len - 2];
                        };
                        const attrCodes = [_][]const u8{
                            "1",   "2",   "3",   "4",   "5",
                            "7",   "8",   "9",   "53",  "4:2",
                            "4:3",
                        };
                        inline for (attrFields, 0..) |field, idx| {
                            if (@field(cell.attr, field.name)) {
                                sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[{s}m", .{attrCodes[idx]}) catch break).len;
                            }
                        }

                        // `\x1b[m` also resets fg/bg to default, so they must
                        // be re-emitted unconditionally when we reset attrs.
                        fg_changed = true;
                        bg_changed = true;
                    }

                    if (fg_changed) {
                        switch (cell.fg.tag) {
                            .default_, .terminal => {},
                            .indexed => {
                                sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;5;{}m", .{@as(u8, @truncate(cell.fg.value))}) catch break).len;
                            },
                            .rgb => {
                                const rgb = cell.fg.toRgb().?;
                                sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[38;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch break).len;
                            },
                        }
                    }

                    if (bg_changed) {
                        switch (cell.bg.tag) {
                            .default_, .terminal => {},
                            .indexed => {
                                sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;5;{}m", .{@as(u8, @truncate(cell.bg.value))}) catch break).len;
                            },
                            .rgb => {
                                const rgb = cell.bg.toRgb().?;
                                sgr_pos += (std.fmt.bufPrint(sgr_buf[sgr_pos..], "\x1b[48;2;{};{};{}m", .{ rgb[0], rgb[1], rgb[2] }) catch break).len;
                            },
                        }
                    }

                    active_fg = cell.fg;
                    active_bg = cell.bg;
                    active_attr = cell.attr;

                    try self.writeBytes(sgr_buf[0..sgr_pos]);
                }

                var cp = cell.char;
                if (cell.attr.sixel) {
                    cp = 0;
                }
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

    fn renderStatusBar(self: Display, session_name: []const u8, windows: []const *Window, active_window: ?*Window, fg: Colour, bg: Colour, message: ?[]const u8, command_mode: bool, command_buf: []const u8, search_prefix: u8, in_copy_mode: bool) Error!void {
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
            const prompt: []const u8 = if (search_prefix != 0) blk: {
                var buf: [2]u8 = undefined;
                buf[0] = search_prefix;
                buf[1] = ' ';
                break :blk buf[0..2];
            } else ":: ";
            try self.writeBytes(prompt);
            col += @intCast(prompt.len);
            const max_len = self.sx;
            const display_len = @min(command_buf.len, max_len -| col);
            if (display_len > 0) {
                try self.writeBytes(command_buf[0..display_len]);
                col += display_len;
            }
        } else if (message) |msg| {
            const max_len = self.sx;
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

                const remaining = (self.sx) -| col;
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

        const max_len = self.sx;
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
    ///
    /// The terminal renders sixel on a separate overlay layer that is *not*
    /// cleared by `CSI X` (Erase Character): re-drawing an image at its new
    /// anchor every frame while never erasing the previous positions leaves a
    /// smear as the image scrolls, and a removed image leaves a permanent ghost
    /// (bug #195). To fix this we track, per pane Screen, the anchor each slot
    /// was last drawn at (`sixel_last_anchor`). Each frame we:
    ///   1. erase any slot whose anchor moved or that disappeared (a DECSIXEL
    ///      Ps=0 erase-from-cursor-to-end operation, positioned at the
    ///   2. draw every currently-visible image at its current anchor.
    /// All erases happen before all draws so a redraw always restores any
    /// overlay pixels the erase may have cleared.
    fn renderSixelImages(self: Display, bounds: []const PaneBounds) Error!void {
        // Phase 0 — check if any pane has (or had) sixel images. Skip the
        // entire O(total_cells) per-pane scan when no sixels are present.
        var needs_erase = false;
        var has_sixel = false;
        for (bounds) |pb| {
            for (pb.pane.screen.sixel_images) |opt_img| {
                if (opt_img != null) {
                    needs_erase = true;
                    has_sixel = true;
                    break;
                }
            }
            for (pb.pane.screen.sixel_last_anchor) |opt_anchor| {
                if (opt_anchor != null) {
                    needs_erase = true;
                    break;
                }
            }
            if (needs_erase) break;
        }

        if (!has_sixel and !needs_erase) return;

        if (needs_erase) {
            try self.writeBytes("\x1bP2q\x1b\\"); // DECSIXEL erase all (Ps=2)
        }

        for (bounds) |pb| {
            const screen = &pb.pane.screen;
            const pane_h = pb.h;
            const pane_w = pb.w;

            var current: [64]?SixelAnchor = [_]?SixelAnchor{null} ** 64;

            var y: u32 = 0;
            while (y < pane_h) : (y += 1) {
                const hist_len = screen.grid.history.items.len - screen.grid.history_start;
                const combined_idx = (@as(isize, @intCast(hist_len)) - @as(isize, @intCast(if (screen.copy_mode) |cm| cm.scroll_offset else 0))) + @as(isize, @intCast(y));

                const cells = if (combined_idx < 0)
                    @as(?*const std.ArrayList(Cell), null)
                else if (combined_idx < hist_len)
                    &screen.grid.history.items[screen.grid.history_start + @as(usize, @intCast(combined_idx))].cells
                else blk: {
                    const visible_y = combined_idx - @as(isize, @intCast(hist_len));
                    break :blk if (visible_y < screen.grid.height)
                        &screen.grid.getLine(@intCast(visible_y)).cells
                    else
                        @as(?*const std.ArrayList(Cell), null);
                };

                if (cells) |cls| {
                    var x: u32 = 0;
                    while (x < pane_w) : (x += 1) {
                        const cell = if (x < cls.items.len) cls.items[x] else Cell.empty();
                        if (cell.attr.sixel) {
                            const image_id = cell.char;
                            if (screen.findSixelImageSlot(image_id)) |slot| {
                                if (current[slot] != null) continue;
                                const img = screen.sixel_images[slot].?;
                                const cell_rows = if (img.px_height > 0) (img.px_height + screen.cell_px_height - 1) / screen.cell_px_height else 1;
                                const cell_cols = if (img.px_width > 0) (img.px_width + screen.cell_px_width - 1) / screen.cell_px_width else 1;

                                const img_pane_col = @as(i32, @intCast(img.anchor_col));
                                const img_pane_row = @as(i32, @intCast(img.anchor_row));

                                const pane_left = @as(i32, @intCast(pb.x));
                                const pane_top = @as(i32, @intCast(pb.y));
                                const pane_right = pane_left + @as(i32, @intCast(pane_w));
                                const pane_bottom = pane_top + @as(i32, @intCast(pane_h));

                                const img_left = pane_left + img_pane_col;
                                const img_top = pane_top + img_pane_row;
                                const img_right = img_left + @as(i32, @intCast(cell_cols));
                                const img_bottom = img_top + @as(i32, @intCast(cell_rows));

                                const contained = img_left >= pane_left and
                                    img_right <= pane_right and
                                    img_top >= pane_top and
                                    img_bottom <= pane_bottom;

                                if (contained) {
                                    current[slot] = .{ .col = img_left, .row = img_top };
                                }
                            }
                        }
                    }
                }
            }

            // Phase 2 — draw every currently-visible image at its anchor.
            // (No per-slot erase needed since we cleared everything in phase 0.)
            for (current, 0..) |cur, slot| {
                if (cur == null) continue;
                const img = screen.sixel_images[slot].?;
                const px = @as(u32, @intCast(cur.?.col));
                const py = @as(u32, @intCast(cur.?.row));
                try self.moveTo(px, py);
                try self.writeBytes(img.data);
                try self.writeBytes("\x1b[m");
            }

            screen.sixel_last_anchor = current;
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

    try display.renderStatusBar("my-session", &windows, &win1, Colour.default_(), Colour.default_(), null, false, "", 0, false);

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

    try display.renderStatusBar("ses", &windows, &win1, Colour.default_(), Colour.default_(), null, false, "", 0, false);

    // Status bar should be exactly sx = 30 visible chars plus ESC sequences.
    // The long name must be truncated so the total emitted content does not
    // exceed 29 visible columns.
    const max_visible: usize = display.sx;
    var visible_cols: u32 = 0;
    var in_esc = false;
    for (capture_buf.items) |ch| {
        if (ch == 0x1b) {
            in_esc = true;
            continue;
        }
        if (in_esc) {
            if (ch == 'm' or ch == 'H') in_esc = false;
            continue;
        }
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
    }, null, false, "", 0, false, true);

    // Verify the cursor was NOT shown at the end
    const has_show_cursor = std.mem.indexOf(u8, capture_buf.items, "\x1b[?25h") != null;
    try std.testing.expect(!has_show_cursor);
}

test "renderAll honours force_clear from a non-active pane — bug #196" {
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

    var win1 = try Window.init(allocator, 1, "active", 40, 23, null);
    defer win1.deinit(allocator);
    var win2 = try Window.init(allocator, 2, "inactive", 40, 23, null);
    defer win2.deinit(allocator);
    const active_pane = win1.active_pane.?;
    const inactive_pane = win2.active_pane.?;

    // The non-active pane requests a force clear; the active one does not.
    inactive_pane.screen.force_clear = true;

    const bounds = [_]PaneBounds{
        .{ .pane = active_pane, .x = 0, .y = 0, .w = 40, .h = 23 },
        .{ .pane = inactive_pane, .x = 40, .y = 0, .w = 40, .h = 23 },
    };

    const Node = @import("../layout.zig").Node;
    const node = Node{ .leaf = active_pane };

    try display.renderAll(allocator, &bounds, active_pane, "sess", &[_]*Window{ &win1, &win2 }, &win1, &node, .{
        .status_fg = Colour.default_(),
        .status_bg = Colour.default_(),
        .pane_border_fg = Colour.fromIndexed(8),
        .pane_active_border_fg = Colour.fromIndexed(2),
    }, null, false, "", 0, false, true);

    // A full-screen erase must have been emitted because of the non-active pane.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[2J") != null);
    // The flag must be consumed so it doesn't fire every frame.
    try std.testing.expect(!inactive_pane.screen.force_clear);
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
    pane.screen.sixel_images[0] = .{
        .data = raw_dcs,
        .col = 5,
        .row = 3,
        .px_width = 10,
        .px_height = 20,
        .id = 0,
        .anchor_col = 5,
        .anchor_row = 3,
    };
    var cell = &pane.screen.grid.getLineMut(3).cells.items[5];
    cell.attr.sixel = true;
    cell.char = 0;
    cell.comb1 = 0;
    cell.comb2 = 0;

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

test "renderSixelImages renders sixel from every pane — bug #194" {
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

    var win1 = try Window.init(allocator, 1, "pane-a", 40, 23, null);
    defer win1.deinit(allocator);
    var win2 = try Window.init(allocator, 2, "pane-b", 40, 23, null);
    defer win2.deinit(allocator);
    const pane1 = win1.active_pane.?;
    const pane2 = win2.active_pane.?;

    // Both panes store their image in slot 0 (id % 64 == 0).
    const dcs1 = try allocator.dupe(u8, "\x1bPqONEx\x1b\\");
    pane1.screen.sixel_images[0] = .{ .data = dcs1, .col = 5, .row = 3, .px_width = 10, .px_height = 20, .id = 0 };
    var c1 = &pane1.screen.grid.getLineMut(3).cells.items[5];
    c1.attr.sixel = true;
    c1.char = 0;
    c1.comb1 = 0;
    c1.comb2 = 0;

    const dcs2 = try allocator.dupe(u8, "\x1bPqTWO\x1b\\");
    pane2.screen.sixel_images[0] = .{ .data = dcs2, .col = 5, .row = 3, .px_width = 10, .px_height = 20, .id = 0 };
    var c2 = &pane2.screen.grid.getLineMut(3).cells.items[5];
    c2.attr.sixel = true;
    c2.char = 0;
    c2.comb1 = 0;
    c2.comb2 = 0;

    const bounds = [_]PaneBounds{
        .{ .pane = pane1, .x = 0, .y = 0, .w = 40, .h = 23 },
        .{ .pane = pane2, .x = 0, .y = 0, .w = 40, .h = 23 },
    };
    try display.renderSixelImages(&bounds);

    // Both pane images must be emitted, even though they share slot index 0.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqONEx\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqTWO\x1b\\") != null);
}

test "renderSixelImages keeps partially-scrolled sixel visible — bug #197" {
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

    var win = try Window.init(allocator, 1, "partial", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    // A 5×10 cell image (50×200 px).
    const raw = try allocator.dupe(u8, "\x1bPqPARTIAL\x1b\\");
    pane.screen.cell_size_known = true;
    try pane.screen.addSixelImage(raw, 50, 200);

    // Simulate a 3-line upward scroll: shift every sixel cell's dy by +3 so the
    // image top sits at pane row -3 (partially scrolled off the top).
    var y: u32 = 0;
    while (y < 10) : (y += 1) {
        var x: u32 = 0;
        while (x < 5) : (x += 1) {
            var cell = pane.screen.grid.getLineMut(y).cells.items[x];
            if (cell.attr.sixel) {
                cell.comb2 = @intCast(y + 3);
                pane.screen.grid.getLineMut(y).cells.items[x] = cell;
            }
        }
    }

    const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 80, .h = 23 }};
    try display.renderSixelImages(&bounds);

    // The top is off-screen, but the remaining rows must still be emitted.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqPARTIAL\x1b\\") != null);
}

test "renderSixelImages clips sixel to pane and erases when scrolled above the border — bug #202" {
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

    // A 5×10 cell image (50×200 px) in the LOWER pane (terminal rows 12..22).
    var win = try Window.init(allocator, 1, "lower", 80, 11, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    const raw = try allocator.dupe(u8, "\x1bPqCLIP\x1b\\");
    pane.screen.sixel_images[0] = .{
        .data = raw,
        .col = 0,
        .row = 0,
        .px_width = 50,
        .px_height = 200,
        .id = 0,
        .anchor_col = 0,
        .anchor_row = 0,
    };
    var cell = &pane.screen.grid.getLineMut(0).cells.items[0];
    cell.attr.sixel = true;
    cell.char = 0;

    const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 12, .w = 80, .h = 11 }};

    // Pass 1: image fully inside the lower pane — it must be drawn.
    try display.renderSixelImages(&bounds);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqCLIP\x1b\\") != null);

    // Pass 2: scroll the image 13 lines up so its whole body is above the pane
    // top. It must be erased (not drawn at a pinned terminal-row-0 position,
    // which would bleed over the upper pane / get stuck on the split border).
    pane.screen.sixel_images[0].?.anchor_row = -13;

    capture_buf.clearRetainingCapacity();
    try display.renderSixelImages(&bounds);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqCLIP\x1b\\") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bP2q\x1b\\") != null);
}

test "renderSixelImages erases previous position when image scrolls — bug #195" {
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

    var win = try Window.init(allocator, 1, "smear", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    // Place the image at a known anchor so we can detect the erase at that
    // position after it scrolls.
    pane.screen.cursor.x = 0;
    pane.screen.cursor.y = 10;
    const raw = try allocator.dupe(u8, "\x1bPqSM\x1b\\");
    pane.screen.cell_size_known = true;
    try pane.screen.addSixelImage(raw, 10, 20); // anchor (0, 10)

    // First render draws the image at its anchor.
    const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 80, .h = 23 }};
    try display.renderSixelImages(&bounds);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqSM\x1b\\") != null);
    // Erase-all is emitted on the first frame since the image exists in the registry.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bP2q\x1b\\") != null);

    // Scroll the pane up by one line so the image anchor moves to row 9.
    pane.screen.cursor.x = 0;
    pane.screen.cursor.y = 22;
    try pane.screen.writeChar('\n'); // triggers scrollUp -> shiftSixelAnchors(-1)

    capture_buf.clearRetainingCapacity();
    try display.renderSixelImages(&bounds);

    // Erase-all is emitted, and the image is redrawn at its new anchor.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bP2q\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqSM\x1b\\") != null);
}

test "renderSixelImages erases removed image overlay — bug #195" {
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

    var win = try Window.init(allocator, 1, "ghost", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    pane.screen.cursor.x = 0;
    pane.screen.cursor.y = 5;
    const raw = try allocator.dupe(u8, "\x1bPqGHOST\x1b\\");
    pane.screen.cell_size_known = true;
    try pane.screen.addSixelImage(raw, 10, 20); // anchor (0, 5)

    const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 80, .h = 23 }};
    try display.renderSixelImages(&bounds);

    // Remove the image from the registry (e.g. eraseDisplay mode 2).
    if (pane.screen.sixel_images[0]) |*img| img.deinit(pane.screen.allocator);
    pane.screen.sixel_images[0] = null;

    capture_buf.clearRetainingCapacity();
    try display.renderSixelImages(&bounds);

    // The previously drawn overlay must be erased (no image redrawn, but an
    // erase-all is emitted to clear the sixel layer).
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqGHOST\x1b\\") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bP2q\x1b\\") != null);
}

test "renderSixelImages derives position from image anchor not cell comb — bug #200" {
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

    var win = try Window.init(allocator, 1, "anchor", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    const raw = try allocator.dupe(u8, "\x1bPqANCHOR\x1b\\");
    pane.screen.cell_size_known = true;
    try pane.screen.addSixelImage(raw, 10, 20);

    // Corrupt the top-left cell's comb2 (simulating a partial overwrite that
    // failed to clear attr.sixel). Before the fix the render position was
    // derived from cell.comb2, yielding a bogus anchor and dropping the image.
    var cell = pane.screen.grid.getLineMut(0).cells.items[0];
    cell.comb2 = 99;
    pane.screen.grid.getLineMut(0).cells.items[0] = cell;

    const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 80, .h = 23 }};
    try display.renderSixelImages(&bounds);

    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqANCHOR\x1b\\") != null);
}

test "sy saturating subtraction — bug #126" {
    try testing.expectEqual(@as(u32, 0), @as(u32, 0) -| 1);
    try testing.expectEqual(@as(u32, 0), @as(u32, 1) -| 1);
    try testing.expectEqual(@as(u32, 2), @as(u32, 3) -| 1);
}

test "sixel rendering with scrolling" {
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

    var win = try Window.init(allocator, 1, "test-sixel-scrolling", 80, 23, null);
    defer win.deinit(allocator);
    const pane = win.active_pane.?;

    // Position cursor at the pane bottom row (22)
    pane.screen.cursor.y = 22;

    // Call addSixelImage with a 15-row height image (300px with cell_px_height=20)
    const raw_dcs = try allocator.dupe(u8, "\x1bPqTEST\x1b\\");
    pane.screen.cell_size_known = true;
    try pane.screen.addSixelImage(raw_dcs, 100, 300);

    // Verify cell coordinates after addSixelImage. The cursor was on the last
    // line (22); a 15-row image anchored there scrolls up by 15 (14 to fit plus
    // 1 so the cursor lands on the last content line), putting its top at 7.
    {
        const cell = pane.screen.grid.getCell(0, 7);
        try std.testing.expect(cell.attr.sixel);
        try std.testing.expectEqual(@as(u21, 0), cell.char); // image id 0
        try std.testing.expectEqual(@as(u13, 0), cell.comb2); // dy = 0
    }

    // Write a newline to trigger a scroll in writeChar
    try pane.screen.writeChar('\n');

    // Verify cell coordinate is decremented to 6 (it has scrolled up by 1)
    {
        const cell = pane.screen.grid.getCell(0, 6);
        try std.testing.expect(cell.attr.sixel);
        try std.testing.expectEqual(@as(u21, 0), cell.char);
        try std.testing.expectEqual(@as(u13, 0), cell.comb2);
    }

    // Render it!
    const bounds = [_]PaneBounds{.{
        .pane = pane,
        .x = 0,
        .y = 0,
        .w = 80,
        .h = 23,
    }};
    try display.renderSixelImages(&bounds);

    // Verify output: after the single scroll the image top is at pane row 6
    // (0-indexed), i.e. 1-indexed 7H.
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1b[7;1H") != null);
    // Verbatim DCS bytes
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqTEST\x1b\\") != null);

    // Scroll enough that the image is completely off-screen (anchor + cell_rows
    // <= 0). With a 15-row image and anchor at 6 after the first newline, this
    // needs >15 further scrolls (bug #197/#200: partial scroll now keeps the
    // still-visible remainder, so we must push it fully past the top edge).
    var i: usize = 0;
    while (i < 22) : (i += 1) {
        try pane.screen.writeChar('\n');
    }

    capture_buf.clearRetainingCapacity();
    
    // Render it!
    // Since the top of the image went off-screen, renderAll should clear attr.sixel
    var merged = try Screen.init(allocator, 80, 23);
    defer merged.deinit();

    const Node = @import("../layout.zig").Node;
    const node = Node{ .leaf = pane };
    const windows = [_]*Window{&win};

    var opt_merged: ?Screen = merged;
    var display_with_merged = display;
    display_with_merged.merged_screen = &opt_merged;

    try display_with_merged.renderAll(allocator, &bounds, pane, "session", &windows, &win, &node, .{
        .status_fg = Colour.default_(),
        .status_bg = Colour.default_(),
        .pane_border_fg = Colour.fromIndexed(8),
        .pane_active_border_fg = Colour.fromIndexed(2),
    }, null, false, "", 0, false, true);

    // Swap back to free resources correctly in defer
    merged = opt_merged.?;
    
    // Verify that the sixel attribute is cleared for the cells
    const cell = merged.grid.getCell(0, 0);
    try std.testing.expect(!cell.attr.sixel);

    // Verify output: DCS bytes should NOT be in the output
    try std.testing.expect(std.mem.indexOf(u8, capture_buf.items, "\x1bPqTEST\x1b\\") == null);
}

