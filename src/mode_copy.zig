const std = @import("std");
const testing = std.testing;
const grid_mod = @import("grid.zig");
const char_width = @import("char_width.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;
const key_mod = @import("key.zig");
const Key = key_mod.Key;

pub const Error = error{
    OutOfMemory,
};

pub const ModeKeys = enum(u8) {
    vi,
    emacs,
};

/// Direction for a copy-mode incremental search.
pub const SearchDir = enum { forward, backward };

pub const Selection = struct {
    start_x: u32 = 0,
    start_y: u32 = 0,
    end_x: u32 = 0,
    end_y: u32 = 0,
    active: bool = false,
    /// Scroll offset at the time the selection was started.
    /// Used to map screen-space coordinates back to grid content
    /// even if the user scrolls after starting the selection.
    start_scroll_offset: u32 = 0,
};

pub const KeyResult = enum { consumed, exit_mode, ignored };

pub const CopyMode = struct {
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    scroll_offset: u32 = 0,
    selection: Selection = .{},
    mode_keys: ModeKeys = .vi,
    active: bool = false,
    /// True while the search prompt is open and accepting input. The actual
    /// query buffer lives in the server's command_buf so it reuses the same
    /// rendering/input path as the command prompt.
    search_active: bool = false,
    /// Direction of the in-progress search prompt.
    search_pending_dir: SearchDir = .forward,
    /// Direction of the last completed search, used by repeat (`n`/`N`).
    last_search_dir: SearchDir = .forward,

    pub fn init(mode_keys: ModeKeys) CopyMode {
        return .{ .mode_keys = mode_keys };
    }

    pub fn enter(self: *CopyMode, grid: *const Grid) void {
        self.active = true;
        self.cursor_x = 0;
        self.cursor_y = grid.height -| 1;
        self.scroll_offset = 0;
        self.selection = .{};
    }

    pub fn exit(self: *CopyMode) void {
        self.active = false;
        self.selection.active = false;
        self.search_active = false;
    }

    /// Open the search prompt in the given direction. The query itself is
    /// collected by the server into its command_buf; CopyMode only tracks
    /// that a search is pending and which way it should go.
    pub fn enterSearch(self: *CopyMode, dir: SearchDir) void {
        self.search_active = true;
        self.search_pending_dir = dir;
    }

    /// Run a search for `query` in `dir` across the full scrollback (history
    /// + visible grid), starting just past the current cursor position.
    /// Returns true if a match was found (cursor is moved to it).
    pub fn submitSearch(self: *CopyMode, grid: *const Grid, allocator: std.mem.Allocator, query: []const u8, dir: SearchDir) bool {
        self.search_active = false;
        self.last_search_dir = dir;
        if (query.len == 0) return false;

        const found = if (dir == .forward)
            self.searchForward(grid, allocator, query)
        else
            self.searchBackward(grid, allocator, query);
        if (found) {
            self.selection = .{};
        }
        return found;
    }

    /// Repeat the last search (used by `n`/`N`). `reverse` flips the
    /// direction relative to the original search. The query is supplied by
    /// the caller (the server keeps the last search string).
    pub fn repeatSearch(self: *CopyMode, grid: *const Grid, allocator: std.mem.Allocator, query: []const u8, reverse: bool) bool {
        if (query.len == 0) return false;
        const dir: SearchDir = if (reverse)
            (if (self.last_search_dir == .forward) .backward else .forward)
        else
            self.last_search_dir;
        const found = if (dir == .forward)
            self.searchForward(grid, allocator, query)
        else
            self.searchBackward(grid, allocator, query);
        if (found) self.selection = .{};
        return found;
    }

    pub fn moveLeft(self: *CopyMode) void {
        if (self.cursor_x > 0) self.cursor_x -= 1;
    }

    pub fn moveRight(self: *CopyMode, grid: *const Grid) void {
        if (self.cursor_x < grid.width -| 1) self.cursor_x += 1;
    }

    pub fn moveUp(self: *CopyMode, grid: *const Grid) void {
        if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        } else if (self.scroll_offset < grid.history.items.len - grid.history_start) {
            self.scroll_offset += 1;
        }
    }

    pub fn moveDown(self: *CopyMode, grid: *const Grid) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        } else if (self.cursor_y < grid.height -| 1) {
            self.cursor_y += 1;
        }
    }

    pub fn moveToLineStart(self: *CopyMode) void {
        self.cursor_x = 0;
    }

    pub fn moveToLineEnd(self: *CopyMode, grid: *const Grid) void {
        self.cursor_x = grid.width -| 1;
    }

    pub fn moveToTop(self: *CopyMode) void {
        self.cursor_y = 0;
        self.cursor_x = 0;
    }

    pub fn moveToBottom(self: *CopyMode, grid: *const Grid) void {
        self.cursor_y = grid.height -| 1;
        self.scroll_offset = 0;
    }

    pub fn pageUp(self: *CopyMode, grid: *const Grid) void {
        const page = grid.height;
        if (self.cursor_y >= page) {
            self.cursor_y -= page;
        } else {
            const remaining = page - self.cursor_y;
            self.cursor_y = 0;
            self.scroll_offset = @min(self.scroll_offset + remaining, @as(u32, @intCast(@as(usize, @min(grid.history.items.len - grid.history_start, std.math.maxInt(u32))))));
        }
    }

    pub fn pageDown(self: *CopyMode, grid: *const Grid) void {
        const page = grid.height;
        if (self.scroll_offset >= page) {
            self.scroll_offset -= page;
        } else {
            const remaining = page - self.scroll_offset;
            self.scroll_offset = 0;
            self.cursor_y = @min(self.cursor_y + remaining, grid.height -| 1);
        }
    }

    pub fn halfPageUp(self: *CopyMode, grid: *const Grid) void {
        const half = grid.height / 2;
        if (self.cursor_y >= half) {
            self.cursor_y -= half;
        } else {
            const remaining = half - self.cursor_y;
            self.cursor_y = 0;
            self.scroll_offset = @min(self.scroll_offset + remaining, @as(u32, @intCast(@as(usize, @min(grid.history.items.len - grid.history_start, std.math.maxInt(u32))))));
        }
    }

    pub fn halfPageDown(self: *CopyMode, grid: *const Grid) void {
        const half = grid.height / 2;
        if (self.scroll_offset >= half) {
            self.scroll_offset -= half;
        } else {
            const remaining = half - self.scroll_offset;
            self.scroll_offset = 0;
            self.cursor_y = @min(self.cursor_y + remaining, grid.height -| 1);
        }
    }

    pub fn startSelection(self: *CopyMode) void {
        self.selection = .{
            .start_x = self.cursor_x,
            .start_y = self.cursor_y,
            .end_x = self.cursor_x,
            .end_y = self.cursor_y,
            .active = true,
            .start_scroll_offset = self.scroll_offset,
        };
    }

    pub fn updateSelection(self: *CopyMode) void {
        if (self.selection.active) {
            self.selection.end_x = self.cursor_x;
            self.selection.end_y = self.cursor_y;
        }
    }

    pub fn adjustSelectionForAutoScroll(self: *CopyMode, delta: i32) void {
        _ = delta;
        self.updateSelection();
    }

    pub fn clearSelection(self: *CopyMode) void {
        self.selection.active = false;
    }

    pub fn isSelected(self: CopyMode, x: u32, y: u32) bool {
        if (!self.selection.active) return false;

        const diff_start = @as(i64, @intCast(self.scroll_offset)) - @as(i64, @intCast(self.selection.start_scroll_offset));

        const sy_i64 = @as(i64, @intCast(self.selection.start_y)) + diff_start;
        const ey_i64 = @as(i64, @intCast(self.selection.end_y));

        const y_i64 = @as(i64, @intCast(y));

        const sy = @min(sy_i64, ey_i64);
        const ey = @max(sy_i64, ey_i64);
        if (y_i64 < sy or y_i64 > ey) return false;

        const start_is_top = (sy == sy_i64);
        const sx = if (start_is_top) self.selection.start_x else self.selection.end_x;
        const ex = if (start_is_top) self.selection.end_x else self.selection.start_x;

        if (sy == ey) {
            const min_x = @min(sx, ex);
            const max_x = @max(sx, ex);
            return x >= min_x and x <= max_x;
        }
        if (y_i64 == sy) {
            return x >= sx;
        }
        if (y_i64 == ey) {
            return x <= ex;
        }
        return true;
    }

    fn getCellAt(self: *const CopyMode, grid: *const Grid, x: u32, screen_y: u32) Cell {
        return self.getCellAtOffset(grid, x, screen_y, self.scroll_offset);
    }

    fn getCellAtOffset(_: *const CopyMode, grid: *const Grid, x: u32, screen_y: u32, scroll_offset: u32) Cell {
        const hist_len = grid.history.items.len - grid.history_start;
        const scroll = @as(usize, @intCast(scroll_offset));
        if (scroll > hist_len) return Cell.empty();

        const combined_idx = (hist_len - scroll) + @as(usize, @intCast(screen_y));

        if (combined_idx < hist_len) {
            const line = &grid.history.items[grid.history_start + combined_idx];
            return if (x < line.cells.items.len) line.cells.items[x] else Cell.empty();
        }

        return grid.getCell(x, @as(u32, @intCast(combined_idx - hist_len)));
    }

    fn isLineWrapped(self: *const CopyMode, grid: *const Grid, screen_y: u32, scroll_offset: u32) bool {
        _ = self;
        const hist_len = grid.history.items.len - grid.history_start;
        const scroll = @as(usize, @intCast(scroll_offset));
        if (scroll > hist_len) return false;

        const combined_idx = (hist_len - scroll) + @as(usize, @intCast(screen_y));

        if (combined_idx < hist_len) {
            return grid.history.items[grid.history_start + combined_idx].wrapped;
        }

        const visible_y = combined_idx - hist_len;
        if (visible_y < grid.lines.items.len) {
            return grid.lines.items[visible_y].wrapped;
        }
        return false;
    }

    fn getCellAtY_i64(self: *const CopyMode, grid: *const Grid, x: u32, y_i64: i64) Cell {
        if (y_i64 < 0) {
            const extra_scroll = @as(u32, @intCast(-y_i64));
            return self.getCellAtOffset(grid, x, 0, self.scroll_offset + extra_scroll);
        } else {
            return self.getCellAtOffset(grid, x, @as(u32, @intCast(y_i64)), self.scroll_offset);
        }
    }

    fn isLineWrappedY_i64(self: *const CopyMode, grid: *const Grid, y_i64: i64) bool {
        if (y_i64 < 0) {
            const extra_scroll = @as(u32, @intCast(-y_i64));
            return self.isLineWrapped(grid, 0, self.scroll_offset + extra_scroll);
        } else {
            return self.isLineWrapped(grid, @as(u32, @intCast(y_i64)), self.scroll_offset);
        }
    }

    pub fn yankSelection(self: *const CopyMode, allocator: std.mem.Allocator, grid: *const Grid) Error![]const u8 {
        if (!self.selection.active) return try allocator.dupe(u8, "");

        const diff_start = @as(i64, @intCast(self.scroll_offset)) - @as(i64, @intCast(self.selection.start_scroll_offset));

        const sy_i64 = @as(i64, @intCast(self.selection.start_y)) + diff_start;
        const ey_i64 = @as(i64, @intCast(self.selection.end_y));

        const sy = @min(sy_i64, ey_i64);
        const ey = @max(sy_i64, ey_i64);
        const start_is_top = (sy == sy_i64);
        const sx = if (start_is_top) self.selection.start_x else self.selection.end_x;
        const ex = if (start_is_top) self.selection.end_x else self.selection.start_x;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var y_i64 = sy;
        while (y_i64 <= ey) : (y_i64 += 1) {
            const line_start = if (y_i64 == sy) sx else 0;
            const line_end = if (y_i64 == ey) @min(ex, grid.width -| 1) else grid.width -| 1;

            const line_pos = result.items.len;
            var x = line_start;
            while (x <= line_end) : (x += 1) {
                const cell = self.getCellAtY_i64(grid, x, y_i64);
                if (cell.is_padding) continue;
                if (cell.char != 0 and cell.char != ' ') {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                        try result.append(allocator, '?');
                        continue;
                    };
                    try result.appendSlice(allocator, buf[0..len]);

                    if (cell.comb1 != 0) {
                        const cp = char_width.combiningCodepoint(cell.comb1);
                        if (cp != 0) {
                            var comb_buf: [4]u8 = undefined;
                            const clen = std.unicode.utf8Encode(cp, &comb_buf) catch 0;
                            if (clen > 0) {
                                try result.appendSlice(allocator, comb_buf[0..clen]);
                            }
                        }
                    }
                    if (cell.comb2 != 0) {
                        const cp = char_width.combiningCodepoint(cell.comb2);
                        if (cp != 0) {
                            var comb_buf: [4]u8 = undefined;
                            const clen = std.unicode.utf8Encode(cp, &comb_buf) catch 0;
                            if (clen > 0) {
                                try result.appendSlice(allocator, comb_buf[0..clen]);
                            }
                        }
                    }
                } else {
                    try result.append(allocator, ' ');
                }
            }

            // Trim trailing spaces by shrinking result
            while (result.items.len > line_pos and result.items[result.items.len - 1] == ' ') {
                result.items.len -= 1;
            }

            const wrapped = self.isLineWrappedY_i64(grid, y_i64);
            if (y_i64 < ey and !wrapped) {
                try result.append(allocator, '\n');
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn searchForward(self: *CopyMode, grid: *const Grid, allocator: std.mem.Allocator, needle: []const u8) bool {
        if (needle.len == 0) return false;

        const hist_len = grid.history.items.len - grid.history_start;
        const total = hist_len + grid.height;
        const cursor_logical = (hist_len -| self.scroll_offset) + self.cursor_y;
        const start_x: usize = self.cursor_x + 1;

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(allocator);

        // Pass 1: from just past the cursor to the end of the scrollback.
        var li = cursor_logical;
        while (li < total) : (li += 1) {
            const start_col: usize = if (li == cursor_logical) start_x else 0;
            if (searchLogicalLine(grid, allocator, &line_buf, &offsets, li, start_col, needle)) |found_x| {
                self.placeCursorAtLogical(grid, li, found_x);
                return true;
            }
        }

        // Pass 2 (cyclic wrap): from the top down to just before the cursor
        // line. Logical lines are disjoint from pass 1, so no re-match.
        li = 0;
        while (li < cursor_logical) : (li += 1) {
            if (searchLogicalLine(grid, allocator, &line_buf, &offsets, li, 0, needle)) |found_x| {
                self.placeCursorAtLogical(grid, li, found_x);
                return true;
            }
        }

        return false;
    }

    pub fn searchBackward(self: *CopyMode, grid: *const Grid, allocator: std.mem.Allocator, needle: []const u8) bool {
        if (needle.len == 0) return false;

        const hist_len = grid.history.items.len - grid.history_start;
        const total = hist_len + grid.height;
        const cursor_logical = (hist_len -| self.scroll_offset) + self.cursor_y;
        const start_x: usize = if (self.cursor_x == 0) 0 else self.cursor_x - 1;

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(allocator);

        // Pass 1: from just before the cursor back to the start.
        var li = cursor_logical;
        while (true) : ({
            if (li == 0) break;
            li -= 1;
        }) {
            const start_col: usize = if (li == cursor_logical) start_x else grid.width -| 1;
            if (searchLogicalLineBackward(grid, allocator, &line_buf, &offsets, li, start_col, needle)) |found_x| {
                self.placeCursorAtLogical(grid, li, found_x);
                return true;
            }
            if (li == 0) break;
        }

        // Pass 2 (cyclic wrap): from the bottom of the scrollback up to the
        // cursor line, not past the cursor's own column.
        li = total -| 1;
        while (li > cursor_logical) : (li -= 1) {
            const start_col: usize = if (li == cursor_logical) start_x else grid.width -| 1;
            if (searchLogicalLineBackward(grid, allocator, &line_buf, &offsets, li, start_col, needle)) |found_x| {
                self.placeCursorAtLogical(grid, li, found_x);
                return true;
            }
        }

        return false;
    }

    /// Map a logical line index + column back to scroll_offset/cursor_y so
    /// the match is visible (history matches pinned to the top of the screen).
    fn placeCursorAtLogical(self: *CopyMode, grid: *const Grid, logical: usize, x: usize) void {
        const hist_len = grid.history.items.len - grid.history_start;
        if (logical < hist_len) {
            self.scroll_offset = @intCast(hist_len - logical);
            self.cursor_y = 0;
        } else {
            self.scroll_offset = 0;
            self.cursor_y = @intCast(logical - hist_len);
        }
        self.cursor_x = @intCast(x);
    }

    /// Build the UTF-8 text of logical line `li` into `out`, then return the
    /// first column >= `start_col` where `needle` occurs, or null. Uses
    /// `std.mem.indexOf` over the line bytes (improvement #3) instead of an
    /// O(n*m) per-cell comparison.
    fn searchLogicalLine(
        grid: *const Grid,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        offsets: *std.ArrayList(usize),
        li: usize,
        start_col: usize,
        needle: []const u8,
    ) ?usize {
        const ncell = lineBytes(grid, allocator, out, offsets, li) orelse return null;
        if (ncell == 0) return null;
        const bytes = out.items;
        // Map the start cell column to its byte offset.
        const byte_start = if (start_col < offsets.items.len) offsets.items[start_col] else bytes.len;
        if (byte_start + needle.len > bytes.len) return null;
        const at = std.mem.indexOf(u8, bytes[byte_start..], needle) orelse return null;
        // Convert the match byte offset back to a cell column.
        return byteToColumn(offsets.items, byte_start + at);
    }

    fn searchLogicalLineBackward(
        grid: *const Grid,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        offsets: *std.ArrayList(usize),
        li: usize,
        start_col: usize,
        needle: []const u8,
    ) ?usize {
        const ncell = lineBytes(grid, allocator, out, offsets, li) orelse return null;
        const bytes = out.items;
        if (ncell == 0 or needle.len > bytes.len) return null;
        const byte_start = if (start_col < offsets.items.len) offsets.items[start_col] else bytes.len;
        var byte_pos = @min(byte_start, bytes.len - needle.len);
        while (true) {
            if (std.mem.eql(u8, bytes[byte_pos .. byte_pos + needle.len], needle)) {
                return byteToColumn(offsets.items, byte_pos);
            }
            if (byte_pos == 0) break;
            byte_pos -= 1;
        }
        return null;
    }

    /// Render logical line `li` (history or visible) into `out` as UTF-8,
    /// reusing `out`'s capacity, and fill `offsets` with the byte offset at
    /// which each cell's char starts (so a byte position can be mapped back
    /// to a cell column — needed for 2-width characters). Returns the number
    /// of cells written.
    fn lineBytes(grid: *const Grid, allocator: std.mem.Allocator, out: *std.ArrayList(u8), offsets: *std.ArrayList(usize), li: usize) ?usize {
        const hist_len = grid.historyLen();
        const total_physical = hist_len + grid.height;
        if (li >= total_physical) return null;

        out.clearRetainingCapacity();
        offsets.clearRetainingCapacity();

        var curr_li = li;
        while (curr_li < total_physical) {
            const line = if (curr_li < hist_len)
                grid.getHistoryLine(curr_li)
            else
                grid.getLine(@intCast(curr_li - hist_len));

            var x: u32 = 0;
            while (x < line.cells.items.len and x < grid.width) : (x += 1) {
                const cell = line.cells.items[x];
                offsets.append(allocator, out.items.len) catch return null;
                if (cell.char == 0) {
                    out.append(allocator, ' ') catch return null;
                    continue;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                    out.append(allocator, ' ') catch return null;
                    continue;
                };
                out.appendSlice(allocator, buf[0..len]) catch return null;
                if (cell.comb1 != 0) {
                    const cp1 = char_width.combiningCodepoint(cell.comb1);
                    if (cp1 != 0) {
                        const l1 = std.unicode.utf8Encode(cp1, &buf) catch 0;
                        if (l1 > 0) out.appendSlice(allocator, buf[0..l1]) catch return null;
                    }
                }
                if (cell.comb2 != 0) {
                    const cp2 = char_width.combiningCodepoint(cell.comb2);
                    if (cp2 != 0) {
                        const l2 = std.unicode.utf8Encode(cp2, &buf) catch 0;
                        if (l2 > 0) out.appendSlice(allocator, buf[0..l2]) catch return null;
                    }
                }
            }

            if (!line.wrapped) break;
            curr_li += 1;
        }

        return offsets.items.len;
    }

    /// Map a byte offset (into `bytes`) to the cell column it falls in, using
    /// the per-cell `offsets` table. `byte_pos` is clamped to the last cell.
    fn byteToColumn(offsets: []const usize, byte_pos: usize) usize {
        var col: usize = 0;
        while (col + 1 < offsets.len and offsets[col + 1] <= byte_pos) {
            col += 1;
        }
        return col;
    }

    pub fn handleKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (!self.active) return .ignored;

        if (self.mode_keys == .vi) {
            return self.handleViKey(k, grid);
        }
        return self.handleEmacsKey(k, grid);
    }

    fn handleViKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (k == .char) {
            const c = k.char;
            if (c.mod.ctrl or c.mod.alt) return .ignored;
            switch (c.code) {
                'h' => {
                    self.moveLeft();
                    self.updateSelection();
                    return .consumed;
                },
                'j' => {
                    self.moveDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'k' => {
                    self.moveUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'l' => {
                    self.moveRight(grid);
                    self.updateSelection();
                    return .consumed;
                },
                '0' => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                '$' => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'g' => {
                    self.moveToTop();
                    self.updateSelection();
                    return .consumed;
                },
                'G' => {
                    self.moveToBottom(grid);
                    self.updateSelection();
                    return .consumed;
                },
                'v' => {
                    if (self.selection.active) {
                        self.clearSelection();
                    } else {
                        self.startSelection();
                    }
                    return .consumed;
                },
                'y' => return .consumed,
                'q' => return .exit_mode,
                else => return .ignored,
            }
        }

        if (k == .arrow) {
            switch (k.arrow.key) {
                .left => {
                    self.moveLeft();
                    self.updateSelection();
                },
                .right => {
                    self.moveRight(grid);
                    self.updateSelection();
                },
                .up => {
                    self.moveUp(grid);
                    self.updateSelection();
                },
                .down => {
                    self.moveDown(grid);
                    self.updateSelection();
                },
            }
            return .consumed;
        }

        if (k == .special) {
            switch (k.special.key) {
                .page_up => {
                    self.pageUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .page_down => {
                    self.pageDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .home => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                .end => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .escape => return .exit_mode,
                else => return .ignored,
            }
        }

        return .ignored;
    }

    fn handleEmacsKey(self: *CopyMode, k: Key, grid: *const Grid) KeyResult {
        if (k == .arrow) {
            switch (k.arrow.key) {
                .left => {
                    self.moveLeft();
                    self.updateSelection();
                },
                .right => {
                    self.moveRight(grid);
                    self.updateSelection();
                },
                .up => {
                    self.moveUp(grid);
                    self.updateSelection();
                },
                .down => {
                    self.moveDown(grid);
                    self.updateSelection();
                },
            }
            return .consumed;
        }

        if (k == .char) {
            const c = k.char;
            if (c.mod.ctrl) {
                switch (c.code) {
                    'P' => {
                        self.pageUp(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'N' => {
                        self.pageDown(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'A' => {
                        self.moveToLineStart();
                        self.updateSelection();
                        return .consumed;
                    },
                    'E' => {
                        self.moveToLineEnd(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    'V' => {
                        self.pageDown(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    else => return .ignored,
                }
            }
            if (c.mod.alt) {
                switch (c.code) {
                    'V' => {
                        self.pageUp(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    '<' => {
                        self.moveToTop();
                        self.updateSelection();
                        return .consumed;
                    },
                    '>' => {
                        self.moveToBottom(grid);
                        self.updateSelection();
                        return .consumed;
                    },
                    else => return .ignored,
                }
            }
        }

        if (k == .special) {
            switch (k.special.key) {
                .page_up => {
                    self.pageUp(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .page_down => {
                    self.pageDown(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .home => {
                    self.moveToLineStart();
                    self.updateSelection();
                    return .consumed;
                },
                .end => {
                    self.moveToLineEnd(grid);
                    self.updateSelection();
                    return .consumed;
                },
                .escape => return .exit_mode,
                else => return .ignored,
            }
        }

        return .ignored;
    }
};

test "copy mode init" {
    const cm = CopyMode.init(.vi);
    try testing.expectEqual(ModeKeys.vi, cm.mode_keys);
    try testing.expect(!cm.active);
}

test "copy mode enter" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    try testing.expect(cm.active);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "copy mode exit" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.exit();
    try testing.expect(!cm.active);
}

test "move left" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    cm.moveLeft();
    try testing.expectEqual(@as(u32, 4), cm.cursor_x);
}

test "move left at column 0" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 0;
    cm.moveLeft();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "move right" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.moveRight(&g);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "move right at last column" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 79;
    cm.moveRight(&g);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "move up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    cm.moveUp(&g);
    try testing.expectEqual(@as(u32, 9), cm.cursor_y);
}

test "move up at top scrolls history" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 5);
    defer g.deinit();

    for (0..10) |_| try g.scrollUp();

    cm.enter(&g);
    cm.cursor_y = 0;
    cm.moveUp(&g);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
    try testing.expectEqual(@as(u32, 1), cm.scroll_offset);
}

test "move down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    cm.moveDown(&g);
    try testing.expectEqual(@as(u32, 11), cm.cursor_y);
}

test "move down at bottom" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 23;
    cm.moveDown(&g);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
}

test "move to line start" {
    var cm = CopyMode.init(.vi);
    cm.cursor_x = 42;
    cm.moveToLineStart();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "move to line end" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.moveToLineEnd(&g);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "move to top" {
    var cm = CopyMode.init(.vi);
    cm.cursor_x = 42;
    cm.cursor_y = 10;
    cm.moveToTop();
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "move to bottom" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.cursor_y = 0;
    cm.moveToBottom(&g);
    try testing.expectEqual(@as(u32, 23), cm.cursor_y);
}

test "page up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    cm.pageUp(&g);
    try testing.expect(cm.cursor_y < 20);
}

test "page down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.scroll_offset = 48;
    cm.cursor_y = 0;
    cm.pageDown(&g);
    try testing.expect(cm.scroll_offset < 48);
}

test "selection start and update" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    cm.cursor_y = 10;
    cm.startSelection();
    try testing.expect(cm.selection.active);
    try testing.expectEqual(@as(u32, 5), cm.selection.start_x);

    cm.cursor_x = 10;
    cm.updateSelection();
    try testing.expectEqual(@as(u32, 10), cm.selection.end_x);
}

test "selection clear" {
    var cm = CopyMode.init(.vi);
    cm.startSelection();
    cm.clearSelection();
    try testing.expect(!cm.selection.active);
}

test "yank selection single line" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'i');

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 1,
        .end_y = 0,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hi", result);
}

test "yank selection wrapped lines merges lines and trims right spaces" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // Line 0 (wrapped): "hello worl"
    g.writeChar(0, 0, 'h');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');
    g.writeChar(5, 0, ' ');
    g.writeChar(6, 0, 'w');
    g.writeChar(7, 0, 'o');
    g.writeChar(8, 0, 'r');
    g.writeChar(9, 0, 'l');
    g.lines.items[0].wrapped = true;

    // Line 1 (not wrapped): "d"
    g.writeChar(0, 1, 'd');

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 1,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "yank selection includes combining characters" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // Write base char 'อ' (0x0E2D)
    g.writeChar(0, 0, 0x0E2D);
    // Write combining sara i 'ิ' (0x0E34) in comb1
    g.lines.items[0].cells.items[0].comb1 = char_width.combiningIndex(0x0E34);

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    // Expected UTF-8: "อิ" (0x0E2D followed by 0x0E34)
    try testing.expectEqualStrings("\xe0\xb8\xad\xe0\xb8\xb4", result);
}

test "yank empty selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "search forward found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, testing.allocator, "ello");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "search forward not found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, testing.allocator, "xyz");
    try testing.expect(!found);
}

test "search backward found" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'H');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');

    cm.cursor_x = 4;
    cm.cursor_y = 0;
    const found = cm.searchBackward(&g, testing.allocator, "Hel");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "vi key h moves left" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 5;
    const result = cm.handleKey(Key{ .char = .{ .code = 'h', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 4), cm.cursor_x);
}

test "vi key j moves down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    const result = cm.handleKey(Key{ .char = .{ .code = 'j', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 11), cm.cursor_y);
}

test "vi key k moves up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    const result = cm.handleKey(Key{ .char = .{ .code = 'k', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 9), cm.cursor_y);
}

test "vi key l moves right" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'l', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 1), cm.cursor_x);
}

test "vi key q exits" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'q', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "vi key v toggles selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    _ = cm.handleKey(Key{ .char = .{ .code = 'v', .mod = .{} } }, &g);
    try testing.expect(cm.selection.active);

    _ = cm.handleKey(Key{ .char = .{ .code = 'v', .mod = .{} } }, &g);
    try testing.expect(!cm.selection.active);
}

test "vi key g moves to top" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 10;
    _ = cm.handleKey(Key{ .char = .{ .code = 'g', .mod = .{} } }, &g);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "vi key escape exits" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .special = .{ .key = .escape, .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "emacs key ctrl-a moves to line start" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_x = 42;
    const result = cm.handleKey(Key{ .char = .{ .code = 'A', .mod = .{ .ctrl = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "emacs key ctrl-e moves to line end" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .char = .{ .code = 'E', .mod = .{ .ctrl = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 79), cm.cursor_x);
}

test "emacs key alt-v page up" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    const result = cm.handleKey(Key{ .char = .{ .code = 'V', .mod = .{ .alt = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expect(cm.cursor_y < 20);
}

test "emacs key alt-< moves to top" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 15;
    const result = cm.handleKey(Key{ .char = .{ .code = '<', .mod = .{ .alt = true } } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .consumed), result);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "emacs key escape exits" {
    var cm = CopyMode.init(.emacs);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    const result = cm.handleKey(Key{ .special = .{ .key = .escape, .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .exit_mode), result);
}

test "handle key when not active returns ignored" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    const result = cm.handleKey(Key{ .char = .{ .code = 'h', .mod = .{} } }, &g);
    try testing.expectEqual(@as(@TypeOf(result), .ignored), result);
}

test "half page up" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.cursor_y = 20;
    cm.halfPageUp(&g);
    try testing.expect(cm.cursor_y < 20);
}

test "half page down" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 80, 24);
    defer g.deinit();

    cm.enter(&g);
    cm.scroll_offset = 24;
    cm.cursor_y = 0;
    cm.halfPageDown(&g);
    try testing.expect(cm.scroll_offset < 24);
}

test "yank multi-line selection" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    g.writeChar(0, 0, 'A');
    g.writeChar(0, 1, 'B');

    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 1,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "A") != null);
    try testing.expect(std.mem.indexOf(u8, result, "B") != null);
}

test "yank selection reverse (bottom-to-top) bounds" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 5, 2);
    defer g.deinit();

    g.writeChar(0, 0, 'A');
    g.writeChar(1, 0, 'B');
    g.writeChar(2, 0, 'C');
    g.writeChar(3, 0, 'D');
    g.writeChar(4, 0, 'E');
    g.writeChar(0, 1, 'F');
    g.writeChar(1, 1, 'G');
    g.writeChar(2, 1, 'H');
    g.writeChar(3, 1, 'I');
    g.writeChar(4, 1, 'J');

    // Reverse selection: start at (3,1), end at (1,0)
    // Should yank the same as forward selection (1,0)->(3,1): BCD + FGHI = "BCDFGHI"
    cm.selection = .{
        .start_x = 3,
        .start_y = 1,
        .end_x = 1,
        .end_y = 0,
        .active = true,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    // Reverse selection from (3,1) to (1,0) should yank the same
    // range as forward selection (1,0) to (3,1): line0 cols 1-4,
    // line1 cols 0-3 => "BCDE\nFGHI"
    try testing.expectEqualStrings("BCDE\nFGHI", result);
}

test "yank selection from scrolled-back history" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // Write content at top row that will scroll into history
    g.writeChar(0, 0, 'X');
    g.writeChar(1, 0, 'Y');
    g.writeChar(2, 0, 'Z');

    // Push that row into history, filling visible with empty lines
    _ = try g.scrollUp();

    // Write more content that also scrolls away
    g.writeChar(0, 0, '1');
    g.writeChar(1, 0, '2');
    _ = try g.scrollUp();
    g.writeChar(0, 0, '3');
    g.writeChar(1, 0, '4');
    _ = try g.scrollUp();

    // history now has 3 lines: [XYZ], [12], [34]
    // visible grid is empty
    try testing.expectEqual(@as(usize, 3), g.history.items.len);

    // Scroll back to see the first history line at screen_y=0
    cm.scroll_offset = 3; // show history[0] at screen_y=0
    cm.selection = .{
        .start_x = 0,
        .start_y = 0,
        .end_x = 2,
        .end_y = 0,
        .active = true,
        .start_scroll_offset = 3,
    };

    const result = try cm.yankSelection(testing.allocator, &g);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("XYZ", result);
}

test "search forward empty needle" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchForward(&g, testing.allocator, "");
    try testing.expect(!found);
}

test "search backward empty needle" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchBackward(&g, testing.allocator, "");
    try testing.expect(!found);
}

test "search respects 2-width characters (byte offset != cell column)" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 1);
    defer g.deinit();

    // Cell 0 holds a 2-width char '世' (3 UTF-8 bytes, occupies cols 0-1).
    // Cell 1 is its spacing continuation. Cell 2 holds 'o'.
    g.writeChar(0, 0, '世');
    g.writeChar(2, 0, 'o');

    cm.cursor_x = 0;
    cm.cursor_y = 0;
    // Search for "o": it sits at cell column 2. A naive byte-offset cursor
    // would land at byte 3 (wrong cell), so we assert the correct column.
    const found = cm.searchForward(&g, testing.allocator, "o");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 2), cm.cursor_x);
}

test "search backward into history" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // Fill three rows with distinct markers, then scroll them into history
    // by scrolling up twice (each scrollUp moves the top visible line to
    // history and reveals a fresh empty line at the bottom).
    g.writeChar(0, 0, 'A');
    g.writeChar(1, 0, 'B');
    g.writeChar(2, 0, 'C');
    g.writeChar(0, 1, 'D');
    g.writeChar(0, 2, 'E');

    try g.scrollUp();
    try g.scrollUp();

    // Cursor sits on the freshly revealed bottom line; search backward should
    // reach into the history lines that now hold A/B/C/D.
    cm.cursor_x = 0;
    cm.cursor_y = 0;
    const found = cm.searchBackward(&g, testing.allocator, "ABC");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "forward search wraps cyclically from the bottom" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // "foo" only exists on the top line; cursor starts at the bottom line
    // (copy mode default), so a non-cyclic search would fail. It must wrap
    // to the top.
    g.writeChar(0, 0, 'f');
    g.writeChar(1, 0, 'o');
    g.writeChar(2, 0, 'o');

    cm.enter(&g); // cursor at bottom line, cursor_y == height-1
    try testing.expectEqual(@as(u32, 2), cm.cursor_y);
    const found = cm.searchForward(&g, testing.allocator, "foo");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
}

test "search matches Thai base + tone mark (combining mark)" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // 'ที่' = THO THAHAN (U+0E17) with MAI EK tone mark (U+0E48), which the
    // grid stores as cell.char = 0x0E17, cell.comb1 = combiningIndex(0x0E48).
    // lineBytes must emit the combining mark too, or a query that includes it
    // (as a Thai IME produces) would never match.
    g.writeChar(0, 0, 0x0E17);
    g.getLine(0).cells.items[0].comb1 = char_width.combiningIndex(0x0E48);

    // Place the cursor on the bottom line so forward search wraps to the top.
    cm.enter(&g);
    try testing.expectEqual(@as(u32, 2), cm.cursor_y);

    var needle: [8]u8 = undefined;
    var npos: usize = 0;
    for ([_]u21{ 0x0E17, 0x0E48 }) |cp| {
        var tmp: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
        @memcpy(needle[npos..][0..l], tmp[0..l]);
        npos += l;
    }
    const found = cm.searchForward(&g, testing.allocator, needle[0..npos]);
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "search matches Thai word with vowel + tone marks" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 10, 3);
    defer g.deinit();

    // 'สวัสดี' = ส(0E2A) วั(0E27+0E31) ส(0E2A) ดี(0E14+0E35)
    // Vowel signs are stored in comb1 of their base cell.
    g.writeChar(0, 0, 0x0E2A);
    g.writeChar(1, 0, 0x0E27);
    g.getLine(0).cells.items[1].comb1 = char_width.combiningIndex(0x0E31);
    g.writeChar(2, 0, 0x0E2A);
    g.writeChar(3, 0, 0x0E14);
    g.getLine(0).cells.items[3].comb1 = char_width.combiningIndex(0x0E35);

    cm.enter(&g); // cursor at bottom line
    try testing.expectEqual(@as(u32, 2), cm.cursor_y);

    // Build the UTF-8 query exactly as a Thai IME would: base + combining.
    var needle: [40]u8 = undefined;
    var npos: usize = 0;
    for ([_]u21{ 0x0E2A, 0x0E27, 0x0E31, 0x0E2A, 0x0E14, 0x0E35 }) |cp| {
        var tmp: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
        @memcpy(needle[npos..][0..l], tmp[0..l]);
        npos += l;
    }
    const found = cm.searchForward(&g, testing.allocator, needle[0..npos]);
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 0), cm.cursor_x);
    try testing.expectEqual(@as(u32, 0), cm.cursor_y);
}

test "searchForward across soft-wrapped line boundaries — bug #234" {
    var cm = CopyMode.init(.vi);
    var g = try Grid.init(testing.allocator, 5, 3);
    defer g.deinit();

    // Write "hello" on line 0 (width 5), set wrapped=true, write "world" on line 1
    g.writeChar(0, 0, 'h');
    g.writeChar(1, 0, 'e');
    g.writeChar(2, 0, 'l');
    g.writeChar(3, 0, 'l');
    g.writeChar(4, 0, 'o');
    g.getLineMut(0).wrapped = true;

    g.writeChar(0, 1, 'w');
    g.writeChar(1, 1, 'o');
    g.writeChar(2, 1, 'r');
    g.writeChar(3, 1, 'l');
    g.writeChar(4, 1, 'd');

    cm.cursor_x = 0;
    cm.cursor_y = 0;

    // Search for "lowo" which spans the wrap point between "hello" and "world"
    const found = cm.searchForward(&g, testing.allocator, "lowo");
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 3), cm.cursor_x);
}
