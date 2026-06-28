const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const grid = @import("grid.zig");
const char_width = @import("char_width.zig");

/// A sixel image stored as the raw DCS bytes (ESC P ... ESC \) received from
/// the child process. We keep the original bytes so we can re-emit them
/// verbatim to the outer terminal, which handles actual pixel rendering.
/// The image is anchored to the cell position of the cursor at the moment the
/// DCS sequence started. `cell_w` / `cell_h` are the number of character
/// cells the image occupies (derived from pixel dimensions / cell size).
pub const SixelImage = struct {
    /// Raw DCS sequence bytes including the leading ESC P and trailing ESC \
    data: []u8,
    /// Cell column where the image starts (cursor x when DCS began)
    col: u32,
    /// Cell row where the image starts (cursor y when DCS began)
    row: u32,
    /// Width in pixels (parsed from sixel P2 parameter or 0 if unknown)
    px_width: u32,
    /// Height in pixels (counted from sixel band count * 6, or 0 if unknown)
    px_height: u32,

    pub fn deinit(self: *SixelImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};
const Cell = grid.Cell;
const Grid = grid.Grid;
const GridLine = grid.GridLine;
const Colour = colour.Colour;

pub const Error = grid.Error || error{OutOfMemory};

pub const Cursor = struct {
    x: u32 = 0,
    y: u32 = 0,
    visible: bool = true,
    style: CursorStyle = .block,
    blink: bool = true,
};

pub const CursorStyle = enum(u8) {
    block,
    underline,
    bar,
};

pub const Mode = packed struct(u32) {
    insert: bool = false,
    keypad: bool = false,
    line_wrap: bool = true,
    mouse_standard: bool = false,
    mouse_button: bool = false,
    mouse_utf8: bool = false,
    mouse_sgr: bool = false,
    focus: bool = false,
    paste: bool = false,
    alt_screen: bool = false,
    cursor: bool = true,
    origin: bool = false,
    sync: bool = false,
    _padding: u19 = 0,
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    grid: Grid,
    alt_grid: ?Grid = null,
    cursor: Cursor = .{},
    saved_cursor: ?Cursor = null,
    alt_cursor: Cursor = .{},
    alt_saved_cursor: ?Cursor = null,
    mode: Mode = .{},
    scroll_region: ?[2]u32 = null,
    cur_cell: Cell = Cell.empty(),
    dirty: bool = true,
    copy_mode: ?@import("mode_copy.zig").CopyMode = null,
    clock_mode: bool = false,
    clock_utc: bool = false,
    tab_stop: u32 = 8,
    /// Sixel images received from child processes, kept for re-emission.
    sixel_images: std.ArrayListUnmanaged(SixelImage) = .empty,
    last_char: ?u21 = null,
    extkeys: u8 = 0,
    kitty_kbd_flags: u32 = 0,
    kitty_kbd_stack: [8]u32 = [_]u32{0} ** 8,
    kitty_kbd_stack_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Screen {
        return Screen{
            .allocator = allocator,
            .grid = try Grid.init(allocator, width, height),
            .copy_mode = null,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        if (self.alt_grid) |*g| g.deinit();
        for (self.sixel_images.items) |*img| img.deinit(self.allocator);
        self.sixel_images.deinit(self.allocator);
    }

    /// Store a sixel image at the current cursor position.
    /// `dcs_bytes` must be the complete raw DCS sequence (ESC P ... ESC \).
    /// Ownership is transferred — `dcs_bytes` must have been allocated with
    /// `self.allocator`.
    pub fn addSixelImage(
        self: *Screen,
        dcs_bytes: []u8,
        px_width: u32,
        px_height: u32,
    ) Error!void {
        const img = SixelImage{
            .data = dcs_bytes,
            .col = self.cursor.x,
            .row = self.cursor.y,
            .px_width = px_width,
            .px_height = px_height,
        };
        try self.sixel_images.append(self.allocator, img);
        // Advance cursor down by the number of character rows the image spans.
        // Most terminals use 20px per cell row as a fallback when the pixel
        // height of a cell is unknown; szn uses the same conservative value.
        const cell_rows = if (px_height > 0) (px_height + 19) / 20 else 1;
        var r: u32 = 0;
        while (r < cell_rows) : (r += 1) {
            if (self.cursor.y + 1 < self.grid.height) {
                self.cursor.y += 1;
            } else {
                try self.grid.scrollUp();
            }
        }
        self.cursor.x = 0;
        self.dirty = true;
    }

    /// Remove all sixel images whose anchor row is above the visible area
    /// (scrolled out of view) to keep memory bounded.
    pub fn pruneSixelImages(self: *Screen) void {
        var i: usize = 0;
        while (i < self.sixel_images.items.len) {
            if (self.sixel_images.items[i].row >= self.grid.height) {
                var img = self.sixel_images.swapRemove(i);
                img.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    pub fn eraseCell(self: *const Screen) Cell {
        return .{
            .char = ' ',
            .attr = .{},
            .fg = Colour.default_(),
            .bg = self.cur_cell.bg,
        };
    }

    pub fn resize(self: *Screen, width: u32, height: u32) Error!void {
        try self.grid.setSize(width, height);
        if (self.alt_grid) |*g| {
            try g.setSize(width, height);
        }
        self.cursor.x = @min(self.cursor.x, width -| 1);
        self.cursor.y = @min(self.cursor.y, height -| 1);
    }

    fn scrollUpInRegion(self: *Screen) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        if (self.cursor.y != bottom) return;
        var y = top;
        while (y < bottom) : (y += 1) {
            const line = self.grid.getLineMut(y);
            const next = self.grid.getLineMut(y + 1);
            std.mem.swap(GridLine, line, next);
        }
        const last = self.grid.getLineMut(bottom);
        @memset(last.cells.items, self.eraseCell());
        last.dirty = true;
    }

    fn scrollDownInRegion(self: *Screen) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        if (self.cursor.y != top) return;
        var y = bottom;
        while (y > top) : (y -= 1) {
            const line = self.grid.getLineMut(y);
            const prev = self.grid.getLineMut(y - 1);
            std.mem.swap(GridLine, line, prev);
        }
        const first = self.grid.getLineMut(top);
        @memset(first.cells.items, self.eraseCell());
        first.dirty = true;
    }

    pub fn writeChar(self: *Screen, char: u21) Error!void {
        if (char < 0x20) {
            self.last_char = null;
        }
        if (char == '\n') {
            if (self.cursor.y + 1 >= self.grid.height) {
                try self.grid.scrollUp();
                const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                @memset(bottom_line.cells.items, self.eraseCell());
                bottom_line.dirty = true;
            } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                try self.scrollUpInRegion();
            } else {
                self.cursor.y += 1;
            }
            self.dirty = true;
            return;
        }
        if (char == '\r') {
            self.cursor.x = 0;
            self.dirty = true;
            return;
        }
        if (char == '\t') {
            self.cursor.x = ((self.cursor.x / self.tab_stop) + 1) * self.tab_stop;
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = self.grid.width - 1;
            }
            self.dirty = true;
            return;
        }
        if (char == 0x07) {
            // BEL — ignored for now
            return;
        }
        if (char == 0x08) {
            // BS
            if (self.cursor.x > 0) self.cursor.x -= 1;
            return;
        }
        if (char < 0x20 and char != '\x1b') return;

        const width = char_width.charWidth(char);
        if (width > 0) {
            self.last_char = char;
        }

        if (width == 0) {
            if (self.cursor.x == 0) return;
            var base_x = self.cursor.x - 1;
            var prev_cell = self.grid.getCell(base_x, self.cursor.y);
            if (prev_cell.is_padding) {
                if (self.cursor.x < 2) return;
                base_x = self.cursor.x - 2;
                prev_cell = self.grid.getCell(base_x, self.cursor.y);
            }
            if (prev_cell.char == ' ' or prev_cell.char == 0) return;
            const cidx = char_width.combiningIndex(char);
            if (cidx == 0) return;
            if (prev_cell.comb1 == 0) {
                prev_cell.comb1 = cidx;
            } else if (prev_cell.comb2 == 0) {
                prev_cell.comb2 = cidx;
            }
            self.grid.setCell(base_x, self.cursor.y, prev_cell);
            self.dirty = true;
            return;
        }

        if (width == 2) {
            if (self.mode.line_wrap and self.cursor.x + 2 > self.grid.width) {
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                    const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                    @memset(bottom_line.cells.items, self.eraseCell());
                    bottom_line.dirty = true;
                } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                    try self.scrollUpInRegion();
                } else {
                    self.cursor.y += 1;
                }
            }
            if (self.cursor.x + 1 >= self.grid.width and !self.mode.line_wrap) return;
            if (self.cursor.x >= self.grid.width) return;

            var cell = self.cur_cell;
            cell.char = char;
            self.grid.setCell(self.cursor.x, self.cursor.y, cell);

            var pad_cell = self.cur_cell;
            pad_cell.char = 0;
            pad_cell.is_padding = true;
            if (self.cursor.x + 1 < self.grid.width) {
                self.grid.setCell(self.cursor.x + 1, self.cursor.y, pad_cell);
            }
            self.dirty = true;

            if (self.mode.line_wrap) {
                self.cursor.x += 2;
            } else {
                self.cursor.x = @min(self.cursor.x + 2, self.grid.width - 1);
            }
            return;
        }

        if (self.mode.line_wrap) {
            if (self.cursor.x >= self.grid.width) {
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                    const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                    @memset(bottom_line.cells.items, self.eraseCell());
                    bottom_line.dirty = true;
                } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                    try self.scrollUpInRegion();
                } else {
                    self.cursor.y += 1;
                }
            }
        }

        if (self.mode.insert) {
            var x = self.grid.width - 1;
            while (x > self.cursor.x) : (x -= 1) {
                const prev = self.grid.getCell(x - 1, self.cursor.y);
                self.grid.setCell(x, self.cursor.y, prev);
            }
        }

        var cell = self.cur_cell;
        cell.char = char;
        self.grid.setCell(self.cursor.x, self.cursor.y, cell);
        self.dirty = true;

        if (self.mode.line_wrap) {
            self.cursor.x += 1;
        } else {
            self.cursor.x = @min(self.cursor.x + 1, self.grid.width - 1);
        }
    }

    pub fn writeStr(self: *Screen, s: []const u8) Error!void {
        for (s) |c| {
            try self.writeChar(c);
        }
    }

    pub fn repeatLastChar(self: *Screen, count: u32) Error!void {
        if (self.last_char) |lc| {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try self.writeChar(lc);
            }
        }
    }

    pub fn setCursorAbs(self: *Screen, x: u32, y: u32) void {
        self.cursor.x = @min(x, self.grid.width -| 1);
        self.cursor.y = @min(y, self.grid.height -| 1);
        self.dirty = true;
    }

    pub fn cursorUp(self: *Screen, n: u32) void {
        const top = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[0] else 0;
        } else 0;
        const count = @min(n, self.cursor.y -| top);
        self.cursor.y -= count;
        self.dirty = true;
    }

    pub fn cursorDown(self: *Screen, n: u32) void {
        const bottom: u32 = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        } else self.grid.height - 1;
        const count = @min(n, bottom -| self.cursor.y);
        self.cursor.y += count;
        self.dirty = true;
    }

    pub fn cursorForward(self: *Screen, n: u32) void {
        self.cursor.x = @min(self.cursor.x + n, self.grid.width - 1);
        self.dirty = true;
    }

    pub fn cursorBack(self: *Screen, n: u32) void {
        self.cursor.x -|= n;
        self.dirty = true;
    }

    pub fn cursorColumn(self: *Screen, x: u32) void {
        self.cursor.x = @min(x, self.grid.width -| 1);
        self.dirty = true;
    }

    pub fn cursorLine(self: *Screen, y: u32) void {
        const origin_y = if (self.mode.origin) blk: {
            break :blk if (self.scroll_region) |r| r[0] else 0;
        } else 0;
        const actual = @min(y +| origin_y, self.grid.height -| 1);
        self.cursor.y = actual;
        self.dirty = true;
    }

    pub fn cursorPosition(self: *Screen, col: u32, row: u32) void {
        const y: u32 = if (self.mode.origin) blk: {
            if (self.scroll_region) |r| {
                break :blk @min(row + r[0], r[1]);
            }
            break :blk @min(row, self.grid.height -| 1);
        } else @min(row, self.grid.height -| 1);
        self.cursor.y = y;
        self.cursor.x = @min(col, self.grid.width -| 1);
        self.dirty = true;
    }

    pub fn eraseLine(self: *Screen, mode: u8) void {
        const fill = self.eraseCell();
        switch (mode) {
            0 => {
                var x = self.cursor.x;
                while (x < self.grid.width) : (x += 1) {
                    self.grid.setCell(x, self.cursor.y, fill);
                }
            },
            1 => {
                var x: u32 = 0;
                while (x <= self.cursor.x) : (x += 1) {
                    self.grid.setCell(x, self.cursor.y, fill);
                }
            },
            2 => {
                const line = self.grid.getLineMut(self.cursor.y);
                @memset(line.cells.items, fill);
                line.dirty = true;
            },
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseDisplay(self: *Screen, mode: u8) void {
        const fill = self.eraseCell();
        switch (mode) {
            0 => {
                var y = self.cursor.y;
                while (y < self.grid.height) : (y += 1) {
                    if (y == self.cursor.y) {
                        self.eraseLine(0);
                    } else {
                        const line = self.grid.getLineMut(y);
                        @memset(line.cells.items, fill);
                        line.dirty = true;
                    }
                }
            },
            1 => {
                var y: u32 = 0;
                while (y <= self.cursor.y) : (y += 1) {
                    if (y == self.cursor.y) {
                        self.eraseLine(1);
                    } else {
                        const line = self.grid.getLineMut(y);
                        @memset(line.cells.items, fill);
                        line.dirty = true;
                    }
                }
            },
            2 => {
                for (0..self.grid.height) |y| {
                    const line = self.grid.getLineMut(@intCast(y));
                    @memset(line.cells.items, fill);
                    line.dirty = true;
                }
            },
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseChars(self: *Screen, n: u32) void {
        const fill = self.eraseCell();
        const end = @min(self.cursor.x + n, self.grid.width);
        if (self.cursor.x < end) {
            const line = self.grid.getLineMut(self.cursor.y);
            @memset(line.cells.items[self.cursor.x..end], fill);
            line.dirty = true;
        }
        self.dirty = true;
    }

    pub fn insertLines(self: *Screen, n: u32) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        const y = @max(self.cursor.y, top);
        if (y > bottom) return;
        const count = @min(n, bottom + 1 - y);
        const fill = self.eraseCell();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var row = bottom;
            const temp = self.grid.getLine(bottom).*;
            while (row > y) : (row -= 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row - 1).*;
            }
            self.grid.getLineMut(y).* = temp;
            const line = self.grid.getLineMut(y);
            @memset(line.cells.items, fill);
            line.dirty = true;
        }
        self.dirty = true;
    }

    pub fn deleteLines(self: *Screen, n: u32) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        const bottom = if (self.scroll_region) |r| r[1] else self.grid.height - 1;
        const y = @max(self.cursor.y, top);
        if (y > bottom) return;
        const count = @min(n, bottom + 1 - y);
        const fill = self.eraseCell();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const temp = self.grid.getLine(y).*;
            var row = y;
            while (row < bottom) : (row += 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row + 1).*;
            }
            self.grid.getLineMut(bottom).* = temp;
            const line = self.grid.getLineMut(bottom);
            @memset(line.cells.items, fill);
            line.dirty = true;
        }
        self.dirty = true;
    }

    pub fn insertChars(self: *Screen, n: u32) void {
        self.grid.insertChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn deleteChars(self: *Screen, n: u32) void {
        self.grid.deleteChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn index(self: *Screen) Error!void {
        if (self.scroll_region) |r| {
            if (self.cursor.y == r[1]) {
                try self.scrollUpInRegion();
                return;
            }
        } else if (self.cursor.y + 1 >= self.grid.height) {
            try self.grid.scrollUp();
            const bottom_line = self.grid.getLineMut(self.grid.height - 1);
            @memset(bottom_line.cells.items, self.eraseCell());
            bottom_line.dirty = true;
            return;
        }
        self.cursor.y += 1;
    }

    pub fn reverseIndex(self: *Screen) Error!void {
        if (self.scroll_region) |r| {
            if (self.cursor.y == r[0]) {
                try self.scrollDownInRegion();
                return;
            }
        } else if (self.cursor.y == 0) {
            if (self.grid.history.items.len > 0) {
                try self.grid.scrollDown();
                const top_line = self.grid.getLineMut(0);
                @memset(top_line.cells.items, self.eraseCell());
                top_line.dirty = true;
            }
            return;
        }
        self.cursor.y -|= 1;
    }

    pub fn scrollUp(self: *Screen, n: u32) Error!void {
        if (self.scroll_region) |r| {
            const top = r[0];
            const bottom = r[1];
            const count = @min(n, bottom + 1 - top);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const temp = self.grid.getLine(top).*;
                var row = top;
                while (row < bottom) : (row += 1) {
                    self.grid.getLineMut(row).* = self.grid.getLine(row + 1).*;
                }
                self.grid.getLineMut(bottom).* = temp;
                const last = self.grid.getLineMut(bottom);
                @memset(last.cells.items, fill);
                last.dirty = true;
            }
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try self.grid.scrollUp();
                const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                @memset(bottom_line.cells.items, fill);
                bottom_line.dirty = true;
            }
        }
    }

    pub fn scrollDown(self: *Screen, n: u32) Error!void {
        if (self.scroll_region) |r| {
            const top = r[0];
            const bottom = r[1];
            const count = @min(n, bottom + 1 - top);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var row = bottom;
                const temp = self.grid.getLine(bottom).*;
                while (row > top) : (row -= 1) {
                    self.grid.getLineMut(row).* = self.grid.getLine(row - 1).*;
                }
                self.grid.getLineMut(top).* = temp;
                const first = self.grid.getLineMut(top);
                @memset(first.cells.items, fill);
                first.dirty = true;
            }
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (self.grid.history.items.len > 0) {
                    try self.grid.scrollDown();
                    const top_line = self.grid.getLineMut(0);
                    @memset(top_line.cells.items, fill);
                    top_line.dirty = true;
                }
            }
        }
    }

    pub fn setScrollRegion(self: *Screen, top: u32, bottom: u32) void {
        self.scroll_region = .{ @min(top, self.grid.height -| 1), @min(bottom, self.grid.height -| 1) };
        self.cursor.x = 0;
        self.cursor.y = if (self.mode.origin) self.scroll_region.?[0] else 0;
        self.dirty = true;
    }

    pub fn setOriginMode(self: *Screen, enable: bool) void {
        self.mode.origin = enable;
        self.cursor.x = 0;
        self.cursor.y = if (enable and self.scroll_region != null) self.scroll_region.?[0] else 0;
        self.dirty = true;
    }

    pub fn saveCursor(self: *Screen) void {
        self.saved_cursor = self.cursor;
    }

    pub fn restoreCursor(self: *Screen) void {
        if (self.saved_cursor) |saved| {
            self.cursor = saved;
            self.dirty = true;
        }
    }

    pub fn setSgr(self: *Screen, params: []const u32, sub_params: []const bool) void {
        if (params.len == 0) {
            self.cur_cell = Cell.empty();
            return;
        }
        var i: usize = 0;
        while (i < params.len) {
            const p = params[i];
            i += 1;
            switch (p) {
                0 => self.cur_cell = Cell.empty(),
                1 => self.cur_cell.attr.bold = true,
                2 => self.cur_cell.attr.dim = true,
                3 => self.cur_cell.attr.italic = true,
                4 => {
                    if (i < params.len and sub_params[i]) {
                        const sub = params[i];
                        i += 1;
                        switch (sub) {
                            0 => {
                                self.cur_cell.attr.underline = false;
                                self.cur_cell.attr.double_underline = false;
                                self.cur_cell.attr.curly_underline = false;
                            },
                            2 => self.cur_cell.attr.double_underline = true,
                            3 => self.cur_cell.attr.curly_underline = true,
                            else => self.cur_cell.attr.underline = true,
                        }
                    } else {
                        self.cur_cell.attr.underline = true;
                    }
                },
                5 => self.cur_cell.attr.blink = true,
                7 => self.cur_cell.attr.reverse = true,
                8 => self.cur_cell.attr.concealed = true,
                9 => self.cur_cell.attr.strikethrough = true,
                21 => self.cur_cell.attr.double_underline = true,
                22 => {
                    self.cur_cell.attr.bold = false;
                    self.cur_cell.attr.dim = false;
                },
                23 => self.cur_cell.attr.italic = false,
                24 => {
                    self.cur_cell.attr.underline = false;
                    self.cur_cell.attr.double_underline = false;
                    self.cur_cell.attr.curly_underline = false;
                },
                25 => self.cur_cell.attr.blink = false,
                27 => self.cur_cell.attr.reverse = false,
                28 => self.cur_cell.attr.concealed = false,
                29 => self.cur_cell.attr.strikethrough = false,
                30...37 => {
                    const idx = p - 30;
                    self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                },
                38 => {
                    if (i < params.len) {
                        const next = params[i];
                        i += 1;
                        if (next == 5) {
                            if (i < params.len) {
                                const idx = params[i];
                                i += 1;
                                self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                            }
                        } else if (next == 2) {
                            if (i + 2 < params.len) {
                                const r = params[i];
                                const g = params[i + 1];
                                const b = params[i + 2];
                                i += 3;
                                self.cur_cell.fg = Colour.fromRgb(@intCast(r), @intCast(g), @intCast(b));
                            }
                        }
                    }
                },
                39 => self.cur_cell.fg = Colour.default_(),
                40...47 => {
                    const idx = p - 40;
                    self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                },
                48 => {
                    if (i < params.len) {
                        const next = params[i];
                        i += 1;
                        if (next == 5) {
                            if (i < params.len) {
                                const idx = params[i];
                                i += 1;
                                self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                            }
                        } else if (next == 2) {
                            if (i + 2 < params.len) {
                                const r = params[i];
                                const g = params[i + 1];
                                const b = params[i + 2];
                                i += 3;
                                self.cur_cell.bg = Colour.fromRgb(@intCast(r), @intCast(g), @intCast(b));
                            }
                        }
                    }
                },
                49 => self.cur_cell.bg = Colour.default_(),
                90...97 => {
                    const idx = p - 90 + 8;
                    self.cur_cell.fg = Colour.fromIndexed(@intCast(idx));
                },
                100...107 => {
                    const idx = p - 100 + 8;
                    self.cur_cell.bg = Colour.fromIndexed(@intCast(idx));
                },
                else => {},
            }
        }
    }

    pub fn resetHard(self: *Screen) Error!void {
        self.cursor = .{};
        self.saved_cursor = null;
        self.mode = .{};
        self.scroll_region = null;
        self.cur_cell = Cell.empty();
        self.last_char = null;
        self.extkeys = 0;
        self.kitty_kbd_flags = 0;
        self.kitty_kbd_stack_len = 0;
        self.grid.clear();
        self.dirty = true;
    }

    pub fn clearLine(self: *Screen, y: u32) void {
        self.grid.clearLine(y);
        self.dirty = true;
    }

    pub fn clearScreen(self: *Screen) void {
        self.grid.clear();
        self.dirty = true;
    }

    pub fn useAltScreen(self: *Screen, enable: bool) Error!void {
        if (enable and self.alt_grid == null) {
            var new_alt = try Grid.init(self.allocator, self.grid.width, self.grid.height);
            std.mem.swap(Grid, &self.grid, &new_alt);
            self.alt_grid = new_alt;

            std.mem.swap(Cursor, &self.cursor, &self.alt_cursor);
            var opt_saved = self.alt_saved_cursor;
            std.mem.swap(?Cursor, &self.saved_cursor, &opt_saved);
            self.alt_saved_cursor = opt_saved;
        } else if (!enable and self.alt_grid != null) {
            var saved = self.alt_grid.?;
            std.mem.swap(Grid, &self.grid, &saved);
            saved.deinit();
            self.alt_grid = null;

            std.mem.swap(Cursor, &self.cursor, &self.alt_cursor);
            var opt_saved = self.alt_saved_cursor;
            std.mem.swap(?Cursor, &self.saved_cursor, &opt_saved);
            self.alt_saved_cursor = opt_saved;

            self.alt_cursor = .{};
            self.alt_saved_cursor = null;
        }
        self.mode.alt_screen = enable;
        self.dirty = true;
    }
};

// ── Tests ──

test "create screen" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    try testing.expectEqual(@as(u32, 80), screen.grid.width);
    try testing.expectEqual(@as(u32, 24), screen.grid.height);
}

test "write char advances cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar('A');
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
}

test "write string" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("Hello");
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
    try testing.expectEqual(@as(u21, 'H'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'o'), screen.grid.getCell(4, 0).char);
}

test "newline moves to next line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // LF moves down only; cursor X is preserved (CR resets X separately).
    try screen.writeStr("abc\ndef");
    try testing.expectEqual(@as(u32, 6), screen.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'a'), screen.grid.getCell(0, 0).char);
    // 'd' lands at col 3 (where cursor was after 'abc').
    try testing.expectEqual(@as(u21, 'd'), screen.grid.getCell(3, 1).char);
}

test "carriage return resets x" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello\rX");
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(0, 0).char);
}

test "line wrapping" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("123456789A");
    try testing.expectEqual(@as(u32, 10), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);

    try screen.writeChar('B');
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);

    try testing.expectEqual(@as(u21, '1'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(9, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(0, 1).char);
}

test "scrolling when full" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("line1\nline2\nline3\nline4\n");
    try testing.expectEqual(@as(u21, 'e'), screen.grid.getCell(3, 0).char);
}

test "cursor positioning" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorAbs(40, 12);
    try testing.expectEqual(@as(u32, 40), screen.cursor.x);
    try testing.expectEqual(@as(u32, 12), screen.cursor.y);
}

test "set cursor clamps to bounds" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursorAbs(999, 999);
    try testing.expectEqual(@as(u32, 79), screen.cursor.x);
    try testing.expectEqual(@as(u32, 23), screen.cursor.y);
}

test "clear line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello");
    screen.clearLine(0);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
    try testing.expect(screen.dirty);
}

test "clear screen" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("hello");
    screen.clearScreen();
    try testing.expect(screen.grid.isEmpty());
}

test "alt screen swap" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeStr("normal screen");
    try testing.expect(!screen.grid.isEmpty());

    try screen.useAltScreen(true);
    try testing.expect(screen.grid.isEmpty());
    try testing.expect(screen.mode.alt_screen);

    try screen.writeStr("alt content");
    try testing.expect(!screen.grid.isEmpty());

    try screen.useAltScreen(false);
    try testing.expect(!screen.mode.alt_screen);
    try testing.expect(!screen.grid.isEmpty());
    try testing.expectEqual(@as(u21, 'n'), screen.grid.getCell(0, 0).char);
}

test "insert mode shifts cells right" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();

    try screen.writeStr("ABCDE");

    screen.mode.insert = true;
    screen.setCursorAbs(2, 0);
    try screen.writeChar('X');

    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'C'), screen.grid.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(4, 0).char);
}

test "Tab moves to next tab stop" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar('\t');
    try testing.expectEqual(@as(u32, 8), screen.cursor.x);
}

test "control chars are ignored" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar(0x01);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
}

test "cursorUp clamped to top" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 2;
    screen.cursorUp(10);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
}

test "cursorDown clamped to bottom" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 20;
    screen.cursorDown(10);
    try testing.expectEqual(@as(u32, 23), screen.cursor.y);
}

test "cursorForward clamped to right" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 75;
    screen.cursorForward(10);
    try testing.expectEqual(@as(u32, 79), screen.cursor.x);
}

test "cursorBack won't underflow" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursorBack(5);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "eraseLine mode 1 clears from start to cursor" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("ABCDE");
    screen.cursor.x = 2;
    screen.eraseLine(1);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(3, 0).char);
}

test "eraseLine mode 2 clears entire line" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("ABCDE");
    screen.eraseLine(2);
    try testing.expect(screen.grid.isEmpty());
}

test "eraseDisplay mode 2 clears all" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeStr("line1\nline2\nline3");
    screen.eraseDisplay(2);
    try testing.expect(screen.grid.isEmpty());
}

test "cursor save and restore" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 10;
    screen.cursor.y = 5;
    screen.saveCursor();
    screen.cursor.x = 99;
    screen.cursor.y = 99;
    screen.restoreCursor();
    try testing.expectEqual(@as(u32, 10), screen.cursor.x);
    try testing.expectEqual(@as(u32, 5), screen.cursor.y);
}

test "setSgr bold + italic" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.setSgr(&[_]u32{ 1, 3 }, &[_]bool{ false, false });
    try screen.writeChar('X');
    try testing.expect(screen.grid.getCell(0, 0).attr.bold);
    try testing.expect(screen.grid.getCell(0, 0).attr.italic);
}

test "setSgr empty resets" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.setSgr(&[_]u32{1}, &[_]bool{false});
    screen.setSgr(&.{}, &.{});
    try testing.expect(!screen.cur_cell.attr.bold);
}

test "origin mode clamps cursor" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "scroll region with cursor up (origin mode)" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    screen.cursor.y = 2;
    screen.cursorUp(5);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "scroll region with cursor down (origin mode)" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    screen.cursor.y = 2;
    screen.cursorDown(5);
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "index within scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    try screen.writeStr("aaa\nbbb\nccc\nddd\neee");
    screen.cursor.y = 3;
    try screen.index();
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "reverse index within scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.cursor.y = 1;
    try screen.reverseIndex();
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "hard reset restores defaults" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.mode.line_wrap = false;
    screen.mode.insert = true;
    screen.setSgr(&[_]u32{ 1, 31 }, &[_]bool{ false, false });
    try screen.resetHard();
    try testing.expect(screen.mode.line_wrap);
    try testing.expect(!screen.mode.insert);
    try testing.expect(!screen.cur_cell.attr.bold);
    try testing.expect(screen.grid.isEmpty());
}

test "setCursorAbs absolute positioning" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.setCursorAbs(40, 12);
    try testing.expectEqual(@as(u32, 40), screen.cursor.x);
    try testing.expectEqual(@as(u32, 12), screen.cursor.y);
}

test "BEL is ignored" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeChar(0x07);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "BS moves cursor left" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    screen.cursor.x = 5;
    try screen.writeChar(0x08);
    try testing.expectEqual(@as(u32, 4), screen.cursor.x);
}

test "BS at column 0 does nothing" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    try screen.writeChar(0x08);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "line wrapping with scroll region" {
    var screen = try Screen.init(testing.allocator, 5, 4);
    defer screen.deinit();

    // Scroll region: lines 1 to 2 inclusive (0-indexed: 0, 1, 2, 3)
    screen.setScrollRegion(1, 2);

    // Position cursor at r[1] (line 2), col 4 (last column)
    screen.cursor.x = 4;
    screen.cursor.y = 2;

    // Write a char to trigger line wrapping.
    try screen.writeChar('A');
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);

    // Write next char to wrap and scroll
    try screen.writeChar('B');
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    // Since cursor.y was at r[1] (2), it should trigger scrollUpInRegion() and remain at y = 2.
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
}

test "line wrapping outside scroll region" {
    var screen = try Screen.init(testing.allocator, 5, 4);
    defer screen.deinit();

    // Scroll region: lines 1 to 2 inclusive (0-indexed: 0, 1, 2, 3)
    screen.setScrollRegion(1, 2);

    // Position cursor at line 3 (below scroll region), col 4 (last column)
    screen.cursor.x = 4;
    screen.cursor.y = 3;

    // Write a char
    try screen.writeChar('A');
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);

    // Write next char to trigger line wrapping.
    try screen.writeChar('B');
    // It should wrap, and either scroll the full grid or clamp, but NOT go out of bounds (y should not be 4).
    try testing.expect(screen.cursor.y < 4);
}

test "useAltScreen saves and restores cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // Position cursor on main screen
    screen.cursor.x = 10;
    screen.cursor.y = 5;
    screen.saveCursor();

    // Enter alt screen
    try screen.useAltScreen(true);

    // Alt screen cursor should be reset to default (0, 0)
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expect(screen.saved_cursor == null);

    // Position cursor on alt screen
    screen.cursor.x = 20;
    screen.cursor.y = 12;

    // Leave alt screen
    try screen.useAltScreen(false);

    // Main screen cursor should be restored
    try testing.expectEqual(@as(u32, 10), screen.cursor.x);
    try testing.expectEqual(@as(u32, 5), screen.cursor.y);
    try testing.expect(screen.saved_cursor != null);
    try testing.expectEqual(@as(u32, 10), screen.saved_cursor.?.x);
    try testing.expectEqual(@as(u32, 5), screen.saved_cursor.?.y);
}

test "scrollUp and scrollDown respect scroll region" {
    var screen = try Screen.init(testing.allocator, 15, 5);
    defer screen.deinit();

    // Populate lines
    try screen.writeStr("0000000000\r\n1111111111\r\n2222222222\r\n3333333333\r\n4444444444");

    // Set scroll region to lines 1..3 inclusive (0-indexed: 1, 2, 3)
    screen.setScrollRegion(1, 3);

    // Scroll up by 1 line inside region
    try screen.scrollUp(1);

    // Line 0 and 4 should be untouched
    try testing.expectEqual(@as(u21, '0'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '4'), screen.grid.getCell(0, 4).char);

    // Region lines (1..3) should be scrolled:
    // old line 2 ("222...") moved to line 1
    // old line 3 ("333...") moved to line 2
    // line 3 cleared (all spaces)
    try testing.expectEqual(@as(u21, '2'), screen.grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '3'), screen.grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 3).char);

    // Scroll down by 1 line inside region
    try screen.scrollDown(1);

    // Line 0 and 4 should be untouched
    try testing.expectEqual(@as(u21, '0'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '4'), screen.grid.getCell(0, 4).char);

    // Region lines (1..3) should be scrolled down:
    // line 1 cleared
    // line 2 gets old line 1 ("222...")
    // line 3 gets old line 2 ("333...")
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '2'), screen.grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, '3'), screen.grid.getCell(0, 3).char);
}

test "writeChar: combining character attaches to previous cell" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar('ก');
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    try testing.expectEqual(@as(u21, 'ก'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u13, 0), screen.grid.getCell(0, 0).comb1);
    try testing.expectEqual(@as(u13, 0), screen.grid.getCell(0, 0).comb2);

    // Thai tone mark (mai ek, U+0E48) — zero-width combining
    try screen.writeChar(0x0E48);
    // Cursor should NOT advance for combining char
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
    // Base cell should now have the combining mark in comb1
    try testing.expectEqual(@as(u21, 'ก'), screen.grid.getCell(0, 0).char);
    try testing.expect(char_width.combiningCodepoint(screen.grid.getCell(0, 0).comb1) == 0x0E48);
    try testing.expectEqual(@as(u13, 0), screen.grid.getCell(0, 0).comb2);
}

test "writeChar: two combining marks stack correctly (Thai ที่)" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar(0x0E17); // ท (tho thahan)
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);

    try screen.writeChar(0x0E35); // ี (sara ii) — first combining
    try testing.expectEqual(@as(u32, 1), screen.cursor.x); // no advance
    try testing.expect(char_width.combiningCodepoint(screen.grid.getCell(0, 0).comb1) == 0x0E35);
    try testing.expectEqual(@as(u13, 0), screen.grid.getCell(0, 0).comb2);

    try screen.writeChar(0x0E48); // ่ (mai ek) — second combining
    try testing.expectEqual(@as(u32, 1), screen.cursor.x); // no advance
    // Both combining marks should be preserved
    try testing.expect(char_width.combiningCodepoint(screen.grid.getCell(0, 0).comb1) == 0x0E35);
    try testing.expect(char_width.combiningCodepoint(screen.grid.getCell(0, 0).comb2) == 0x0E48);
}

test "writeChar: combining char at column 0 is ignored" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    screen.cursor.x = 0;
    try screen.writeChar(0x0E48); // combining mark at x=0
    // Cursor should not move, no cell written
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
}

test "writeChar: wide character writes padding cell" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar(0x4E2D); // CJK ideograph (wide)
    try testing.expectEqual(@as(u32, 2), screen.cursor.x);
    try testing.expectEqual(@as(u21, 0x4E2D), screen.grid.getCell(0, 0).char);
    try testing.expect(!screen.grid.getCell(0, 0).is_padding);

    const pad_cell = screen.grid.getCell(1, 0);
    try testing.expect(pad_cell.is_padding);
}

test "writeChar: combining after wide character" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    try screen.writeChar(0x4E2D); // wide CJK
    try testing.expectEqual(@as(u32, 2), screen.cursor.x);

    try screen.writeChar(0x0301); // combining acute accent
    // Cursor should NOT advance
    try testing.expectEqual(@as(u32, 2), screen.cursor.x);
    // Combining should be on the base wide character, not the padding
    const base_cell = screen.grid.getCell(0, 0);
    try testing.expect(char_width.combiningCodepoint(base_cell.comb1) == 0x0301);
}
