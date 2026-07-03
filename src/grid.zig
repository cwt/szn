const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const char_width = @import("char_width.zig");
const thai = @import("thai.zig");
const Colour = colour.Colour;

pub const Error = error{OutOfMemory};

pub const Attr = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    concealed: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    double_underline: bool = false,
    curly_underline: bool = false,
    _padding: u5 = 0,
};

pub const Cell = packed struct(u128) {
    char: u21,
    comb1: u13 = 0,
    comb2: u13 = 0,
    attr: Attr,
    fg: Colour,
    bg: Colour,
    is_padding: bool = false,

    pub fn empty() Cell {
        return .{
            .char = 0,
            .attr = .{},
            .fg = Colour.default_(),
            .bg = Colour.default_(),
        };
    }

    pub fn withChar(c: u21) Cell {
        var cell = Cell.empty();
        cell.char = c;
        return cell;
    }

    pub fn eql(self: Cell, other: Cell) bool {
        return @as(u128, @bitCast(self)) == @as(u128, @bitCast(other));
    }
};

pub const GridLine = struct {
    cells: std.ArrayListUnmanaged(Cell) = .empty,
    dirty: bool = true,
    /// True when this line is a soft-wrap continuation from the previous line.
    /// Used by reflow to reconstruct logical lines.
    wrapped: bool = false,

    pub fn deinit(self: *GridLine, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
    }
};

pub const CursorPos = struct { line_idx: usize, col_idx: usize };

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    lines: std.ArrayListUnmanaged(GridLine) = .empty,
    history: std.ArrayListUnmanaged(GridLine) = .empty,
    history_limit: u32 = 2000,
    start_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Grid {
        return initWithLimit(allocator, width, height, 2000);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, width: u32, height: u32, history_limit: u32) Error!Grid {
        var grid = Grid{
            .allocator = allocator,
            .width = width,
            .height = height,
            .history_limit = history_limit,
            .start_index = 0,
        };
        try grid.lines.ensureTotalCapacity(allocator, height);
        try grid.resize(height);
        return grid;
    }

    pub fn getLine(self: *const Grid, y: u32) *const GridLine {
        const idx = (self.start_index + y) % self.height;
        return &self.lines.items[idx];
    }

    pub fn getLineMut(self: *Grid, y: u32) *GridLine {
        const idx = (self.start_index + y) % self.height;
        return &self.lines.items[idx];
    }

    pub fn normalize(self: *Grid) !void {
        if (self.start_index == 0 or self.height == 0) return;
        std.mem.rotate(GridLine, self.lines.items[0..self.height], self.start_index);
        self.start_index = 0;
    }

    pub fn deinit(self: *Grid) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        for (self.history.items) |*line| line.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    pub fn clone(self: *const Grid, allocator: std.mem.Allocator) Error!Grid {
        var copy = Grid{
            .allocator = allocator,
            .width = self.width,
            .height = self.height,
            .history_limit = self.history_limit,
            .start_index = self.start_index,
        };
        try copy.lines.ensureTotalCapacity(allocator, self.lines.items.len);
        errdefer {
            for (copy.lines.items) |*l| l.deinit(allocator);
            copy.lines.deinit(allocator);
        }
        for (self.lines.items) |line| {
            var new_line = GridLine{ .dirty = line.dirty, .wrapped = line.wrapped };
            try new_line.cells.appendSlice(allocator, line.cells.items);
            try copy.lines.append(allocator, new_line);
        }
        try copy.history.ensureTotalCapacity(allocator, self.history.items.len);
        errdefer {
            for (copy.history.items) |*l| l.deinit(allocator);
            copy.history.deinit(allocator);
        }
        for (self.history.items) |line| {
            var new_line = GridLine{ .dirty = line.dirty, .wrapped = line.wrapped };
            try new_line.cells.appendSlice(allocator, line.cells.items);
            try copy.history.append(allocator, new_line);
        }
        return copy;
    }

    pub fn resize(self: *Grid, new_height: u32) Error!void {
        if (new_height == 0) return;
        try self.normalize();
        while (self.lines.items.len < new_height) {
            var line = GridLine{};
            try line.cells.resize(self.allocator, self.width);
            @memset(line.cells.items, Cell.empty());
            try self.lines.append(self.allocator, line);
        }
        while (self.lines.items.len > new_height) {
            var line = self.lines.pop().?;
            line.deinit(self.allocator);
        }
        self.height = new_height;
    }

    pub fn setSize(self: *Grid, new_width: u32, new_height: u32) Error!void {
        try self.setSizeCursor(new_width, new_height, null, null, null, null);
    }

    pub fn setSizeCursor(
        self: *Grid,
        new_width: u32,
        new_height: u32,
        cursor_x: ?u32,
        cursor_y: ?u32,
        out_cursor_x: ?*u32,
        out_cursor_y: ?*u32,
    ) Error!void {
        if (new_width != self.width) {
            try self.reflowCursor(new_width, cursor_x, cursor_y, out_cursor_x, out_cursor_y);
        }
        try self.resize(new_height);
    }

    pub fn setCell(self: *Grid, x: u32, y: u32, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const line = self.getLineMut(y);
        line.cells.items[x] = cell;
        line.dirty = true;
    }

    pub fn getCell(self: *const Grid, x: u32, y: u32) Cell {
        if (x >= self.width or y >= self.height) return Cell.empty();
        return self.getLine(y).cells.items[x];
    }

    pub fn writeChar(self: *Grid, x: u32, y: u32, char: u21) void {
        self.setCell(x, y, Cell.withChar(char));
    }

    pub fn scrollUp(self: *Grid) Error!void {
        if (self.height == 0) return;

        var new_line = GridLine{};
        try new_line.cells.resize(self.allocator, self.width);
        @memset(new_line.cells.items, Cell.empty());

        var old_line = self.getLineMut(0).*;
        old_line.dirty = false;
        self.getLineMut(0).* = new_line;

        errdefer old_line.deinit(self.allocator);
        try self.history.append(self.allocator, old_line);
        if (self.history.items.len > self.history_limit) {
            if (self.history_limit > 64) {
                if (self.history.items.len > self.history_limit + 64) {
                    const num_to_remove = self.history.items.len - self.history_limit;
                    for (self.history.items[0..num_to_remove]) |*old| {
                        old.deinit(self.allocator);
                    }
                    std.mem.copyForwards(GridLine, self.history.items[0 .. self.history.items.len - num_to_remove], self.history.items[num_to_remove..]);
                    self.history.items.len -= num_to_remove;
                }
            } else {
                var old = self.history.orderedRemove(0);
                old.deinit(self.allocator);
            }
        }

        self.start_index = (self.start_index + 1) % self.height;
    }

    pub fn scrollDown(self: *Grid) Error!void {
        if (self.height == 0 or self.history.items.len == 0) return;
        var line = self.history.pop().?;
        errdefer line.deinit(self.allocator);

        self.getLineMut(self.height - 1).deinit(self.allocator);
        self.start_index = (self.start_index + self.height - 1) % self.height;
        self.getLineMut(0).* = line;
    }

    pub fn clearLine(self: *Grid, y: u32) void {
        if (y >= self.height) return;
        var line = self.getLineMut(y);
        @memset(line.cells.items, Cell.empty());
        line.wrapped = false;
        line.dirty = true;
    }

    pub fn insertLine(self: *Grid, y: u32) Error!void {
        if (y >= self.height) return;
        const temp = self.getLine(self.height - 1).*;
        var i = self.height - 1;
        while (i > y) : (i -= 1) {
            self.getLineMut(i).* = self.getLine(i - 1).*;
        }
        self.getLineMut(y).* = temp;
        @memset(self.getLineMut(y).cells.items, Cell.empty());
        self.getLineMut(y).wrapped = false;
        self.getLineMut(y).dirty = true;
    }

    pub fn deleteLine(self: *Grid, y: u32) Error!void {
        if (y >= self.height) return;
        const temp = self.getLine(y).*;
        var i = y;
        while (i < self.height - 1) : (i += 1) {
            self.getLineMut(i).* = self.getLine(i + 1).*;
        }
        self.getLineMut(self.height - 1).* = temp;
        @memset(self.getLineMut(self.height - 1).cells.items, Cell.empty());
        self.getLineMut(self.height - 1).wrapped = false;
        self.getLineMut(self.height - 1).dirty = true;
    }

    pub fn insertChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const num = @min(n, self.width -| x);
        if (num == 0) return;
        const line = self.getLineMut(y);
        var i = self.width - 1;
        while (i >= x + num) : (i -= 1) {
            line.cells.items[i] = line.cells.items[i - num];
        }
        const end = @min(x + num, self.width);
        for (x..end) |col| {
            line.cells.items[col] = Cell.empty();
        }
        line.dirty = true;
    }

    pub fn deleteChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const num = @min(n, self.width -| x);
        if (num == 0) return;
        const line = self.getLineMut(y);
        var i = x;
        while (i + num < self.width) : (i += 1) {
            line.cells.items[i] = line.cells.items[i + num];
        }
        while (i < self.width) : (i += 1) {
            line.cells.items[i] = Cell.empty();
        }
        line.dirty = true;
    }

    pub fn eraseChars(self: *Grid, x: u32, y: u32, n: u32) void {
        if (y >= self.height) return;
        const line = self.getLineMut(y);
        const end = @min(x + n, self.width);
        if (x < end) {
            @memset(line.cells.items[x..end], Cell.empty());
            line.dirty = true;
        }
    }

    pub fn clearArea(self: *Grid, sx: u32, sy: u32, ex: u32, ey: u32) void {
        var y = sy;
        while (y <= ey and y < self.height) : (y += 1) {
            const line = self.getLineMut(y);
            const x = if (y == sy) sx else 0;
            const max_x = if (y == ey) @min(ex, self.width - 1) else self.width - 1;
            if (x <= max_x) {
                @memset(line.cells.items[x .. max_x + 1], Cell.empty());
                line.dirty = true;
            }
        }
    }

    pub fn clear(self: *Grid) void {
        for (0..self.height) |y| {
            self.clearLine(@intCast(y));
        }
    }

    pub fn isEmpty(self: *const Grid) bool {
        for (self.lines.items) |*line| {
            for (line.cells.items) |cell| {
                if (cell.char != 0) return false;
            }
        }
        return true;
    }

    pub fn isDirty(self: *const Grid) bool {
        for (self.lines.items) |*line| {
            if (line.dirty) return true;
        }
        return false;
    }

    pub fn clearDirty(self: *Grid) void {
        for (self.lines.items) |*line| {
            line.dirty = false;
        }
    }

    /// Returns the index after the last cell in the visual cluster at `start`.
    /// Handles Thai clusters (leading vowel + base + following vowel + attaching),
    /// CJK wide char + padding pairs, and regular single cells.
    fn findClusterEnd(cells: []const Cell, start: usize) usize {
        const cp = cells[start].char;
        if (cp == ' ' and cells[start].is_padding) return start + 1;
        if (thai.isThai(cp)) return thai.findThaiClusterEnd(cells, start);
        if (char_width.charWidth(cp) == 2) return @min(start + 2, cells.len);
        return start + 1;
    }

    /// Returns the display width of a cluster spanning `cells[0..end)`.
    fn clusterWidth(cells: []const Cell) u32 {
        var w: u32 = 0;
        for (cells) |c| {
            if (c.is_padding) continue;
            w += if (c.char == ' ') 1 else char_width.charWidth(c.char);
        }
        return w;
    }

    fn isNumberChar(cp: u21) bool {
        return (cp >= '0' and cp <= '9') or cp == ',' or cp == '.';
    }

    /// Rewrap a flat cell sequence (one logical line) to `new_width`.
    /// Returns owned slice of GridLine. Lines that wrap to the next physical
    /// line have wrapped=true; the last line of each rewrapped group is false.
    fn rewrap(
        cells: []const Cell,
        new_width: u32,
        allocator: std.mem.Allocator,
        cursor_offset: ?usize,
        out_cursor_pos: ?*CursorPos,
    ) ![]GridLine {
        var lines: std.ArrayListUnmanaged(GridLine) = .empty;
        errdefer {
            for (lines.items) |*l| l.deinit(allocator);
            lines.deinit(allocator);
        }

        const word_breaks = try thai.findWordBreaks(allocator, cells);
        defer allocator.free(word_breaks);

        if (cells.len == 0) {
            var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
            try line_cells.resize(allocator, new_width);
            @memset(line_cells.items, Cell.empty());
            var gl = GridLine{ .dirty = true, .wrapped = false };
            gl.cells = line_cells;
            try lines.append(allocator, gl);
            if (cursor_offset) |co| {
                if (co == 0) {
                    if (out_cursor_pos) |ocp| {
                        ocp.line_idx = 0;
                        ocp.col_idx = 0;
                    }
                }
            }
            return lines.toOwnedSlice(allocator);
        }

        var i: usize = 0;
        while (i < cells.len) {
            const line_start = i;
            var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
            defer line_cells.deinit(allocator);
            var line_width: u32 = 0;
            var did_break = false;

            var last_cluster_start: usize = i;

            while (i < cells.len) {
                const cluster_end = findClusterEnd(cells, i);
                const cw = clusterWidth(cells[i..cluster_end]);
                if (line_width > 0 and line_width + cw > new_width) {
                    did_break = true;

                    // Number breaking rule:
                    // If we are breaking inside a number (digits, commas, periods),
                    // check the length of the number.
                    if (isNumberChar(cells[i - 1].char) and isNumberChar(cells[i].char)) {
                        var start_idx = i - 1;
                        while (start_idx > line_start and isNumberChar(cells[start_idx - 1].char)) {
                            start_idx -= 1;
                        }
                        var end_idx = i;
                        while (end_idx < cells.len and isNumberChar(cells[end_idx].char)) {
                            end_idx += 1;
                        }
                        const num_len = end_idx - start_idx;
                        if (num_len <= 6) {
                            if (start_idx > line_start) {
                                i = start_idx;
                                line_cells.shrinkRetainingCapacity(start_idx - line_start);
                                break;
                            }
                        } else {
                            // Long number: search for the last comma on the current line
                            var comma_idx: ?usize = null;
                            var scan_idx = i;
                            while (scan_idx > start_idx) {
                                scan_idx -= 1;
                                if (cells[scan_idx].char == ',') {
                                    comma_idx = scan_idx;
                                    break;
                                }
                            }
                            if (comma_idx) |ci| {
                                if (ci + 1 > line_start) {
                                    i = ci + 1;
                                    line_cells.shrinkRetainingCapacity(ci + 1 - line_start);
                                    break;
                                }
                            }
                        }
                    }

                    // If libthai returned word boundaries, use them to break at a valid boundary.
                    var found_wb: ?usize = null;
                    if (word_breaks.len > 0) {
                        for (word_breaks) |wb| {
                            if (wb > line_start and wb <= i) {
                                // Only wrap if this boundary borders a Thai character or space adjacent to a Thai word
                                const is_thai_boundary = blk: {
                                    if (thai.isThai(cells[wb - 1].char) or (wb < cells.len and thai.isThai(cells[wb].char))) {
                                        break :blk true;
                                    }
                                    if (cells[wb - 1].char == ' ' and wb >= 2 and thai.isThai(cells[wb - 2].char)) {
                                        break :blk true;
                                    }
                                    if (wb < cells.len and cells[wb].char == ' ' and wb + 1 < cells.len and thai.isThai(cells[wb + 1].char)) {
                                        break :blk true;
                                    }
                                    break :blk false;
                                };
                                if (is_thai_boundary) {
                                    found_wb = wb;
                                }
                            }
                        }
                    }

                    // A space character bordering a Thai character is also a valid word boundary.
                    var space_wb: ?usize = null;
                    if (cells[i].char == ' ' and !cells[i].is_padding) {
                        if (i > 0 and thai.isThai(cells[i - 1].char)) {
                            space_wb = i;
                        }
                    } else {
                        var j = i;
                        while (j > line_start) {
                            j -= 1;
                            if (cells[j].char == ' ' and !cells[j].is_padding) {
                                const borders_thai = blk: {
                                    if (j > 0 and thai.isThai(cells[j - 1].char)) break :blk true;
                                    if (j + 1 < cells.len and thai.isThai(cells[j + 1].char)) break :blk true;
                                    break :blk false;
                                };
                                if (borders_thai) {
                                    space_wb = j + 1;
                                    break;
                                }
                            }
                        }
                    }

                    if (space_wb) |wb| {
                        if (wb <= line_start + 1) {
                            space_wb = null;
                        }
                    }

                    const final_wb = @max(found_wb orelse 0, space_wb orelse 0);
                    if (final_wb > 0) {
                        i = final_wb;
                        line_cells.shrinkRetainingCapacity(final_wb - line_start);
                        break;
                    }

                    // MAI HAN AKAT rule: if the last added cluster contains MAI HAN AKAT,
                    // we cannot break the line right after it. Backtrack to before that cluster.
                    var has_mai_han_akat = false;
                    var k = last_cluster_start;
                    while (k < i) : (k += 1) {
                        if (thai.cellHasMaiHanAkat(cells[k])) {
                            has_mai_han_akat = true;
                            break;
                        }
                    }

                    if (has_mai_han_akat and last_cluster_start > line_start) {
                        i = last_cluster_start;
                        line_cells.shrinkRetainingCapacity(last_cluster_start - line_start);
                        break;
                    }

                    // Look-ahead heuristic: if breaking would leave a single Thai consonant
                    // at the start of the next line, followed immediately by a leading vowel,
                    // backtrack to the start of the word (the leading vowel of the current syllable).
                    if (cluster_end == i + 1 and thai.isThai(cells[i].char) and !thai.isThaiLeadingVowel(cells[i].char)) {
                        const next_idx = cluster_end;
                        if (next_idx < cells.len and thai.isThaiLeadingVowel(cells[next_idx].char)) {
                            var j = i;
                            var found_vowel_idx: ?usize = null;
                            var first_thai_idx = i;
                            while (j > line_start) {
                                j -= 1;
                                const cp = cells[j].char;
                                if (!thai.isThai(cp)) {
                                    break;
                                }
                                first_thai_idx = j;
                                if (thai.isThaiLeadingVowel(cp)) {
                                    found_vowel_idx = j;
                                    break;
                                }
                            }
                            const break_idx = found_vowel_idx orelse first_thai_idx;
                            if (break_idx > line_start) {
                                i = break_idx;
                                line_cells.shrinkRetainingCapacity(break_idx - line_start);
                            }
                        }
                    }
                    break;
                }
                last_cluster_start = i;
                try line_cells.appendSlice(allocator, cells[i..cluster_end]);
                line_width += cw;
                i = cluster_end;
            }

            if (cursor_offset) |co| {
                if (co >= line_start and (co < i or (co == i and i == cells.len))) {
                    if (out_cursor_pos) |ocp| {
                        ocp.line_idx = lines.items.len;
                        ocp.col_idx = co - line_start;
                    }
                }
            }

            // Pad to new_width
            while (line_cells.items.len < new_width) {
                try line_cells.append(allocator, Cell.empty());
            }

            var gl = GridLine{ .dirty = true, .wrapped = did_break };
            try gl.cells.appendSlice(allocator, line_cells.items);
            try lines.append(allocator, gl);
        }

        return lines.toOwnedSlice(allocator);
    }

    /// Reflow the grid content to `new_width`, respecting Thai cluster, CJK
    /// wide-char, and soft-wrap boundaries. All content (visible + history)
    /// is reflowed.
    pub fn reflow(self: *Grid, new_width: u32) !void {
        try self.reflowCursor(new_width, null, null, null, null);
    }

    pub fn reflowCursor(
        self: *Grid,
        new_width: u32,
        cursor_x: ?u32,
        cursor_y: ?u32,
        out_cursor_x: ?*u32,
        out_cursor_y: ?*u32,
    ) !void {
        try self.reflowCursorInternal(new_width, cursor_x, cursor_y, out_cursor_x, out_cursor_y, false);
    }

    pub fn forceReflowCursor(
        self: *Grid,
        cursor_x: ?u32,
        cursor_y: ?u32,
        out_cursor_x: ?*u32,
        out_cursor_y: ?*u32,
    ) !void {
        try self.reflowCursorInternal(self.width, cursor_x, cursor_y, out_cursor_x, out_cursor_y, true);
    }

    fn reflowCursorInternal(
        self: *Grid,
        new_width: u32,
        cursor_x: ?u32,
        cursor_y: ?u32,
        out_cursor_x: ?*u32,
        out_cursor_y: ?*u32,
        force: bool,
    ) !void {
        if (!force and new_width == self.width) return;
        if (new_width == 0) return;

        try self.normalize();

        const total = self.history.items.len + self.lines.items.len;

        // Find the last non-empty line to avoid treating trailing empty lines as content.
        var last_non_empty: usize = 0;
        var found_non_empty = false;
        var j = total;
        while (j > 0) {
            j -= 1;
            const line = if (j < self.history.items.len)
                &self.history.items[j]
            else
                &self.lines.items[j - self.history.items.len];

            if (line.wrapped) {
                last_non_empty = j;
                found_non_empty = true;
                break;
            }
            var has_content = false;
            for (line.cells.items) |c| {
                if (c.char != 0 or c.is_padding or c.comb1 != 0 or c.comb2 != 0) {
                    has_content = true;
                    break;
                }
            }
            if (has_content) {
                last_non_empty = j;
                found_non_empty = true;
                break;
            }
        }
        var process_limit = if (found_non_empty) last_non_empty + 1 else 0;
        if (cursor_y) |cy| {
            const cursor_logical_y = cy + self.history.items.len;
            if (cursor_logical_y < total) {
                if (process_limit < cursor_logical_y + 1) {
                    process_limit = cursor_logical_y + 1;
                }
            }
        }

        // ── Flatten all lines into logical lines ──
        var flat_cells: std.ArrayListUnmanaged(Cell) = .empty;
        defer flat_cells.deinit(self.allocator);

        const Span = struct { start: usize, len: usize };
        var logical_spans: std.ArrayListUnmanaged(Span) = .empty;
        defer logical_spans.deinit(self.allocator);

        const allocator = self.allocator;
        var idx: usize = 0;
        var cursor_logical_line: ?usize = null;
        var cursor_offset_in_logical: ?usize = null;

        while (idx < process_limit) {
            const start_idx = flat_cells.items.len;
            var line_idx = idx;

            var is_cursor_logical_line = false;
            var cursor_offset_in_this_logical: usize = 0;
            var current_offset: usize = 0;

            while (line_idx < total) : (line_idx += 1) {
                const line = if (line_idx < self.history.items.len)
                    &self.history.items[line_idx]
                else
                    &self.lines.items[line_idx - self.history.items.len];

                var cells_to_add = line.cells.items;
                // Trim trailing unwritten cells from all lines to remove padding
                while (cells_to_add.len > 0) {
                    const last = cells_to_add[cells_to_add.len - 1];
                    if (last.char == 0) {
                        cells_to_add = cells_to_add[0 .. cells_to_add.len - 1];
                    } else break;
                }

                if (cursor_y != null and line_idx == cursor_y.? + self.history.items.len) {
                    is_cursor_logical_line = true;
                    cursor_offset_in_this_logical = current_offset + @min(cursor_x.?, cells_to_add.len);
                }

                try flat_cells.appendSlice(allocator, cells_to_add);
                current_offset += cells_to_add.len;
                if (!line.wrapped) {
                    line_idx += 1;
                    break;
                }
            }
            idx = line_idx;

            // Final trim of trailing unwritten cells
            while (flat_cells.items.len > start_idx) {
                const last = flat_cells.items[flat_cells.items.len - 1];
                if (last.char == 0) {
                    _ = flat_cells.pop();
                } else break;
            }

            const current_logical_idx = logical_spans.items.len;
            if (is_cursor_logical_line) {
                cursor_logical_line = current_logical_idx;
                cursor_offset_in_logical = cursor_offset_in_this_logical;
            }

            try logical_spans.append(allocator, Span{
                .start = start_idx,
                .len = flat_cells.items.len - start_idx,
            });
        }

        // ── Save and replace old lines ──
        var old_lines = self.lines;
        var old_history = self.history;
        self.lines = .empty;
        self.history = .empty;

        // ── Rewrap each logical line and build new line set ──
        var new_lines: std.ArrayListUnmanaged(GridLine) = .empty;
        errdefer {
            for (new_lines.items) |*l| l.deinit(allocator);
            new_lines.deinit(allocator);
        }

        var new_cursor_logical_line: ?usize = null;
        var new_cursor_offset_on_line: ?usize = null;

        for (logical_spans.items, 0..) |span, logical_line_idx| {
            var rewrap_cursor_pos = CursorPos{ .line_idx = 0, .col_idx = 0 };
            const has_cursor = (cursor_logical_line != null and cursor_logical_line.? == logical_line_idx);

            const flat = flat_cells.items[span.start .. span.start + span.len];

            const rewrapped = try rewrap(
                flat,
                new_width,
                allocator,
                if (has_cursor) cursor_offset_in_logical else null,
                if (has_cursor) &rewrap_cursor_pos else null,
            );

            if (has_cursor) {
                new_cursor_logical_line = new_lines.items.len + rewrap_cursor_pos.line_idx;
                new_cursor_offset_on_line = rewrap_cursor_pos.col_idx;
            }

            try new_lines.ensureUnusedCapacity(allocator, rewrapped.len);
            for (rewrapped) |rl| {
                new_lines.appendAssumeCapacity(rl);
            }
            allocator.free(rewrapped);
        }

        // ── Deinit old lines ──
        for (old_lines.items) |*l| l.deinit(allocator);
        old_lines.deinit(allocator);
        for (old_history.items) |*l| l.deinit(allocator);
        old_history.deinit(allocator);

        // ── Split result into visible + history ──
        self.width = new_width;

        const total_len = new_lines.items.len;
        const height = self.height;
        if (total_len <= height) {
            self.lines = new_lines;
            new_lines = .empty;
            // Pad self.lines with empty lines to match self.height
            while (self.lines.items.len < height) {
                var line_cells: std.ArrayListUnmanaged(Cell) = .empty;
                try line_cells.resize(allocator, new_width);
                @memset(line_cells.items, Cell.empty());
                try self.lines.append(allocator, GridLine{
                    .cells = line_cells,
                    .dirty = true,
                    .wrapped = false,
                });
            }
        } else {
            const h_count = total_len - height;

            // Allocate visible portion (last `height` lines)
            self.lines.items = try allocator.dupe(GridLine, new_lines.items[h_count..]);
            self.lines.capacity = @intCast(height);
            errdefer self.lines.deinit(allocator);

            // Allocate history portion (first `h_count` lines)
            self.history.items = try allocator.dupe(GridLine, new_lines.items[0..h_count]);
            self.history.capacity = @intCast(h_count);
            errdefer self.history.deinit(allocator);

            // Free new_lines backing array
            new_lines.deinit(allocator);
            new_lines = .empty;
        }

        if (cursor_x != null and cursor_y != null) {
            if (new_cursor_logical_line) |ncll| {
                const h_count = if (total_len > height) total_len - height else 0;
                if (ncll >= h_count) {
                    if (out_cursor_y) |ocy| ocy.* = @intCast(ncll - h_count);
                    if (out_cursor_x) |ocx| ocx.* = @intCast(new_cursor_offset_on_line orelse 0);
                } else {
                    // Cursor scrolled into history, clamp to top of visible screen
                    if (out_cursor_y) |ocy| ocy.* = 0;
                    if (out_cursor_x) |ocx| ocx.* = 0;
                }
            } else {
                if (out_cursor_y) |ocy| ocy.* = @min(cursor_y.?, height -| 1);
                if (out_cursor_x) |ocx| ocx.* = @min(cursor_x.?, new_width -| 1);
            }
        }
    }
};

// ── Tests ──

test "create grid with dimensions" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();
    try testing.expectEqual(@as(u32, 80), grid.width);
    try testing.expectEqual(@as(u32, 24), grid.height);
    try testing.expectEqual(@as(usize, 24), grid.lines.items.len);
}

test "write and read cell" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const cell = Cell.withChar('X');
    grid.setCell(10, 5, cell);

    const read = grid.getCell(10, 5);
    try testing.expectEqual(@as(u21, 'X'), read.char);
}

test "read empty cell returns space" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const cell = grid.getCell(40, 12);
    try testing.expectEqual(@as(u21, 0), cell.char);
}

test "out of bounds get returns empty" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try testing.expectEqual(@as(u21, 0), grid.getCell(999, 0).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(0, 999).char);
}

test "out of bounds set is no-op" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    grid.setCell(999, 0, Cell.withChar('X'));
    grid.setCell(0, 999, Cell.withChar('X'));
    // Shouldn't crash or panic
}

test "scroll up moves lines to history" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    try testing.expectEqual(@as(usize, 0), grid.history.items.len);

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.history.items[0].cells.items[0].char);
}

test "scroll down restores from history" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);

    try grid.scrollDown();
    try testing.expectEqual(@as(usize, 0), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
}

test "history respects limit" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();
    grid.history_limit = 3;

    for (0..10) |_| {
        try grid.scrollUp();
    }

    try testing.expectEqual(@as(usize, 3), grid.history.items.len);
}

test "clear line" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    grid.writeChar(10, 5, 'X');
    try testing.expectEqual(@as(u21, 'X'), grid.getCell(10, 5).char);

    grid.clearLine(5);
    try testing.expectEqual(@as(u21, 0), grid.getCell(10, 5).char);
}

test "clear area" {
    var grid = try Grid.init(testing.allocator, 10, 10);
    defer grid.deinit();

    for (0..10) |x| {
        for (0..10) |y| {
            grid.writeChar(@intCast(x), @intCast(y), '#');
        }
    }

    grid.clearArea(2, 2, 7, 7);

    try testing.expectEqual(@as(u21, '#'), grid.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(2, 2).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(7, 7).char);
    try testing.expectEqual(@as(u21, '#'), grid.getCell(8, 8).char);
}

test "clear all" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    for (0..10) |i| {
        grid.writeChar(@intCast(i), 0, @intCast('A' + i));
    }

    try testing.expect(!grid.isEmpty());

    grid.clear();
    try testing.expect(grid.isEmpty());
}

test "dirty flag tracking" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try testing.expect(grid.isDirty());

    grid.clearDirty();
    try testing.expect(!grid.isDirty());

    grid.writeChar(0, 0, 'X');
    try testing.expect(grid.isDirty());
}

test "cell attribute combinations" {
    var cell = Cell.empty();
    try testing.expect(!cell.attr.bold);
    try testing.expect(!cell.attr.italic);

    cell.attr.bold = true;
    cell.attr.italic = true;
    try testing.expect(cell.attr.bold);
    try testing.expect(cell.attr.italic);
}

test "cell equality" {
    const a = Cell.withChar('A');
    const b = Cell.withChar('A');
    const c = Cell.withChar('B');
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}

test "resize grid" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.resize(40);
    try testing.expectEqual(@as(u32, 40), grid.height);
    try testing.expectEqual(@as(usize, 40), grid.lines.items.len);
}

test "scroll up does not corrupt grid — C1 UAF regression" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }

    // Scroll up multiple times — each scroll moves top line to history
    for (0..10) |_| {
        try grid.scrollUp();
    }

    // History should have 5 entries (we had 5 lines, scrolled 10 times)
    // but more importantly, no crash and grid is still writable
    try testing.expect(grid.history.items.len > 0);

    // Verify grid lines are still writable — UAF bug would crash here
    grid.writeChar(0, 0, 'X');
    try testing.expectEqual(@as(u21, 'X'), grid.getCell(0, 0).char);

    // Verify history entries still have valid content — no dangling pointers
    for (grid.history.items, 0..) |*h_line, idx| {
        _ = idx;
        // Just reading should not crash
        _ = h_line.cells.items.len;
    }
}

test "resize to zero is no-op" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.resize(0);
    try testing.expectEqual(@as(u32, 24), grid.height);
    try testing.expectEqual(@as(usize, 24), grid.lines.items.len);
}

test "scrollDown with zero height does not crash" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    try grid.scrollUp();
    try testing.expectEqual(@as(usize, 1), grid.history.items.len);

    try grid.resize(0);
    try testing.expectEqual(@as(u32, 24), grid.height);

    try grid.scrollDown();
    // Should not crash — scrollDown should be no-op after resize(0) guard
}

test "write string across grid" {
    var grid = try Grid.init(testing.allocator, 80, 24);
    defer grid.deinit();

    const text = "Hello, szn!";
    for (text, 0..) |c, i| {
        grid.writeChar(@intCast(i), 0, c);
    }

    for (text, 0..) |c, i| {
        const cell = grid.getCell(@intCast(i), 0);
        try testing.expectEqual(@as(u21, c), cell.char);
    }
}

test "setSize reflows content" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    for (0..5) |i| {
        grid.writeChar(0, @intCast(i), @intCast('A' + i));
    }
    for (0..3) |_| try grid.scrollUp();

    try testing.expectEqual(@as(usize, 3), grid.history.items.len);

    // Resize width to 40 — content should be reflowed, not truncated
    try grid.setSize(40, 5);
    try testing.expectEqual(@as(u32, 40), grid.width);

    // Content is reflowed: all lines (history + visible) are rewrapped.
    // History A,B,C come first, then visible D,E
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'C'), grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, 'D'), grid.getCell(0, 3).char);
    try testing.expectEqual(@as(u21, 'E'), grid.getCell(0, 4).char);
    try testing.expectEqual(@as(usize, 0), grid.history.items.len);
}

test "Grid clone" {
    var grid = try Grid.init(testing.allocator, 80, 5);
    defer grid.deinit();

    // Fill grid and scroll some lines into history
    grid.writeChar(0, 0, 'A');
    try grid.scrollUp();
    grid.writeChar(0, 0, 'B');

    try testing.expectEqual(@as(usize, 1), grid.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), grid.history.items[0].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 0).char);

    var copy = try grid.clone(testing.allocator);
    defer copy.deinit();

    try testing.expectEqual(@as(u32, 80), copy.width);
    try testing.expectEqual(@as(u32, 5), copy.height);
    try testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try testing.expectEqual(@as(u21, 'A'), copy.history.items[0].cells.items[0].char);
    try testing.expectEqual(@as(u21, 'B'), copy.getCell(0, 0).char);

    // Modify clone, verify original is untouched
    copy.writeChar(0, 0, 'C');
    try testing.expectEqual(@as(u21, 'C'), copy.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 0).char);
}

test "setSize reflow narrow-to-wide unwraps content" {
    var grid = try Grid.init(testing.allocator, 10, 24);
    defer grid.deinit();

    // Write text at width=10, simulating screen wrapping.
    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }
    // Second logical line
    for ("123456789012345\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=10: 4 physical lines (2 logical, each wrapping once)
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'K'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 3).char);

    // Widen to 80
    try grid.setSize(80, 24);
    try testing.expectEqual(@as(u32, 80), grid.width);

    // Each logical line now fits on one physical line
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'Z'), grid.getCell(25, 0).char);
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '5'), grid.getCell(14, 1).char);

    // Each fits on one line — neither should be wrapped
    try testing.expect(!grid.lines.items[0].wrapped);
    try testing.expect(!grid.lines.items[1].wrapped);
}

test "setSize reflow wider preserves wrapped flags on multi-line logical groups" {
    var grid = try Grid.init(testing.allocator, 5, 24);
    defer grid.deinit();

    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=5: 6 physical lines, 1 logical line
    // Widen to 15: 2 physical lines
    try grid.setSize(15, 24);

    // Line 0 (first 15 chars): should wrap to line 1
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'O'), grid.getCell(14, 0).char);
    try testing.expect(grid.lines.items[0].wrapped);

    // Line 1 (remaining 11 chars): end of logical line
    try testing.expectEqual(@as(u21, 'P'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'Z'), grid.getCell(10, 1).char);
    try testing.expect(!grid.lines.items[1].wrapped);
}

test "setSize reflow wider with multiple logical lines preserves wrapped flags" {
    var grid = try Grid.init(testing.allocator, 5, 24);
    defer grid.deinit();

    var x: u32 = 0;
    var y: u32 = 0;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ\n12345678901234567890\n") |ch| {
        if (ch == '\n') {
            y += 1;
            x = 0;
            continue;
        }
        grid.writeChar(x, y, ch);
        x += 1;
        if (x >= grid.width) {
            grid.lines.items[y].wrapped = true;
            y += 1;
            x = 0;
        }
    }

    // At width=5: 10 physical lines, 2 logical lines
    // Widen to 12: each logical wraps to 3 physical lines
    try grid.setSize(12, 24);

    // First logical line: ABCDEFGHIJKLMNOPQRSTUVWXYZ (26 chars)
    // At width=12: ABCDEFGHIJKL (wrapped), MNOPQRSTUVWX (wrapped), YZ (not)
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expect(grid.lines.items[0].wrapped);
    try testing.expectEqual(@as(u21, 'M'), grid.getCell(0, 1).char);
    try testing.expect(grid.lines.items[1].wrapped);
    try testing.expectEqual(@as(u21, 'Y'), grid.getCell(0, 2).char);
    try testing.expect(!grid.lines.items[2].wrapped);

    // Second logical line: 12345678901234567890 (20 chars)
    // At width=12: 123456789012 (wrapped), 34567890 (not wrapped, fits)
    try testing.expectEqual(@as(u21, '1'), grid.getCell(0, 3).char);
    try testing.expect(grid.lines.items[3].wrapped);
    try testing.expectEqual(@as(u21, '3'), grid.getCell(0, 4).char);
    try testing.expect(!grid.lines.items[4].wrapped);
}

test "setSize reflow preserves empty lines" {
    var grid = try Grid.init(testing.allocator, 10, 5);
    defer grid.deinit();

    // Line 0: text
    grid.writeChar(0, 0, 'A');
    // Line 1: empty
    // Line 2: text
    grid.writeChar(0, 2, 'B');
    // Line 3: empty
    // Line 4: empty

    try grid.setSize(20, 5);

    // Verify empty lines are preserved between paragraphs and at the end
    try testing.expectEqual(@as(u21, 'A'), grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'B'), grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(0, 3).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(0, 4).char);

    // Verify the grid size invariant is preserved
    try testing.expectEqual(@as(usize, 5), grid.lines.items.len);
}

test "setSize reflow Thai look-ahead breaking" {
    var grid = try Grid.init(testing.allocator, 10, 24);
    defer grid.deinit();

    // Write "ดูเที่ยวไป"
    // ด (0x0E14) + ู (0x0E39, combining mark in ด)
    // เ (0x0E40) + ท (0x0E17) + ี (0x0E35, comb) + ่ (0x0E48, comb) + ย (0x0E22) + ว (0x0E23)
    // ไ (0x0E44) + ป (0x0E1B)
    grid.writeChar(0, 0, 0x0E14); // ด
    grid.lines.items[0].cells.items[0].comb1 = 0x0E39; // ู
    grid.writeChar(1, 0, 0x0E40); // เ
    grid.writeChar(2, 0, 0x0E17); // ท
    grid.lines.items[0].cells.items[2].comb1 = 0x0E35; // ี
    grid.lines.items[0].cells.items[2].comb2 = 0x0E48; // ่
    grid.writeChar(3, 0, 0x0E22); // ย
    grid.writeChar(4, 0, 0x0E23); // ว
    grid.writeChar(5, 0, 0x0E44); // ไ
    grid.writeChar(6, 0, 0x0E1B); // ป

    // Simulates soft-wrap of the line
    grid.lines.items[0].wrapped = true;

    // Resize to width 5
    // Without look-ahead, it would fit "ดูเที่ยว" (width 5) and put "ไป" on next line.
    // This is a clean break! No look-ahead backtrack is needed because
    // "เที่ยว" is complete, and "ไป" starts with leading vowel "ไ" which is a clean syllable start.
    try grid.setSize(5, 24);
    try testing.expectEqual(0x0E14, grid.getCell(0, 0).char); // ด
    try testing.expectEqual(0x0E40, grid.getCell(1, 0).char); // เ
    try testing.expectEqual(0x0E23, grid.getCell(4, 0).char); // ว
    try testing.expectEqual(0x0E44, grid.getCell(0, 1).char); // ไ
    try testing.expectEqual(0x0E1B, grid.getCell(1, 1).char); // ป

    // Reset grid
    try grid.setSize(10, 24);
    grid.lines.items[0].wrapped = true;

    // Now resize to width 4:
    // "ดูเที่ย" would be 4 cells (ดุ=1, เที่ย=3). But "ว" (consonant) would be left to wrap to the next line.
    // Since "ว" is U+0E23 (base) and is followed by "ไ" (leading vowel), look-ahead should trigger.
    // It should backtrack to before "เ" (index 1), leaving only "ดุ" on the first line.
    // "เที่ยวไป" starts on the second line: "เที่ยว" (width 4) fits exactly on the second line, and "ไป" wraps to the third line.
    try grid.setSize(4, 24);

    try testing.expectEqual(0x0E14, grid.getCell(0, 0).char); // ด
    try testing.expectEqual(@as(u21, 0), grid.getCell(1, 0).char); // space (empty/padded)

    // Line 1 should be "เที่ยว"
    try testing.expectEqual(0x0E40, grid.getCell(0, 1).char); // เ
    try testing.expectEqual(0x0E17, grid.getCell(1, 1).char); // ท
    try testing.expectEqual(0x0E22, grid.getCell(2, 1).char); // ย
    try testing.expectEqual(0x0E23, grid.getCell(3, 1).char); // ว

    // Line 2 should be "ไป"
    try testing.expectEqual(0x0E44, grid.getCell(0, 2).char); // ไ
    try testing.expectEqual(0x0E1B, grid.getCell(1, 2).char); // ป
}

test "setSize reflow Thai MAI HAN AKAT breaking" {
    var grid = try Grid.init(testing.allocator, 10, 24);
    defer grid.deinit();

    // Write "สวัสดี"
    // ส (0x0E2A)
    // ว (0x0E27) + ั (0x0E31, comb)
    // ส (0x0E2A)
    // ด (0x0E14) + ี (0x0E35, comb)
    grid.writeChar(0, 0, 0x0E2A); // ส
    grid.writeChar(1, 0, 0x0E27); // ว
    grid.lines.items[0].cells.items[1].comb1 = char_width.combiningIndex(0x0E31); // ั
    grid.writeChar(2, 0, 0x0E2A); // ส
    grid.writeChar(3, 0, 0x0E14); // ด
    grid.lines.items[0].cells.items[3].comb1 = char_width.combiningIndex(0x0E35); // ี

    // Simulates soft-wrap of the line
    grid.lines.items[0].wrapped = true;

    // Resize to width 2
    // Without MAI HAN AKAT rule, it would fit "สว" (with ั) on line 0, and put "สดี" on line 1.
    // With the rule, it backtracks before "ว" + "ั", so line 0 only has "ส".
    // Line 1 gets "วัส" (which fits in width 2).
    // Line 2 gets "ดี".
    try grid.setSize(2, 24);

    // Line 0: ส
    try testing.expectEqual(0x0E2A, grid.getCell(0, 0).char); // ส
    try testing.expectEqual(@as(u21, 0), grid.getCell(1, 0).char); // empty

    // Line 1: วัส
    try testing.expectEqual(0x0E27, grid.getCell(0, 1).char); // ว
    // Check comb mark on ว is still ั
    try testing.expectEqual(char_width.combiningIndex(0x0E31), grid.getCell(0, 1).comb1);
    try testing.expectEqual(0x0E2A, grid.getCell(1, 1).char); // ส

    // Line 2: ดี
    try testing.expectEqual(0x0E14, grid.getCell(0, 2).char); // ด
    try testing.expectEqual(char_width.combiningIndex(0x0E35), grid.getCell(0, 2).comb1);
}

test "setSize reflow Thai Ro Han (รร) breaking" {
    var grid = try Grid.init(testing.allocator, 10, 24);
    defer grid.deinit();

    // Write "บรรทุก"
    // บ (0x0E1A)
    // ร (0x0E23)
    // ร (0x0E23)
    // ท (0x0E17) + ุ (0x0E38, comb)
    // ก (0x0E01)
    grid.writeChar(0, 0, 0x0E1A); // บ
    grid.writeChar(1, 0, 0x0E23); // ร
    grid.writeChar(2, 0, 0x0E23); // ร
    grid.writeChar(3, 0, 0x0E17); // ท
    grid.lines.items[0].cells.items[3].comb1 = char_width.combiningIndex(0x0E38); // ุ
    grid.writeChar(4, 0, 0x0E01); // ก

    // Simulates soft-wrap of the line
    grid.lines.items[0].wrapped = true;

    // Resize to width 3
    // Without Ro Han rule, it could break after "บ" or "บร", splitting the "บรร" syllable.
    // With Ro Han rule, "บ" + "ร" + "ร" is a single cluster of width 3.
    // Line 0 gets "บรร".
    // Line 1 gets "ทุก".
    try grid.setSize(3, 24);

    // Line 0: บรร
    try testing.expectEqual(0x0E1A, grid.getCell(0, 0).char); // บ
    try testing.expectEqual(0x0E23, grid.getCell(1, 0).char); // ร
    try testing.expectEqual(0x0E23, grid.getCell(2, 0).char); // ร

    // Line 1: ทุก
    try testing.expectEqual(0x0E17, grid.getCell(0, 1).char); // ท
    try testing.expectEqual(char_width.combiningIndex(0x0E38), grid.getCell(0, 1).comb1); // ุ
    try testing.expectEqual(0x0E01, grid.getCell(1, 1).char); // ก
}

test "reflow cursor tracking" {
    var grid = try Grid.init(testing.allocator, 10, 5);
    defer grid.deinit();

    // Write a paragraph that will wrap: "hello world hello world"
    // Line 0: "hello worl", wrapped = true
    // Line 1: "d hello wo", wrapped = true
    // Line 2: "rld", wrapped = false
    grid.lines.items[0].cells.items[0].char = 'h';
    grid.lines.items[0].cells.items[1].char = 'e';
    grid.lines.items[0].cells.items[2].char = 'l';
    grid.lines.items[0].cells.items[3].char = 'l';
    grid.lines.items[0].cells.items[4].char = 'o';
    grid.lines.items[0].cells.items[5].char = ' ';
    grid.lines.items[0].cells.items[6].char = 'w';
    grid.lines.items[0].cells.items[7].char = 'o';
    grid.lines.items[0].cells.items[8].char = 'r';
    grid.lines.items[0].cells.items[9].char = 'l';
    grid.lines.items[0].wrapped = true;

    grid.lines.items[1].cells.items[0].char = 'd';
    grid.lines.items[1].cells.items[1].char = ' ';
    grid.lines.items[1].cells.items[2].char = 'h';
    grid.lines.items[1].cells.items[3].char = 'e';
    grid.lines.items[1].cells.items[4].char = 'l';
    grid.lines.items[1].cells.items[5].char = 'l';
    grid.lines.items[1].cells.items[6].char = 'o';
    grid.lines.items[1].cells.items[7].char = ' ';
    grid.lines.items[1].cells.items[8].char = 'w';
    grid.lines.items[1].cells.items[9].char = 'o';
    grid.lines.items[1].wrapped = true;

    grid.lines.items[2].cells.items[0].char = 'r';
    grid.lines.items[2].cells.items[1].char = 'l';
    grid.lines.items[2].cells.items[2].char = 'd';
    grid.lines.items[2].wrapped = false;

    // Place the cursor at Line 1, Col 4 (char 'l' in "hello").
    // This is offset 10 ("hello worl") + 4 = 14 in the logical line.
    const orig_cx: u32 = 4;
    const orig_cy: u32 = 1;

    // Now resize to width 5.
    // Logical line is "hello world hello world" (length 23).
    // Rewrapping to width 5:
    // Line 0: "hello" (length 5, starts at 0, ends at 5)
    // Line 1: " worl" (length 5, starts at 5, ends at 10)
    // Line 2: "d hel" (length 5, starts at 10, ends at 15)
    // Line 3: "lo wo" (length 5, starts at 15, ends at 20)
    // Line 4: "rld"   (length 3, starts at 20, ends at 23)
    // Cursor offset is 14.
    // Offset 14 falls in Line 2 ("d hel", starts at 10, ends at 15).
    // Column index is 14 - 10 = 4.
    // So new cursor should be at Line 2, Col 4.
    var new_cx: u32 = 0;
    var new_cy: u32 = 0;
    try grid.setSizeCursor(5, 5, orig_cx, orig_cy, &new_cx, &new_cy);

    try testing.expectEqual(@as(u32, 4), new_cx);
    try testing.expectEqual(@as(u32, 2), new_cy);
}

test "setSize reflow number wrapping" {
    var grid = try Grid.init(testing.allocator, 25, 5);
    defer grid.deinit();

    // Write "Value is 534 million"
    // "Value is 5" is 11 chars.
    // If we resize to width 11, it should wrap before "534".
    const text = "Value is 534 million";
    for (text, 0..) |c, idx| {
        grid.writeChar(@intCast(idx), 0, c);
    }
    grid.lines.items[0].wrapped = true;

    try grid.setSize(11, 5);

    // Line 0 should end with space, not '5'
    try testing.expectEqual(@as(u21, 's'), grid.getCell(7, 0).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(8, 0).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(9, 0).char); // padded
    try testing.expectEqual(@as(u21, 0), grid.getCell(10, 0).char); // padded

    // Line 1 should start with "534"
    try testing.expectEqual(@as(u21, '5'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '3'), grid.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, '4'), grid.getCell(2, 1).char);
}

test "setSize reflow long number wrapping at comma" {
    var grid = try Grid.init(testing.allocator, 25, 5);
    defer grid.deinit();

    // "Value: 1,234,567.88"
    // "Value: 1,234,5" is 15 chars.
    // If we resize to width 15, it should wrap after the last comma: "Value: 1,234,"
    const text = "Value: 1,234,567.88";
    for (text, 0..) |c, idx| {
        grid.writeChar(@intCast(idx), 0, c);
    }
    grid.lines.items[0].wrapped = true;

    try grid.setSize(15, 5);

    // Line 0 should be "Value: 1,234,"
    try testing.expectEqual(@as(u21, ','), grid.getCell(12, 0).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(13, 0).char); // padded
    try testing.expectEqual(@as(u21, 0), grid.getCell(14, 0).char); // padded

    // Line 1 should be "567.88"
    try testing.expectEqual(@as(u21, '5'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '6'), grid.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, '7'), grid.getCell(2, 1).char);
    try testing.expectEqual(@as(u21, '.'), grid.getCell(3, 1).char);
}

test "forceReflow at current width" {
    var grid = try Grid.init(testing.allocator, 11, 5);
    defer grid.deinit();

    // Write "Value is 534"
    // Set up standard split:
    // Line 0: "Value is 53", wrapped = true
    // Line 1: "4", wrapped = false
    const text = "Value is 53";
    for (text, 0..) |c, idx| {
        grid.writeChar(@intCast(idx), 0, c);
    }
    grid.lines.items[0].wrapped = true;
    grid.writeChar(0, 1, '4');

    // Force reflow at current width (11)
    try grid.forceReflowCursor(null, null, null, null);

    // After reflow, since "534" is a short number (length 3),
    // it should be wrapped entirely to line 1 to avoid split:
    // Line 0 should be "Value is ", padded
    try testing.expectEqual(@as(u21, 's'), grid.getCell(7, 0).char);
    try testing.expectEqual(@as(u21, ' '), grid.getCell(8, 0).char);
    try testing.expectEqual(@as(u21, 0), grid.getCell(9, 0).char);

    // Line 1 should be "534"
    try testing.expectEqual(@as(u21, '5'), grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '3'), grid.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, '4'), grid.getCell(2, 1).char);
}

test "setSize reflow Thai word breaking via libthai" {
    if (thai.getLibThai() == null) return;
    defer thai.deinitLibThai();

    var grid = try Grid.init(testing.allocator, 20, 5);
    defer grid.deinit();

    // Write "ภาษาไทยง่ายนิดเดียว"
    grid.writeChar(0, 0, 0x0E20); // ภ
    grid.writeChar(1, 0, 0x0E32); // า
    grid.writeChar(2, 0, 0x0E29); // ษ
    grid.writeChar(3, 0, 0x0E32); // า
    grid.writeChar(4, 0, 0x0E44); // ไ
    grid.writeChar(5, 0, 0x0E17); // ท
    grid.writeChar(6, 0, 0x0E22); // ย
    grid.writeChar(7, 0, 0x0E07); // ง
    grid.lines.items[0].cells.items[7].comb1 = char_width.combiningIndex(0x0E48); // ่
    grid.writeChar(8, 0, 0x0E32); // า
    grid.writeChar(9, 0, 0x0E22); // ย
    grid.writeChar(10, 0, 0x0E19); // น
    grid.lines.items[0].cells.items[10].comb1 = char_width.combiningIndex(0x0E34); // ิ
    grid.writeChar(11, 0, 0x0E14); // ด
    grid.writeChar(12, 0, 0x0E40); // เ
    grid.writeChar(13, 0, 0x0E14); // ด
    grid.lines.items[0].cells.items[13].comb1 = char_width.combiningIndex(0x0E35); // ี
    grid.writeChar(14, 0, 0x0E22); // ย
    grid.writeChar(15, 0, 0x0E27); // ว

    grid.lines.items[0].wrapped = true;

    try grid.setSize(8, 5);

    // Line 0: ภาษาไทย (7 cells)
    try testing.expectEqual(@as(u21, 0x0E20), grid.getCell(0, 0).char); // ภ
    try testing.expectEqual(@as(u21, 0x0E22), grid.getCell(6, 0).char); // ย
    try testing.expectEqual(@as(u21, 0), grid.getCell(7, 0).char); // padding

    // Line 1: ง่าย (3 cells)
    try testing.expectEqual(@as(u21, 0x0E07), grid.getCell(0, 1).char); // ง
    try testing.expectEqual(@as(u21, 0x0E22), grid.getCell(2, 1).char); // ย
    try testing.expectEqual(@as(u21, 0), grid.getCell(3, 1).char); // padding

    // Line 2: นิดเดียว (6 cells)
    try testing.expectEqual(@as(u21, 0x0E19), grid.getCell(0, 2).char); // น
    try testing.expectEqual(@as(u21, 0x0E14), grid.getCell(1, 2).char); // ด
    try testing.expectEqual(@as(u21, 0x0E40), grid.getCell(2, 2).char); // เ
    try testing.expectEqual(@as(u21, 0x0E27), grid.getCell(5, 2).char); // ว
}

test "setSize reflow Thai word trailing space bug" {
    if (thai.getLibThai() == null) return;
    defer thai.deinitLibThai();

    var grid = try Grid.init(testing.allocator, 100, 5);
    defer grid.deinit();

    const str = "โฆษกกระทรวงการต่างประเทศรัสเซีย อ้างผ่าน";
    var col: u32 = 0;
    var utf8 = std.unicode.Utf8View.init(str) catch unreachable;
    var iter = utf8.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (char_width.combiningIndex(cp) != 0) {
            if (col > 0) {
                const idx = (grid.start_index) % grid.height;
                const cell = &grid.lines.items[idx].cells.items[col - 1];
                if (cell.comb1 == 0) {
                    cell.comb1 = char_width.combiningIndex(cp);
                } else if (cell.comb2 == 0) {
                    cell.comb2 = char_width.combiningIndex(cp);
                }
            }
        } else {
            grid.writeChar(col, 0, cp);
            col += 1;
        }
    }

    grid.lines.items[0].wrapped = true;

    try grid.setSize(28, 5);

    // Line 0 should end with "รัสเซีย"
    // Cell 23 should be ร
    try testing.expectEqual(@as(u21, 0x0E23), grid.getCell(23, 0).char); // ร
    // Cell 27 should be ย
    try testing.expectEqual(@as(u21, 0x0E22), grid.getCell(27, 0).char); // ย
}

