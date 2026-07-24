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
    row: i32,
    /// Width in pixels (parsed from sixel P2 parameter or 0 if unknown)
    px_width: u32,
    /// Height in pixels (counted from sixel band count * 6, or 0 if unknown)
    px_height: u32,
    /// Unique monotonically increasing Sixel image ID
    id: u32,
    /// Pane-relative top-left anchor of the image. Stored once on the image
    /// (bug #200) so the render position is reconstructable from the image
    /// itself rather than from per-cell `comb1`/`comb2` offsets, which are a
    /// consistency hazard if a cell is partially overwritten.
    anchor_col: u32 = 0,
    anchor_row: i32 = 0,
    /// True when this image was placed on the alternate screen. Used by
    /// `shiftSixelAnchors` to skip shifting alt-screen images when the
    /// main grid scrolls (and vice versa), fixing bug #219.
    alt_screen: bool = false,

    pub fn deinit(self: *SixelImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// A sixel captured from the PTY but not yet placed because the terminal's
/// real cell pixel size has not been measured yet. Held until a `cell_size`
/// response arrives (see #204) so the cursor advance / marker rows use the
/// correct footprint instead of the built-in defaults.
pub const PendingSixel = struct {
    data: []u8,
    px_width: u32,
    px_height: u32,

    pub fn deinit(self: PendingSixel, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Pane-relative top-left cell anchor (clamped to >= 0) an image was last
/// drawn at. Used by the renderer to erase a moved/removed image's overlay
/// pixels (bug #195).
pub const SixelAnchor = struct {
    col: i32,
    row: i32,
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
    /// Sixel images received from child processes, stored in a ring buffer registry.
    sixel_images: [64]?SixelImage = [_]?SixelImage{null} ** 64,
    next_sixel_id: u32 = 0,
    /// Per-slot reference count: number of grid cells currently referencing
    /// this sixel image (bug #225). Replaces the O(n) cell-scan in
    /// `isImageReferenced` with an O(1) array lookup.
    sixel_refcounts: [64]usize = [_]usize{0} ** 64,
    /// Anchor (pane-relative top-left cell, clamped to >= 0) each registry
    /// slot's sixel image was last drawn at during the previous render frame.
    /// The renderer uses this to erase a moved/removed image's overlay pixels
    /// (bug #195): the terminal's separate sixel layer is not cleared by `ECH`,
    /// so without tracking the last anchor a scrolling image leaves a smear
    /// trail, and a removed image leaves a permanent ghost.
    sixel_last_anchor: [64]?SixelAnchor = [_]?SixelAnchor{null} ** 64,
    /// Terminal cell size in pixels, used to convert sixel pixel dimensions into
    /// character-cell extents (bug #199). Defaults match the common 10×20 metrics
    /// but should be set from the real terminal (e.g. DECSLPP / font metrics).
    cell_px_width: u32 = 10,
    cell_px_height: u32 = 20,
    /// True once `cell_px_width/height` hold a measured value rather than the
    /// built-in defaults. The early oversized-image drop in `addSixelImage`
    /// waits for this so it never mis-judges an image against stale defaults.
    cell_size_known: bool = false,
    /// A sixel buffered while `cell_size_known` is false. The server pauses
    /// this pane's PTY feed and bounds the wait with its own timer (see #204).
    pending_sixel: ?PendingSixel = null,
    /// Set true when a sixel is added, signalling the server to query the
    /// display terminal for current cell pixel dimensions before the next
    /// render. The server clears this after sending the request.
    cell_size_needs_refresh: bool = false,
    force_clear: bool = false,
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
        if (self.pending_sixel) |p| p.deinit(self.allocator);
        for (&self.sixel_images) |*opt_img| {
            if (opt_img.*) |*img| {
                img.deinit(self.allocator);
            }
        }
    }

    /// Update cell pixel dimensions from terminal window size query response.
    /// Call this when receiving XTWINOPS response (CSI 4 ; height ; width t).
    /// Update the per-cell pixel dimensions. These are properties of the
    /// physical terminal, so the SAME value applies to every pane regardless
    /// of how the window is split. The display client computes them from the
    /// XTWINOPS window-pixel response divided by the full display grid size and
    /// sends the resulting cell dimensions here directly (no further division).
    pub fn updateCellSize(self: *Screen, cell_height_px: u32, cell_width_px: u32) void {
        if (cell_height_px > 0) self.cell_px_height = cell_height_px;
        if (cell_width_px > 0) self.cell_px_width = cell_width_px;
        // A measured value just arrived: replay any sixel we buffered while
        // waiting so it gets placed with the correct footprint (see #204).
        self.flushPendingSixel();
    }

    /// Place the sixel buffered in `pending_sixel` now that the cell size is
    /// known. Must only be called once `cell_size_known` is true. Safe to call
    /// when there is nothing pending.
    pub fn flushPendingSixel(self: *Screen) void {
        const pending = self.pending_sixel orelse return;
        self.pending_sixel = null;
        if (!self.cell_size_known) return;
        self.placeSixelImage(pending.data, pending.px_width, pending.px_height) catch |e| {
            // Ownership of `data` stays with the slot if placement assigned it
            // before failing; otherwise it is lost here. Either way nothing is
            // double-freed.
            std.log.warn("failed to replay buffered sixel: {any}", .{e});
        };
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
        // Under the fully-contained sixel rule an image can only ever be drawn
        // when it fits entirely inside the pane. If it spans more cell rows or
        // columns than the grid has it can never be `contained`, so it would be
        // silently discarded anyway — after we'd already scrolled the whole
        // grid up and stored it. Bail out first to skip that wasted work (and
        // the scrollback destruction) and free the captured bytes.
        const footprint_rows = if (px_height > 0) (px_height + self.cell_px_height - 1) / self.cell_px_height else 1;
        const footprint_cols = if (px_width > 0) (px_width + self.cell_px_width - 1) / self.cell_px_width else 1;
        // Only drop once we have a measured cell size; while still on the
        // built-in defaults the footprint could be wrong and we must wait for
        // the real dimensions before deciding (see #203).
        if (self.cell_size_known and (footprint_rows > self.grid.height or footprint_cols > self.grid.width)) {
            self.allocator.free(dcs_bytes);
            return;
        }

        self.cell_size_needs_refresh = true;

        // Wait for a measured cell size before placing. Until then the
        // footprint — and therefore the cursor advance and marker rows — is
        // only a guess, which is exactly what produced the "extra lines after
        // the first sixel" bug (#204). Buffer the captured bytes; the server
        // pauses this pane's PTY feed so the shell's prompt (written right
        // after the sixel DCS) cannot race the measurement and land on top of
        // where the image will go.
        if (!self.cell_size_known) {
            if (self.pending_sixel) |p| p.deinit(self.allocator);
            self.pending_sixel = .{ .data = dcs_bytes, .px_width = px_width, .px_height = px_height };
            return;
        }

        try self.placeSixelImage(dcs_bytes, px_width, px_height);
    }

    /// Place an already-captured sixel at the current cursor (used directly
    /// once the cell size is known, or to replay a buffered sixel, #204).
    fn placeSixelImage(
        self: *Screen,
        dcs_bytes: []u8,
        px_width: u32,
        px_height: u32,
    ) Error!void {
        const id = self.next_sixel_id;
        self.next_sixel_id += 1;

        // Find a slot for the new image (bug #198: don't overwrite referenced images)
        var target_slot: ?usize = null;

        const preferred_slot = id % 64;

        // 1. Try preferred slot if empty or not referenced
        if (self.sixel_images[preferred_slot] == null) {
            target_slot = preferred_slot;
        } else if (!self.isImageReferenced(self.sixel_images[preferred_slot].?.id)) {
            target_slot = preferred_slot;
        }

        // 2. Otherwise, find any empty slot
        if (target_slot == null) {
            for (self.sixel_images, 0..) |opt_img, idx| {
                if (opt_img == null) {
                    target_slot = idx;
                    break;
                }
            }
        }

        // 3. If no empty slot, find any slot whose image is no longer referenced
        if (target_slot == null) {
            for (self.sixel_images, 0..) |opt_img, idx| {
                if (opt_img) |img| {
                    if (!self.isImageReferenced(img.id)) {
                        target_slot = idx;
                        break;
                    }
                }
            }
        }

        // 4. All slots are full and every image is referenced — evict the
        // oldest *unreferenced* image first.  If none are unreferenced we
        // fall back to the minimum-id slot but only after confirming it is
        // no longer referenced at this moment (a race window in multi-pane
        // rendering).  This avoids the double-free / dangling-cell crash
        // described in bug #218.
        if (target_slot == null) {
            for (self.sixel_images, 0..) |opt_img, idx| {
                if (opt_img) |img| {
                    if (!self.isImageReferenced(img.id)) {
                        target_slot = idx;
                        break;
                    }
                }
            }
        }
        // 4b. Absolute last resort: evict oldest by ID even if referenced.
        // The caller must ensure cells are cleaned up; we accept the risk
        // here because all 64 slots are full and every image is live.
        if (target_slot == null) {
            var min_id: u32 = std.math.maxInt(u32);
            var min_idx: usize = 0;
            for (self.sixel_images, 0..) |opt_img, idx| {
                if (opt_img) |img| {
                    if (img.id < min_id) {
                        min_id = img.id;
                        min_idx = idx;
                    }
                }
            }
            target_slot = min_idx;
        }

        const slot = target_slot.?;
        if (self.sixel_images[slot]) |*old| {
            old.deinit(self.allocator);
        }

        self.sixel_images[slot] = SixelImage{
            .data = dcs_bytes,
            .col = self.cursor.x,
            .row = @intCast(self.cursor.y),
            .px_width = px_width,
            .px_height = px_height,
            .id = id,
            .anchor_col = self.cursor.x,
            .anchor_row = @intCast(self.cursor.y),
            .alt_screen = self.mode.alt_screen, // bug #219: tag so shiftSixelAnchors filters correctly
        };

        const cell_rows = if (px_height > 0) (px_height + self.cell_px_height - 1) / self.cell_px_height else 1;
        const cell_cols = if (px_width > 0) (px_width + self.cell_px_width - 1) / self.cell_px_width else 1;

        // Place marker cells row by row, scrolling the grid up as needed so that
        // *every* row of the image gets a complete set of marker cells even when
        // the cursor starts at (or near) the bottom line. Pre-scrolling here
        // keeps the stored anchor in lock-step with the marker rows: previously
        // an image added at the last line left only a single marker row (the
        // `grid_y >= height` check `break`ed before the others), which desynced
        // the sixel overlay from its cells and produced trailing artifacts
        // (bug: first image with cursor on the last line).
        const anchor_col = self.cursor.x;
        var y: u32 = 0;
        while (y < cell_rows) : (y += 1) {
            if (self.cursor.y >= self.grid.height) {
                try self.grid.scrollUp();
                self.shiftSixelAnchors(-1);
                self.cursor.y = self.grid.height - 1;
            }
            const grid_y = self.cursor.y;
            const line = self.grid.getLineMut(grid_y);
            var x: u32 = 0;
            while (x < cell_cols) : (x += 1) {
                const grid_x = anchor_col + x;
                if (grid_x >= self.grid.width) break;
                if (grid_x < line.cells.items.len) {
                    var cell = &line.cells.items[grid_x];
                    cell.attr.sixel = true;
                    cell.char = @intCast(id & 0x1FFFFF);
                    cell.comb1 = @intCast(x & 0x1FFF);
                    cell.comb2 = @intCast(y & 0x1FFF);
                }
            }
            self.cursor.y += 1;
        }

        // Leave the cursor on the line just below the image so the next write
        // scrolls it into view if it ran past the bottom. If the image was
        // added at (or near) the last line, the cursor can end up ON the bottom
        // line / status bar. Scroll the image up one more line so the cursor
        // sits on the last *content* line, just below the image (bug: cursor
        // landed on the status bar, hiding the shell prompt).
        while (self.cursor.y >= self.grid.height) {
            try self.grid.scrollUp();
            self.shiftSixelAnchors(-1);
            self.cursor.y = self.grid.height - 1;
        }

        self.cursor.x = 0;

        // bug #225: increment refcount for each marker cell placed.
        const ref_inc = @as(usize, cell_rows) * @as(usize, cell_cols);
        self.sixel_refcounts[slot] += ref_inc;

        self.dirty = true;
    }

    /// Shift every registered sixel image's stored anchor by `delta_rows`
    /// whenever the main grid scrolls (bug #200: the render position is derived
    /// from the image's anchor, which must track content as it scrolls).
    /// Only shifts images that belong to the currently active screen
    /// (bug #219: alt-screen images must not drift when the main grid scrolls).
    fn shiftSixelAnchors(self: *Screen, delta_rows: i32) void {
        const is_alt = self.mode.alt_screen;
        for (&self.sixel_images) |*opt_img| {
            if (opt_img.*) |*img| {
                // Only shift images that belong to the active screen.
                if (img.alt_screen == is_alt) {
                    img.anchor_row += delta_rows;
                }
            }
        }
    }

    /// Returns true if the sixel image with the given absolute ID is referenced
    /// by any cell.  Uses the per-slot refcount for O(1) lookup (bug #225).
    pub fn isImageReferenced(self: *const Screen, id: u32) bool {
        for (self.sixel_images, 0..) |opt_img, idx| {
            if (opt_img) |img| {
                if ((img.id & 0x1FFFFF) == id) {
                    return self.sixel_refcounts[idx] > 0;
                }
            }
        }
        return false;
    }

    /// Finds a sixel image in the registry by its absolute ID.
    pub fn findSixelImage(self: *const Screen, image_id: u32) ?SixelImage {
        for (self.sixel_images) |opt_img| {
            if (opt_img) |img| {
                if ((img.id & 0x1FFFFF) == image_id) {
                    return img;
                }
            }
        }
        return null;
    }

    /// Finds the slot index of a sixel image in the registry by its absolute ID.
    pub fn findSixelImageSlot(self: *const Screen, image_id: u32) ?usize {
        for (self.sixel_images, 0..) |opt_img, idx| {
            if (opt_img) |img| {
                if ((img.id & 0x1FFFFF) == image_id) {
                    return idx;
                }
            }
        }
        return null;
    }

    // ── Refcount helpers (bug #225) ──

    /// Decrement the refcount for the sixel image occupying cell (x, y) on the
    /// main grid.  If the cell has no sixel marker the call is a no-op.
    fn decrementMainGridRef(self: *Screen, x: u32, y: u32) void {
        if (x >= self.grid.width or y >= self.grid.height) return;
        const cell = self.grid.getCell(x, y);
        if (!cell.attr.sixel) return;
        const id = @as(u32, cell.char & 0x1FFFFF);
        if (self.findSixelImageSlot(id)) |slot| {
            if (self.sixel_refcounts[slot] > 0) {
                self.sixel_refcounts[slot] -= 1;
            }
        }
    }

    /// Decrement the refcount for the sixel image occupying cell (x, y) on the
    /// alt grid (if active).  No-op when no alt grid exists.
    fn decrementAltGridRef(self: *Screen, x: u32, y: u32) void {
        if (self.alt_grid) |alt| {
            if (x < alt.width and y < alt.height) {
                const cell = alt.getCell(x, y);
                if (!cell.attr.sixel) return;
                const id = @as(u32, cell.char & 0x1FFFFF);
                if (self.findSixelImageSlot(id)) |slot| {
                    if (self.sixel_refcounts[slot] > 0) {
                        self.sixel_refcounts[slot] -= 1;
                    }
                }
            }
        }
    }

    /// Decrement refcount for every cell in the given line's cells slice.
    fn decrementLineRefs(self: *Screen, cells: []const Cell) void {
        for (cells, 0..) |cell, x| {
            if (cell.attr.sixel) {
                const id = @as(u32, cell.char & 0x1FFFFF);
                if (self.findSixelImageSlot(id)) |slot| {
                    if (self.sixel_refcounts[slot] > 0) {
                        self.sixel_refcounts[slot] -= 1;
                    }
                }
            }
            _ = x;
        }
    }

    pub fn eraseCell(self: *const Screen) Cell {
        return .{
            .char = 0,
            .attr = .{},
            .fg = Colour.default_(),
            .bg = self.cur_cell.bg,
        };
    }

    pub fn resize(self: *Screen, width: u32, height: u32) Error!void {
        var cx = self.cursor.x;
        var cy = self.cursor.y;
        try self.grid.setSizeCursor(width, height, self.cursor.x, self.cursor.y, &cx, &cy);
        if (self.alt_grid) |*g| {
            // Use alt_cursor for the alt grid (bug #223: was using main cursor).
            var alt_cx = self.alt_cursor.x;
            var alt_cy = self.alt_cursor.y;
            try g.setSizeCursor(width, height, self.alt_cursor.x, self.alt_cursor.y, &alt_cx, &alt_cy);
        }
        self.cursor.x = @min(cx, width -| 1);
        self.cursor.y = @min(cy, height -| 1);
    }

    pub fn forceReflow(self: *Screen) Error!void {
        var cx = self.cursor.x;
        var cy = self.cursor.y;
        try self.grid.forceReflowCursor(self.cursor.x, self.cursor.y, &cx, &cy);
        if (self.alt_grid) |*g| {
            var alt_cx = self.cursor.x;
            var alt_cy = self.cursor.y;
            try g.forceReflowCursor(self.cursor.x, self.cursor.y, &alt_cx, &alt_cy);
        }
        self.cursor.x = @min(cx, self.grid.width -| 1);
        self.cursor.y = @min(cy, self.grid.height -| 1);
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
        // bug #225: decrement refcounts for the fill cells.
        self.decrementLineRefs(last.cells.items);
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
        // bug #225: decrement refcounts for the fill cells.
        self.decrementLineRefs(first.cells.items);
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
                self.shiftSixelAnchors(-1);
                const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                // bug #225: decrement refcounts for fill cells.
                self.decrementLineRefs(bottom_line.cells.items);
                @memset(bottom_line.cells.items, self.eraseCell());
                bottom_line.dirty = true;
            } else if (self.scroll_region != null and self.cursor.y == self.scroll_region.?[1]) {
                try self.scrollUpInRegion();
            } else {
                self.cursor.y += 1;
            }
            // A newline starts a fresh (non-wrapped) line
            self.grid.getLineMut(self.cursor.y).wrapped = false;
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
            if (self.cursor.x == 0) {
                if (self.cursor.y > 0 and self.grid.getLine(self.cursor.y - 1).wrapped) {
                    const prev_y = self.cursor.y - 1;
                    const last_col = self.grid.width - 1;
                    var prev_cell = self.grid.getCell(last_col, prev_y);
                    var target_col = last_col;
                    if (prev_cell.is_padding and last_col > 0) {
                        target_col = last_col - 1;
                        prev_cell = self.grid.getCell(target_col, prev_y);
                    }
                    if (prev_cell.char != ' ' and prev_cell.char != 0) {
                        const cidx = char_width.combiningIndex(char);
                        if (cidx != 0) {
                            if (prev_cell.comb1 == 0) {
                                prev_cell.comb1 = cidx;
                            } else if (prev_cell.comb2 == 0) {
                                prev_cell.comb2 = cidx;
                            }
                            self.grid.setCell(target_col, prev_y, prev_cell);
                            self.dirty = true;
                            return;
                        }
                    }
                }
                return;
            }
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
            // bug #225: don't decrement refcount for combining chars
            // (they modify in-place without erasing the sixel marker).
            self.grid.setCell(base_x, self.cursor.y, prev_cell);
            self.dirty = true;
            return;
        }

        if (width == 2) {
            if (self.mode.line_wrap and self.cursor.x + 2 > self.grid.width) {
                if (self.cursor.x < self.grid.width) {
                    self.decrementMainGridRef(self.cursor.x, self.cursor.y);
                    self.grid.setCell(self.cursor.x, self.cursor.y, self.eraseCell());
                }
                self.grid.getLineMut(self.cursor.y).wrapped = true;
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                    self.shiftSixelAnchors(-1);
                    const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                    // bug #225: decrement refcounts for fill cells.
                    self.decrementLineRefs(bottom_line.cells.items);
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

            // bug #225: decrement refcounts before overwriting cells.
            self.decrementMainGridRef(self.cursor.x, self.cursor.y);
            if (self.cursor.x + 1 < self.grid.width) {
                self.decrementMainGridRef(self.cursor.x + 1, self.cursor.y);
            }

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
                self.grid.getLineMut(self.cursor.y).wrapped = true;
                self.cursor.x = 0;
                if (self.cursor.y + 1 >= self.grid.height) {
                    try self.grid.scrollUp();
                    self.shiftSixelAnchors(-1);
                    const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                    // bug #225: decrement refcounts for fill cells.
                    self.decrementLineRefs(bottom_line.cells.items);
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
                // bug #225: decrement refcount for the overwritten cell.
                self.decrementMainGridRef(x, self.cursor.y);
                const prev = self.grid.getCell(x - 1, self.cursor.y);
                self.grid.setCell(x, self.cursor.y, prev);
            }
        }

        // bug #225: decrement refcount before overwriting.
        self.decrementMainGridRef(self.cursor.x, self.cursor.y);

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
                    // bug #225: decrement refcount before erasing.
                    self.decrementMainGridRef(x, self.cursor.y);
                    self.grid.setCell(x, self.cursor.y, fill);
                }
            },
            1 => {
                var x: u32 = 0;
                while (x <= self.cursor.x) : (x += 1) {
                    // bug #225: decrement refcount before erasing.
                    self.decrementMainGridRef(x, self.cursor.y);
                    self.grid.setCell(x, self.cursor.y, fill);
                }
            },
            2 => {
                const line = self.grid.getLineMut(self.cursor.y);
                // bug #225: decrement refcounts for all cells in this line.
                self.decrementLineRefs(line.cells.items);
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
                        // bug #225: decrement refcounts for all cells in this line.
                        self.decrementLineRefs(line.cells.items);
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
                        // bug #225: decrement refcounts for all cells in this line.
                        self.decrementLineRefs(line.cells.items);
                        @memset(line.cells.items, fill);
                        line.dirty = true;
                    }
                }
            },
            2 => {
                for (0..self.grid.height) |y| {
                    const line = self.grid.getLineMut(@intCast(y));
                    // bug #225: decrement refcounts for all cells in this line.
                    self.decrementLineRefs(line.cells.items);
                    @memset(line.cells.items, fill);
                    line.dirty = true;
                }
            },
            else => {},
        }

        var removed_sixel = false;
        for (self.sixel_images, 0..) |opt_img, idx| {
            if (opt_img) |img| {
                const cell_rows = if (img.px_height > 0) (img.px_height + 19) / 20 else 1;
                const remove = switch (mode) {
                    0 => (img.row + @as(i32, @intCast(cell_rows))) > @as(i32, @intCast(self.cursor.y)),
                    1 => img.row <= @as(i32, @intCast(self.cursor.y)),
                    2, 3 => true,
                    else => false,
                };
                if (remove) {
                    removed_sixel = true;
                    // bug #225: zero refcount for evicted image.
                    self.sixel_refcounts[idx] = 0;
                    const slot = &self.sixel_images[idx];
                    if (slot.*) |*img_ptr| {
                        img_ptr.deinit(self.allocator);
                    }
                    slot.* = null;
                }
            }
        }

        // Only force a full repaint if an image that overlapped the erased
        // region was actually removed (bug #201) — not merely because a sixel
        // happens to exist somewhere in the registry.
        if (removed_sixel) {
            self.force_clear = true;
        }
        self.dirty = true;
    }

    pub fn eraseChars(self: *Screen, n: u32) void {
        const fill = self.eraseCell();
        const end = @min(self.cursor.x + n, self.grid.width);
        if (self.cursor.x < end) {
            const line = self.grid.getLineMut(self.cursor.y);
            // bug #225: decrement refcounts for erased cells.
            self.decrementLineRefs(line.cells.items[self.cursor.x..end]);
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
            // bug #225: decrement refcounts for the target row before overwriting.
            self.decrementLineRefs(self.grid.getLineMut(row).cells.items);
            while (row > y) : (row -= 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row - 1).*;
            }
            self.grid.getLineMut(y).* = temp;
            const line = self.grid.getLineMut(y);
            // bug #225: zero refcount for fill cells.
            self.decrementLineRefs(line.cells.items);
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
            // bug #225: decrement refcount for the bottom row before overwrite.
            self.decrementLineRefs(self.grid.getLineMut(bottom).cells.items);
            const temp = self.grid.getLine(y).*;
            var row = y;
            while (row < bottom) : (row += 1) {
                self.grid.getLineMut(row).* = self.grid.getLine(row + 1).*;
            }
            self.grid.getLineMut(bottom).* = temp;
            const line = self.grid.getLineMut(bottom);
            // bug #225: zero refcount for fill cells.
            self.decrementLineRefs(line.cells.items);
            @memset(line.cells.items, fill);
            line.dirty = true;
        }
        self.dirty = true;
    }

    pub fn insertChars(self: *Screen, n: u32) void {
        // bug #225: decrement refcount for the overwritten cell at width-1.
        if (self.grid.width > 0) {
            self.decrementMainGridRef(self.grid.width - 1, self.cursor.y);
        }
        self.grid.insertChars(self.cursor.x, self.cursor.y, n);
        self.dirty = true;
    }

    pub fn deleteChars(self: *Screen, n: u32) void {
        // bug #225: decrement refcounts for the padding cells at the end.
        var x: u32 = self.grid.width -| n;
        while (x < self.grid.width) : (x += 1) {
            self.decrementMainGridRef(x, self.cursor.y);
        }
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
            // bug #225: decrement refcounts for the fill cells.
            self.decrementLineRefs(bottom_line.cells.items);
            @memset(bottom_line.cells.items, self.eraseCell());
            bottom_line.dirty = true;
            return;
        }
        self.cursor.y += 1;
    }

    pub fn reverseIndex(self: *Screen) Error!void {
        const top = if (self.scroll_region) |r| r[0] else 0;
        if (self.cursor.y == top) {
            try self.scrollDown(1);
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
                // bug #225: decrement refcounts for the fill cells.
                self.decrementLineRefs(last.cells.items);
                @memset(last.cells.items, fill);
                last.dirty = true;
            }
            // Sixel images anchored within the scroll region must follow the
            // content shift so their anchors stay in sync with their cells.
            self.shiftSixelAnchors(-1);
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try self.grid.scrollUp();
                self.shiftSixelAnchors(-1);
                const bottom_line = self.grid.getLineMut(self.grid.height - 1);
                // bug #225: decrement refcounts for the fill cells.
                self.decrementLineRefs(bottom_line.cells.items);
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
                var y = bottom;
                while (y > top) : (y -= 1) {
                    const line = self.grid.getLineMut(y);
                    const prev = self.grid.getLineMut(y - 1);
                    std.mem.swap(GridLine, line, prev);
                }
                const first = self.grid.getLineMut(top);
                self.decrementLineRefs(first.cells.items);
                @memset(first.cells.items, fill);
                first.dirty = true;
            }
            self.dirty = true;
        } else {
            const count = @min(n, self.grid.height);
            const fill = self.eraseCell();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                self.grid.shiftDown();
                self.shiftSixelAnchors(1);
                const top_line = self.grid.getLineMut(0);
                self.decrementLineRefs(top_line.cells.items);
                @memset(top_line.cells.items, fill);
                top_line.dirty = true;
            }
            self.dirty = true;
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
        var had_sixels = false;
        for (self.sixel_images) |opt_img| {
            if (opt_img != null) {
                had_sixels = true;
                break;
            }
        }
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
        // bug #225: zero all refcounts before clearing images.
        @memset(&self.sixel_refcounts, 0);
        for (&self.sixel_images) |*opt_img| {
            if (opt_img.*) |*img| {
                img.deinit(self.allocator);
            }
            opt_img.* = null;
        }
        if (had_sixels) {
            self.force_clear = true;
        }
        self.dirty = true;
    }

    pub fn clearLine(self: *Screen, y: u32) void {
        if (y < self.grid.height) {
            const line = self.grid.getLineMut(y);
            // bug #225: decrement refcounts for all cells in the cleared line.
            self.decrementLineRefs(line.cells.items);
        }
        self.grid.clearLine(y);
        self.dirty = true;
    }

    pub fn clearScreen(self: *Screen) void {
        self.grid.clear();
        // bug #225: zero refcounts.
        @memset(&self.sixel_refcounts, 0);
        for (&self.sixel_images) |*opt_img| {
            if (opt_img.*) |*img| {
                img.deinit(self.allocator);
            }
            opt_img.* = null;
        }
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

test "auto-wrap marks source line as wrapped" {
    var screen = try Screen.init(testing.allocator, 5, 10);
    defer screen.deinit();

    try screen.writeStr("ABCDE");
    try testing.expect(!screen.grid.getLine(0).wrapped);

    try screen.writeChar('F');
    try testing.expect(screen.grid.getLine(0).wrapped);
    try testing.expect(!screen.grid.getLine(1).wrapped);
}

test "auto-wrap wide char marks source line as wrapped" {
    var screen = try Screen.init(testing.allocator, 10, 10);
    defer screen.deinit();

    try screen.writeStr("123456789");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expect(!screen.grid.getLine(0).wrapped);

    try screen.writeChar(0x4E2D);
    try testing.expect(screen.grid.getLine(0).wrapped);
    try testing.expect(!screen.grid.getLine(1).wrapped);
}

test "auto-wrap followed by newline does not propagate wrapped flag" {
    var screen = try Screen.init(testing.allocator, 5, 10);
    defer screen.deinit();

    // Write 6 characters (causes wrap to line 1)
    try screen.writeStr("ABCDEF");
    try testing.expect(screen.grid.getLine(0).wrapped);
    try testing.expect(!screen.grid.getLine(1).wrapped);

    // Send a newline (should terminate the logical line)
    try screen.writeChar('\n');
    try testing.expect(screen.grid.getLine(0).wrapped);
    try testing.expect(!screen.grid.getLine(1).wrapped);
    try testing.expect(!screen.grid.getLine(2).wrapped);
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
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 0).char);
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
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 0).char);
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
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(2, 0).char);
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

test "eraseDisplay only force_clears when an overlapping sixel is removed — bug #201" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    const dcs = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
    screen.sixel_images[0] = .{ .data = dcs, .col = 0, .row = 0, .px_width = 10, .px_height = 20, .id = 0 };

    // Mode 0 erases from the cursor downward; place the cursor past the image
    // so it is NOT removed. force_clear must stay false (bug #201).
    screen.cursor.y = 10;
    screen.eraseDisplay(0);
    try testing.expect(screen.sixel_images[0] != null);
    try testing.expect(!screen.force_clear);

    // Mode 2 erases everything, removing the image -> force_clear set.
    screen.eraseDisplay(2);
    try testing.expect(screen.sixel_images[0] == null);
    try testing.expect(screen.force_clear);
}

test "addSixelImage uses configurable cell pixel size — bug #199" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;
    // Non-default terminal cell metrics (8×16 instead of the hardcoded 10×20).
    screen.cell_px_width = 8;
    screen.cell_px_height = 16;

    const dcs = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try screen.addSixelImage(dcs, 300, 200); // rows = (200+15)/16 = 13, cols = (300+7)/8 = 38

    // Hardcoded 20px/row would give 10 rows; the configured size must win.
    try testing.expect(screen.grid.getCell(0, 12).attr.sixel);
    try testing.expect(!screen.grid.getCell(0, 13).attr.sixel);
    try testing.expect(screen.grid.getCell(37, 0).attr.sixel);
    try testing.expect(!screen.grid.getCell(38, 0).attr.sixel);
}

test "addSixelImage drops an image larger than the pane — bug #203" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    // 2000px tall at 20px/cell = 100 rows > 24 grid rows: undisplayable.
    screen.cell_px_width = 20;
    screen.cell_px_height = 20;
    screen.cell_size_known = true;

    const dcs = try testing.allocator.dupe(u8, "\x1bPqBIG\x1b\\");
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try screen.addSixelImage(dcs, 100, 2000);

    // Nothing was stored in the registry, and the grid was left untouched
    // (no marker cells placed, no scrollback churn) for the dropped image.
    try testing.expect(screen.sixel_images[0] == null);
    try testing.expect(!screen.grid.getCell(0, 0).attr.sixel);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
}

test "addSixelImage buffers an image before cell size is known — bug #203" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_px_width = 20;
    screen.cell_px_height = 20;
    // Unknown (default) cell size: the image is buffered, not placed or dropped.
    screen.cell_size_known = false;

    const dcs = try testing.allocator.dupe(u8, "\x1bPqBIG\x1b\\");
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try screen.addSixelImage(dcs, 100, 2000);

    try testing.expect(screen.sixel_images[0] == null);
    try testing.expect(screen.pending_sixel != null);
    try testing.expect(!screen.grid.getCell(0, 0).attr.sixel);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
}

test "addSixelImage replays a buffered image once cell size is known — bug #204" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_px_width = 20;
    screen.cell_px_height = 20;
    screen.cell_size_known = false;

    const dcs = try testing.allocator.dupe(u8, "\x1bPqREPLAY\x1b\\");
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try screen.addSixelImage(dcs, 100, 200); // 10 rows at 20px/cell

    try testing.expect(screen.pending_sixel != null);
    try testing.expect(screen.sixel_images[0] == null);

    // A measured cell size arrives: the buffered sixel must now be placed with
    // the correct footprint and cleared from the pending slot.
    screen.cell_px_width = 20;
    screen.cell_px_height = 20;
    screen.cell_size_known = true;
    screen.updateCellSize(20, 20);

    try testing.expect(screen.pending_sixel == null);
    try testing.expect(screen.sixel_images[0] != null);
    // 200px / 20px = 10 rows of marker cells placed, cursor advanced below.
    try testing.expect(screen.grid.getCell(0, 9).attr.sixel);
    try testing.expect(screen.grid.getCell(0, 10).attr.sixel == false);
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
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 3).char);

    // Scroll down by 1 line inside region
    try screen.scrollDown(1);

    // Line 0 and 4 should be untouched
    try testing.expectEqual(@as(u21, '0'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '4'), screen.grid.getCell(0, 4).char);

    // Region lines (1..3) should be scrolled down:
    // line 1 cleared
    // line 2 gets old line 1 ("222...")
    // line 3 gets old line 2 ("333...")
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 1).char);
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
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 0).char);
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

test "sixel scrolling" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;

    // Position cursor at row 10
    screen.cursor.y = 10;
    screen.cursor.x = 0;

    // Add a sixel image (height 40px = 2 rows, so it covers rows 10, 11)
    const raw_dcs = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs, 100, 40);

    // Verify cell coordinates
    {
        const cell = screen.grid.getCell(0, 10);
        try testing.expect(cell.attr.sixel);
        try testing.expectEqual(@as(u21, 0), cell.char); // ID = 0
        try testing.expectEqual(@as(u13, 0), cell.comb2); // dy = 0
    }
    {
        const cell = screen.grid.getCell(0, 11);
        try testing.expect(cell.attr.sixel);
        try testing.expectEqual(@as(u21, 0), cell.char);
        try testing.expectEqual(@as(u13, 1), cell.comb2); // dy = 1
    }

    // Scroll up by 1 line (screen.scrollUp)
    try screen.scrollUp(1);
    // Cells should shift up to 9 and 10
    {
        const cell = screen.grid.getCell(0, 9);
        try testing.expect(cell.attr.sixel);
        try testing.expectEqual(@as(u21, 0), cell.char);
        try testing.expectEqual(@as(u13, 0), cell.comb2);
    }
    {
        const cell = screen.grid.getCell(0, 10);
        try testing.expect(cell.attr.sixel);
        try testing.expectEqual(@as(u21, 0), cell.char);
        try testing.expectEqual(@as(u13, 1), cell.comb2);
    }
}

test "sixel clearing" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;

    // Add a sixel image at row 10 (height 40px = 2 rows, so it covers rows 10, 11)
    screen.cursor.y = 10;
    screen.cursor.x = 0;
    const raw_dcs1 = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs1, 100, 40);

    // Add a sixel image at row 15 (height 40px = 2 rows, so it covers rows 15, 16)
    screen.cursor.y = 15;
    screen.cursor.x = 0;
    const raw_dcs2 = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs2, 100, 40);

    try testing.expect(screen.sixel_images[0] != null);
    try testing.expect(screen.sixel_images[1] != null);

    // Test eraseDisplay(0) (clear from cursor down)
    // Position cursor at row 14.
    // The image at 10-11 should NOT be removed from registry (row 11 < 14).
    // The image at 15-16 should be removed since its row 15 >= 14 overlaps.
    screen.cursor.y = 14;
    screen.eraseDisplay(0);
    try testing.expect(screen.sixel_images[0] != null);
    try testing.expect(screen.sixel_images[1] == null);

    // Add back second image
    screen.cursor.y = 15;
    screen.cursor.x = 0;
    const raw_dcs3 = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs3, 100, 40); // this goes to ID 2 (slot 2)
    try testing.expect(screen.sixel_images[2] != null);

    // Test eraseDisplay(1) (clear from top to cursor)
    // Position cursor at row 12.
    // The image at 10 (row 10 <= 12) should be removed.
    // The image at 15 (row 15 <= 12 is false) should NOT be removed.
    screen.cursor.y = 12;
    screen.eraseDisplay(1);
    try testing.expect(screen.sixel_images[0] == null);
    try testing.expect(screen.sixel_images[2] != null);

    // Test eraseDisplay(2) (clear whole screen)
    screen.eraseDisplay(2);
    try testing.expect(screen.sixel_images[2] == null);

    // Add an image back for clearScreen test
    screen.cursor.y = 5;
    screen.cursor.x = 0;
    const raw_dcs4 = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs4, 100, 40); // ID 3 (slot 3)
    try testing.expect(screen.sixel_images[3] != null);

    screen.clearScreen();
    try testing.expect(screen.sixel_images[3] == null);

    // Add an image back for resetHard test
    screen.cursor.y = 5;
    screen.cursor.x = 0;
    const raw_dcs5 = try testing.allocator.dupe(u8, "\x1bPq\x1b\\");
    try screen.addSixelImage(raw_dcs5, 100, 40); // ID 4 (slot 4)
    try testing.expect(screen.sixel_images[4] != null);

    try screen.resetHard();
    try testing.expect(screen.sixel_images[4] == null);
}

test "shiftSixelAnchors only shifts images on the active screen — bug #219" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;

    // Add a sixel on the main screen (ID 0)
    screen.cursor.y = 5;
    screen.cursor.x = 0;
    const dcs_main = try testing.allocator.dupe(u8, "\x1bPqMAIN\x1b\\");
    try screen.addSixelImage(dcs_main, 10, 20);
    try testing.expect(screen.sixel_images[0] != null);
    try testing.expectEqual(@as(i32, 5), screen.sixel_images[0].?.anchor_row);
    try testing.expect(!screen.sixel_images[0].?.alt_screen);

    // Enter alt screen and add another sixel (ID 1)
    try screen.useAltScreen(true);
    screen.cursor.y = 10;
    screen.cursor.x = 0;
    const dcs_alt = try testing.allocator.dupe(u8, "\x1bPqALT\x1b\\");
    try screen.addSixelImage(dcs_alt, 10, 20);
    try testing.expect(screen.sixel_images[1] != null);
    try testing.expectEqual(@as(i32, 10), screen.sixel_images[1].?.anchor_row);
    try testing.expect(screen.sixel_images[1].?.alt_screen);

    // Scroll the main grid up by 1 — only main-screen image should shift.
    // But we're on the alt screen, so scrollUp affects the alt grid's cursor.
    // Instead, manually simulate: call shiftSixelAnchors with alt_screen=false
    // (main screen scrolling). The alt image should NOT move.
    screen.mode.alt_screen = false; // pretend we switched back
    screen.shiftSixelAnchors(-1);

    // Main image shifted from row 5 → 4
    try testing.expectEqual(@as(i32, 4), screen.sixel_images[0].?.anchor_row);
    // Alt image stayed at row 10 (not shifted because alt_screen=true but is_alt=false)
    try testing.expectEqual(@as(i32, 10), screen.sixel_images[1].?.anchor_row);
}

test "sixel registry wrapping keeps referenced images — bug #198" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;

    // 1. Add the first image (ID 0) at row 0. It will occupy cells in the grid at row 0.
    screen.cursor.y = 0;
    screen.cursor.x = 0;
    const dcs0 = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
    try screen.addSixelImage(dcs0, 10, 20); // occupies slot 0, ID 0
    try testing.expect(screen.sixel_images[0] != null);
    try testing.expectEqual(@as(u32, 0), screen.sixel_images[0].?.id);

    // 2. Add 63 more images. They will occupy slots 1 to 63.
    // For each image, we immediately overwrite/clear its grid cells so that they are NOT referenced.
    var i: u32 = 1;
    while (i < 64) : (i += 1) {
        screen.cursor.y = 2; // draw at row 2 so we don't touch row 0
        screen.cursor.x = 0;
        const dcs = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
        try screen.addSixelImage(dcs, 10, 20); // goes to slot i, ID i

        // Clear the cells at row 2 to make the image unreferenced.
        // Must also decrement refcounts to keep the invariant consistent.
        const line = screen.grid.getLineMut(2);
        screen.decrementLineRefs(line.cells.items);
        @memset(line.cells.items, Cell.empty());
    }

    // Double check that image 0 is still referenced and image 1 is NOT referenced.
    try testing.expect(screen.isImageReferenced(0));
    try testing.expect(!screen.isImageReferenced(1));

    // 3. Add the 65th image (ID 64). Its preferred slot is 0 (64 % 64 = 0).
    // But since ID 0 in slot 0 is still referenced, it should avoid slot 0 and use another slot (e.g. slot 1).
    screen.cursor.y = 4;
    screen.cursor.x = 0;
    const dcs64 = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
    try screen.addSixelImage(dcs64, 10, 20); // ID 64

    // Verify that ID 0 was NOT evicted and is still in slot 0.
    try testing.expect(screen.sixel_images[0] != null);
    try testing.expectEqual(@as(u32, 0), screen.sixel_images[0].?.id);

    // Verify that the new image (ID 64) is in the registry and NOT in slot 0.
    const slot64 = screen.findSixelImageSlot(64);
    try testing.expect(slot64 != null);
    try testing.expect(slot64.? != 0);
    try testing.expect(screen.sixel_images[slot64.?] != null);
    try testing.expectEqual(@as(u32, 64), screen.sixel_images[slot64.?].?.id);
}

test "sixel refcount tracks cell writes and erases — bug #225" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cell_size_known = true;

    // Place a sixel (10px × 20px = 1 row × 1 col = 1 marker cell).
    screen.cursor.y = 5;
    screen.cursor.x = 10;
    const dcs = try testing.allocator.dupe(u8, "\x1bPqX\x1b\\");
    try screen.addSixelImage(dcs, 10, 20);

    // Refcount should be 1 (one marker cell placed).
    try testing.expectEqual(@as(usize, 1), screen.sixel_refcounts[0]);
    try testing.expect(screen.isImageReferenced(0));

    // Overwrite the sixel cell with a regular character.
    screen.cursor.x = 10;
    screen.cursor.y = 5;
    try screen.writeChar('A');

    // Refcount should now be 0; image is no longer referenced.
    try testing.expectEqual(@as(usize, 0), screen.sixel_refcounts[0]);
    try testing.expect(!screen.isImageReferenced(0));

    // Place another sixel at row 3.
    screen.cursor.y = 3;
    screen.cursor.x = 0;
    const dcs2 = try testing.allocator.dupe(u8, "\x1bPqY\x1b\\");
    try screen.addSixelImage(dcs2, 10, 20);
    try testing.expectEqual(@as(usize, 1), screen.sixel_refcounts[1]);

    // eraseDisplay(2) clears everything including the sixel.
    screen.eraseDisplay(2);
    try testing.expectEqual(@as(usize, 0), screen.sixel_refcounts[1]);
}

test "scrollDown and reverseIndex work with empty history — bug #229" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 3);
    defer screen.deinit();

    screen.grid.setCell(0, 0, Cell.withChar('A'));
    screen.grid.setCell(0, 1, Cell.withChar('B'));

    // Top of screen, empty history
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try screen.reverseIndex();

    // Line 0 should now be empty (scrolled down), Line 1 should have 'A'
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 1).char);

    // scrollDown(1) on screen with empty history
    try screen.scrollDown(1);
    // Line 2 should now have 'A'
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 2).char);
}

test "wide character 2-col wrap clears ghost character and combining mark across wrap — bug #235" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    // Position cursor at x = 4 (width 5), write 'X', then write 2-col wide char '日'
    screen.cursor.x = 4;
    screen.cursor.y = 0;
    try screen.writeChar('X');

    // Reset cursor to x = 4
    screen.cursor.x = 4;
    screen.cursor.y = 0;
    try screen.writeChar(0x65E5); // '日' (width 2)

    // Cell at (4, 0) should be cleared (no ghost 'X')
    try testing.expectEqual(@as(u21, 0), screen.grid.getCell(4, 0).char);
    // '日' should be at line 1 (0, 1)
    try testing.expectEqual(@as(u21, 0x65E5), screen.grid.getCell(0, 1).char);

    // Now test combining mark attached at x=0 right after line wrap
    var screen2 = try Screen.init(allocator, 3, 3);
    defer screen2.deinit();
    try screen2.writeChar('A');
    try screen2.writeChar('B');
    try screen2.writeChar('C');
    try screen2.writeChar('D'); // fills line 0 (width 3), wraps to line 1 x=1

    try testing.expectEqual(@as(u32, 1), screen2.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen2.cursor.y);

    // Set cursor to x=0 on wrapped line 1
    screen2.cursor.x = 0;

    // Write combining mark (0x0301) at x=0 on line 1 right after line wrap
    try screen2.writeChar(0x0301);

    // Combining mark should attach to 'C' at (2, 0) of preceding wrapped line
    const cell_c = screen2.grid.getCell(2, 0);
    try testing.expectEqual(@as(u21, 'C'), cell_c.char);
    try testing.expect(cell_c.comb1 != 0);
}
