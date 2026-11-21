const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const szn = @import("szn");

const compat = szn.compat;
const grid_mod = szn.grid;
const Grid = grid_mod.Grid;
const GridLine = grid_mod.GridLine;
const Cell = grid_mod.Cell;
const thai = szn.thai;
const screen_mod = szn.screen;
const Screen = screen_mod.Screen;
const input_mod = szn.input;
const InputParser = input_mod.InputParser;
const window_mod = szn.window;
const Window = window_mod.Window;
const Pane = window_mod.Pane;
const layout_mod = szn.layout;
const colour_mod = szn.colour;
const Colour = colour_mod.Colour;
const char_width = szn.char_width;
const render = szn.render;
const Display = render.Display;
const PaneBounds = render.PaneBounds;
const ThemeColours = render.ThemeColours;
const io_mod = szn.io;
const msg_reader = szn.message_reader;
const protocol = szn.protocol;

const Config = struct {
    warmup_iters: usize = 5,
    min_iters: usize = 30,
    min_duration_ns: u64 = 1_500_000_000,
    max_iters: usize = 200_000,
    filter: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    vcs_rev: ?[]const u8 = null,
    cpu_model: ?[]const u8 = null,
};

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: u64 = 0,
    resize_calls: u64 = 0,
    remap_calls: u64 = 0,
    free_calls: u64 = 0,
    total_bytes_allocated: u64 = 0,
    current_live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,

    fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn resetStatsKeepLive(self: *CountingAllocator) void {
        self.alloc_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
        self.total_bytes_allocated = 0;
        self.peak_live_bytes = self.current_live_bytes;
    }

    fn snapshot(self: *const CountingAllocator) AllocSnapshot {
        return .{
            .alloc_calls = self.alloc_calls,
            .resize_calls = self.resize_calls,
            .remap_calls = self.remap_calls,
            .free_calls = self.free_calls,
            .total_bytes_allocated = self.total_bytes_allocated,
            .peak_live_bytes = self.peak_live_bytes,
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_calls += 1;
        self.total_bytes_allocated += len;
        self.current_live_bytes += len;
        if (self.current_live_bytes > self.peak_live_bytes) {
            self.peak_live_bytes = self.current_live_bytes;
        }
        return ptr;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resize_calls += 1;
        if (new_len >= memory.len) {
            const delta = new_len - memory.len;
            self.total_bytes_allocated += delta;
            self.current_live_bytes += delta;
            if (self.current_live_bytes > self.peak_live_bytes) {
                self.peak_live_bytes = self.current_live_bytes;
            }
        } else {
            self.current_live_bytes -|= (memory.len - new_len);
        }
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.remap_calls += 1;
        if (new_len >= memory.len) {
            const delta = new_len - memory.len;
            self.total_bytes_allocated += delta;
            self.current_live_bytes += delta;
            if (self.current_live_bytes > self.peak_live_bytes) {
                self.peak_live_bytes = self.current_live_bytes;
            }
        } else {
            self.current_live_bytes -|= (memory.len - new_len);
        }
        return ptr;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.free_calls += 1;
        self.current_live_bytes -|= memory.len;
    }
};

const AllocSnapshot = struct {
    alloc_calls: u64 = 0,
    resize_calls: u64 = 0,
    remap_calls: u64 = 0,
    free_calls: u64 = 0,
    total_bytes_allocated: u64 = 0,
    peak_live_bytes: u64 = 0,
};

const CounterResult = struct {
    allocs: AllocSnapshot = .{},
    bytes_memmoved: u64 = 0,
    bytes_processed: u64 = 0,
    rows_skipped: ?u64 = null,
    total_rows: ?u64 = null,
    checksum: u64 = 0,
};

const CaseResult = struct {
    id: []const u8,
    phase: []const u8,
    unit: []const u8,
    param: u64,
    iterations: usize,
    min_ns: u64,
    p25_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    p75_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    iqr_ns: u64,
    alloc_calls: u64,
    resize_calls: u64,
    remap_calls: u64,
    free_calls: u64,
    total_bytes_allocated: u64,
    peak_live_bytes: u64,
    bytes_memmoved: u64,
    bytes_processed: u64,
    rows_skipped: ?u64,
    total_rows: ?u64,
    checksum: u64,
};

const ScalingEntry = struct {
    id: []const u8,
    from_param: u64,
    to_param: u64,
    alpha: f64,
};

const Metadata = struct {
    szn_version: []const u8,
    zig_version: []const u8,
    optimize_mode: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu_model: []const u8,
    vcs_rev: []const u8,
    libthai_available: bool,
    timestamp_unix: i64,
    warmup_iters: usize,
    min_iters: usize,
    min_duration_ms: u64,
};

const Report = struct {
    schema_version: u32 = 1,
    metadata: Metadata,
    cases: []const CaseResult,
    scaling: []const ScalingEntry,
};

fn percentile(sorted: []const u64, num: usize, den: usize) u64 {
    if (sorted.len == 0) return 0;
    const idx = ((sorted.len - 1) * num) / den;
    return sorted[idx];
}

fn shouldRun(cfg: Config, id: []const u8) bool {
    const f = cfg.filter orelse return true;
    return std.mem.indexOf(u8, id, f) != null;
}

fn runMeasured(
    alloc: std.mem.Allocator,
    cfg: Config,
    id: []const u8,
    phase: []const u8,
    unit: []const u8,
    param: u64,
    ctx: anytype,
    comptime run_timed: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!u64,
    comptime run_counters: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!CounterResult,
    stderr: *std.Io.Writer,
) !CaseResult {
    // Warmup iterations (stabilize caches, branch predictors, lazy libthai init)
    var w: usize = 0;
    while (w < cfg.warmup_iters) : (w += 1) {
        const dt = try run_timed(ctx, alloc);
        std.mem.doNotOptimizeAway(dt);
    }

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(alloc);
    try samples.ensureTotalCapacity(alloc, @max(cfg.min_iters, 64));

    var total_ns: u64 = 0;
    var iters: usize = 0;
    while (iters < cfg.min_iters or (total_ns < cfg.min_duration_ns and iters < cfg.max_iters)) : (iters += 1) {
        const dt = try run_timed(ctx, alloc);
        try samples.append(alloc, dt);
        total_ns += dt;
    }

    std.mem.sort(u64, samples.items, {}, std.sort.asc(u64));
    const min_ns = samples.items[0];
    const max_ns = samples.items[samples.items.len - 1];
    const p25_ns = percentile(samples.items, 25, 100);
    const median_ns = percentile(samples.items, 50, 100);
    const p75_ns = percentile(samples.items, 75, 100);
    const p95_ns = percentile(samples.items, 95, 100);
    const p99_ns = percentile(samples.items, 99, 100);
    const mean_ns = total_ns / @as(u64, @intCast(samples.items.len));
    const iqr_ns = p75_ns -| p25_ns;

    // Dedicated deterministic counter pass (non-timed)
    const counters = try run_counters(ctx, alloc);
    std.mem.doNotOptimizeAway(counters.checksum);

    const med_ms = @as(f64, @floatFromInt(median_ns)) / 1_000_000.0;
    const iqr_ms = @as(f64, @floatFromInt(iqr_ns)) / 1_000_000.0;
    try stderr.print(
        "  [{s}] {s:<24} N={d:<9} med={d:8.3} ms (IQR {d:6.3} ms, n={d:<5}) allocs={d} memmove={d}\n",
        .{ phase, id, param, med_ms, iqr_ms, samples.items.len, counters.allocs.alloc_calls, counters.bytes_memmoved },
    );
    try stderr.flush();

    return .{
        .id = id,
        .phase = phase,
        .unit = unit,
        .param = param,
        .iterations = samples.items.len,
        .min_ns = min_ns,
        .p25_ns = p25_ns,
        .median_ns = median_ns,
        .mean_ns = mean_ns,
        .p75_ns = p75_ns,
        .p95_ns = p95_ns,
        .p99_ns = p99_ns,
        .max_ns = max_ns,
        .iqr_ns = iqr_ns,
        .alloc_calls = counters.allocs.alloc_calls,
        .resize_calls = counters.allocs.resize_calls,
        .remap_calls = counters.allocs.remap_calls,
        .free_calls = counters.allocs.free_calls,
        .total_bytes_allocated = counters.allocs.total_bytes_allocated,
        .peak_live_bytes = counters.allocs.peak_live_bytes,
        .bytes_memmoved = counters.bytes_memmoved,
        .bytes_processed = counters.bytes_processed,
        .rows_skipped = counters.rows_skipped,
        .total_rows = counters.total_rows,
        .checksum = counters.checksum,
    };
}

// ── Helpers for constructing workloads ──

fn decodeUtf8ToCells(alloc: std.mem.Allocator, text: []const u8) ![]Cell {
    var list: std.ArrayList(Cell) = .empty;
    errdefer list.deinit(alloc);
    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const w = char_width.charWidth(cp);
        if (w == 0 and list.items.len > 0) {
            const cidx = char_width.combiningIndex(cp);
            if (cidx != 0) {
                const last = &list.items[list.items.len - 1];
                if (last.comb1 == 0) {
                    last.comb1 = cidx;
                    continue;
                } else if (last.comb2 == 0) {
                    last.comb2 = cidx;
                    continue;
                }
            }
            continue;
        }
        try list.append(alloc, Cell.withChar(cp));
        if (w == 2) {
            var pad = Cell.empty();
            pad.is_padding = true;
            try list.append(alloc, pad);
        }
    }
    return list.toOwnedSlice(alloc);
}

fn repeatCells(alloc: std.mem.Allocator, pattern: []const Cell, target_len: usize) ![]Cell {
    const out = try alloc.alloc(Cell, target_len);
    var i: usize = 0;
    while (i < target_len) : (i += 1) {
        out[i] = pattern[i % pattern.len];
    }
    return out;
}

fn buildGridFromLogicalLine(
    alloc: std.mem.Allocator,
    cells: []const Cell,
    init_width: u32,
    vis_height: u32,
    history_limit: u32,
) !Grid {
    var g = try Grid.initWithLimit(alloc, init_width, vis_height, history_limit);
    errdefer g.deinit();

    const rows = (cells.len + init_width - 1) / init_width;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const target_y: u32 = if (r < vis_height) @intCast(r) else blk: {
            try g.scrollUp();
            break :blk vis_height - 1;
        };
        const line = g.getLineMut(target_y);
        const start = r * init_width;
        const end = @min(start + init_width, cells.len);
        const slice = cells[start..end];
        @memcpy(line.cells.items[0..slice.len], slice);
        if (slice.len < init_width) {
            @memset(line.cells.items[slice.len..], Cell.empty());
        }
        line.wrapped = (r + 1 < rows);
        line.dirty = true;
    }
    return g;
}

fn checksumGrid(g: *const Grid) u64 {
    var h: u64 = @as(u64, g.width) ^ (@as(u64, g.historyLen()) << 16);
    if (g.lines.items.len > 0) {
        const first = g.getLine(0);
        const last = g.getLine(g.height - 1);
        if (first.cells.items.len > 0) h +%= first.cells.items[0].char;
        if (last.cells.items.len > 0) h +%= last.cells.items[0].char *% 31;
    }
    if (g.historyLen() > 0) {
        const hl = g.getHistoryLine(0);
        if (hl.cells.items.len > 0) h +%= hl.cells.items[0].char *% 131;
    }
    return h;
}

fn collectBounds(
    alloc: std.mem.Allocator,
    node: *const layout_mod.Node,
    lx: u32,
    ly: u32,
    lw: u32,
    lh: u32,
    out: *std.ArrayList(PaneBounds),
) !void {
    switch (node.*) {
        .leaf => |pane| {
            try out.append(alloc, .{
                .pane = pane,
                .x = lx,
                .y = ly,
                .w = lw,
                .h = lh,
            });
        },
        .split => |s| {
            if (s.direction == .horizontal) {
                const sizes = layout_mod.splitSizes(lw -| 1, s.proportion);
                try collectBounds(alloc, s.a, lx, ly, sizes.first, lh, out);
                try collectBounds(alloc, s.b, lx + sizes.first + 1, ly, sizes.second, lh, out);
            } else {
                const sizes = layout_mod.splitSizes(lh -| 1, s.proportion);
                try collectBounds(alloc, s.a, lx, ly, lw, sizes.first, out);
                try collectBounds(alloc, s.b, lx, ly + sizes.first + 1, lw, sizes.second, out);
            }
        },
    }
}

fn defaultTheme() ThemeColours {
    return .{
        .status_fg = Colour.fromIndexed(0),
        .status_bg = Colour.fromIndexed(2),
        .pane_border_fg = Colour.fromIndexed(8),
        .pane_active_border_fg = Colour.fromIndexed(2),
    };
}

// ── Phase 1 (P0): Reflow & Copy Mode Benchmarks ──

const RewrapBreaksCtx = struct {
    cells: []const Cell,
    word_breaks: []const usize,
    new_width: u32,

    fn timed(self: @This(), alloc: std.mem.Allocator) !u64 {
        var out_lines: std.ArrayList(GridLine) = .empty;
        defer {
            for (out_lines.items) |*l| l.deinit(alloc);
            out_lines.deinit(alloc);
        }
        const t0 = compat.monotonicNs();
        try Grid.rewrapWithBreaks(self.cells, self.word_breaks, self.new_width, alloc, null, null, &out_lines);
        const t1 = compat.monotonicNs();
        var sum: u64 = out_lines.items.len;
        if (out_lines.items.len > 0 and out_lines.items[0].cells.items.len > 0) {
            sum +%= out_lines.items[0].cells.items[0].char;
        }
        std.mem.doNotOptimizeAway(sum);
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var out_lines: std.ArrayList(GridLine) = .empty;
        defer {
            for (out_lines.items) |*l| l.deinit(alloc);
            out_lines.deinit(alloc);
        }
        try Grid.rewrapWithBreaks(self.cells, self.word_breaks, self.new_width, alloc, null, null, &out_lines);
        const snap = ca.snapshot();
        return .{
            .allocs = snap,
            .checksum = out_lines.items.len,
        };
    }
};

const ReflowLogicalLineCtx = struct {
    cells: []const Cell,
    init_width: u32,
    target_width: u32,
    history_limit: u32,

    fn timed(self: @This(), alloc: std.mem.Allocator) !u64 {
        var g = try buildGridFromLogicalLine(alloc, self.cells, self.init_width, 40, self.history_limit);
        defer g.deinit();
        const t0 = compat.monotonicNs();
        try g.reflow(self.target_width);
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(checksumGrid(&g));
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var g = try buildGridFromLogicalLine(alloc, self.cells, self.init_width, 40, self.history_limit);
        defer g.deinit();
        ca.resetStatsKeepLive();
        try g.reflow(self.target_width);
        return .{
            .allocs = ca.snapshot(),
            .checksum = checksumGrid(&g),
        };
    }
};

fn buildAsciiHistoryGrid(alloc: std.mem.Allocator, total_lines: usize, width: u32, vis_height: u32) !Grid {
    const hist_limit: u32 = @intCast(@max(total_lines * 4, 8000));
    var g = try Grid.initWithLimit(alloc, width, vis_height, hist_limit);
    errdefer g.deinit();

    var row_idx: usize = 0;
    while (row_idx < total_lines) : (row_idx += 1) {
        const target_y: u32 = if (row_idx < vis_height) @intCast(row_idx) else blk: {
            try g.scrollUp();
            break :blk vis_height - 1;
        };
        const line = g.getLineMut(target_y);
        @memset(line.cells.items, Cell.empty());

        // 80% short unwrapped lines (rows % 5 < 4), 20% wrapped paragraphs (linked rows)
        const group_pos = row_idx % 10;
        const is_wrapped_para = (group_pos >= 8);
        const fill_len: usize = if (is_wrapped_para)
            width
        else
            @min(width, 24 + (row_idx * 17) % 48);

        var col: usize = 0;
        while (col < fill_len) : (col += 1) {
            const ch: u21 = if (col % 9 == 8) ' ' else @intCast('a' + ((row_idx + col) % 26));
            line.cells.items[col] = Cell.withChar(ch);
        }
        // Link row 8 -> row 9 as a 2-row wrapped paragraph (20% of rows belong to wrapped paragraphs)
        line.wrapped = (group_pos == 8 and row_idx + 1 < total_lines);
        line.dirty = true;
    }
    return g;
}

const ReflowAsciiHistoryCtx = struct {
    total_lines: usize,

    fn timed(self: @This(), alloc: std.mem.Allocator) !u64 {
        var g = try buildAsciiHistoryGrid(alloc, self.total_lines, 120, 40);
        defer g.deinit();
        const t0 = compat.monotonicNs();
        try g.reflow(80);
        try g.reflow(120);
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(checksumGrid(&g));
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var g = try buildAsciiHistoryGrid(alloc, self.total_lines, 120, 40);
        defer g.deinit();
        ca.resetStatsKeepLive();
        try g.reflow(80);
        try g.reflow(120);
        return .{
            .allocs = ca.snapshot(),
            .checksum = checksumGrid(&g),
        };
    }
};

fn populateUnwrappedPane(pane: *Pane, history_lines: usize) !void {
    pane.screen.grid.history_limit = @intCast(history_lines);
    const width = pane.screen.grid.width;
    const height = pane.screen.grid.height;
    const total = history_lines + height;
    var r: usize = 0;
    while (r < total) : (r += 1) {
        const y: u32 = if (r < height) @intCast(r) else blk: {
            try pane.screen.grid.scrollUp();
            break :blk height - 1;
        };
        const line = pane.screen.grid.getLineMut(y);
        @memset(line.cells.items, Cell.empty());
        const fill = @min(width, 40 + @as(u32, @intCast((r * 13) % 50)));
        var c: u32 = 0;
        while (c < fill) : (c += 1) {
            line.cells.items[c] = Cell.withChar(@intCast('A' + ((r + c) % 26)));
        }
        line.wrapped = false;
        line.dirty = true;
    }
}

const CopyModeEnterCtx = struct {
    pane: *Pane,
    history_lines: usize,
    width: u32,
    height: u32,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        const t0 = compat.monotonicNs();
        try self.pane.enterCopyMode();
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(checksumGrid(&self.pane.screen.grid));
        self.pane.screen.copy_mode = null;
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var pane = try Pane.init(alloc, 1, self.width, self.height);
        defer pane.deinit();
        try populateUnwrappedPane(&pane, self.history_lines);
        ca.resetStatsKeepLive();
        try pane.enterCopyMode();
        const snap = ca.snapshot();
        const cs = checksumGrid(&pane.screen.grid);
        pane.screen.copy_mode = null;
        return .{
            .allocs = snap,
            .checksum = cs,
        };
    }
};

// ── Phase 2 (P1): Non-Blocking I/O Queue Drains ──

const QueueBenchResult = struct {
    elapsed_ns: u64,
    bytes_memmoved: u64,
    checksum: u64,
};

fn runQueueDrainImpl(
    alloc: std.mem.Allocator,
    payload: []const u8,
    chunk_size: usize,
    interleaved: bool,
    ca_opt: ?*CountingAllocator,
) !QueueBenchResult {
    var memmoved: u64 = 0;
    var checksum: u64 = 0;

    if (comptime @hasDecl(io_mod, "ByteQueue")) {
        var q: io_mod.ByteQueue = .{};
        defer q.deinit(alloc);

        const t0 = compat.monotonicNs();
        if (ca_opt) |ca| ca.resetStatsKeepLive();

        if (!interleaved) {
            try q.appendSlice(alloc, payload);
            while (q.len() > 0) {
                const slice = q.unreadSlice();
                const take = @min(chunk_size, slice.len);
                checksum +%= slice[0];
                const head_before = q.head;
                const unread_after = slice.len - take;
                q.consume(take);
                if (unread_after > 0 and q.head == 0 and head_before == 0) {
                    memmoved += unread_after;
                }
            }
        } else {
            const half = payload.len / 2;
            try q.appendSlice(alloc, payload[0..half]);
            var next_off: usize = half;
            while (next_off < payload.len or q.len() > 0) {
                if (q.len() > 0) {
                    const slice = q.unreadSlice();
                    const take = @min(chunk_size, slice.len);
                    checksum +%= slice[0];
                    q.consume(take);
                }
                if (next_off < payload.len) {
                    const add_len = @min(chunk_size, payload.len - next_off);
                    const head_before = q.head;
                    const unread_before = q.len();
                    try q.appendSlice(alloc, payload[next_off .. next_off + add_len]);
                    if (head_before > 0 and q.head == 0) {
                        memmoved += unread_before;
                    }
                    next_off += add_len;
                }
            }
        }
        const t1 = compat.monotonicNs();
        return .{ .elapsed_ns = t1 - t0, .bytes_memmoved = memmoved, .checksum = checksum };
    } else {
        // Phase 0 baseline: exact ArrayList(u8) + copyForwards drain pattern used in
        // Server.flushDisplayClient, main.flushStdout, and Pty.flushInput.
        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(alloc);

        const t0 = compat.monotonicNs();
        if (ca_opt) |ca| ca.resetStatsKeepLive();

        if (!interleaved) {
            try out_buf.appendSlice(alloc, payload);
            while (out_buf.items.len > 0) {
                const take = @min(chunk_size, out_buf.items.len);
                checksum +%= out_buf.items[0];
                if (take >= out_buf.items.len) {
                    out_buf.clearRetainingCapacity();
                } else {
                    const rem = out_buf.items.len - take;
                    std.mem.copyForwards(u8, out_buf.items[0..rem], out_buf.items[take..]);
                    out_buf.items.len = rem;
                    memmoved += rem;
                }
            }
        } else {
            const half = payload.len / 2;
            try out_buf.appendSlice(alloc, payload[0..half]);
            var next_off: usize = half;
            while (next_off < payload.len or out_buf.items.len > 0) {
                if (out_buf.items.len > 0) {
                    const take = @min(chunk_size, out_buf.items.len);
                    checksum +%= out_buf.items[0];
                    if (take >= out_buf.items.len) {
                        out_buf.clearRetainingCapacity();
                    } else {
                        const rem = out_buf.items.len - take;
                        std.mem.copyForwards(u8, out_buf.items[0..rem], out_buf.items[take..]);
                        out_buf.items.len = rem;
                        memmoved += rem;
                    }
                }
                if (next_off < payload.len) {
                    const add_len = @min(chunk_size, payload.len - next_off);
                    try out_buf.appendSlice(alloc, payload[next_off .. next_off + add_len]);
                    next_off += add_len;
                }
            }
        }
        const t1 = compat.monotonicNs();
        return .{ .elapsed_ns = t1 - t0, .bytes_memmoved = memmoved, .checksum = checksum };
    }
}

const QueueDrainCtx = struct {
    payload: []const u8,
    chunk_size: usize,
    interleaved: bool,

    fn timed(self: @This(), alloc: std.mem.Allocator) !u64 {
        const res = try runQueueDrainImpl(alloc, self.payload, self.chunk_size, self.interleaved, null);
        std.mem.doNotOptimizeAway(res.checksum);
        return res.elapsed_ns;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        const res = try runQueueDrainImpl(alloc, self.payload, self.chunk_size, self.interleaved, &ca);
        return .{
            .allocs = ca.snapshot(),
            .bytes_memmoved = res.bytes_memmoved,
            .bytes_processed = self.payload.len,
            .checksum = res.checksum,
        };
    }
};

const MessageReaderCtx = struct {
    batch_bytes: []const u8,
    rounds: usize,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        var reader = msg_reader.MessageReader{};
        var sum: u64 = 0;
        const t0 = compat.monotonicNs();
        var r: usize = 0;
        while (r < self.rounds) : (r += 1) {
            reader.reset();
            try reader.feed(self.batch_bytes);
            while (try reader.tryParse()) |pkt| {
                sum +%= pkt.header.length;
                if (pkt.data.len > 0) sum +%= pkt.data[0];
                reader.consume(pkt);
            }
        }
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(sum);
        return t1 - t0;
    }

    fn counters(self: @This(), _: std.mem.Allocator) !CounterResult {
        var reader = msg_reader.MessageReader{};
        var sum: u64 = 0;
        var memmoved: u64 = 0;
        var r: usize = 0;
        while (r < self.rounds) : (r += 1) {
            reader.reset();
            try reader.feed(self.batch_bytes);
            while (try reader.tryParse()) |pkt| {
                sum +%= pkt.header.length;
                const rem = if (comptime @hasField(msg_reader.MessageReader, "head"))
                    (reader.pos - reader.head) -| pkt.header.length
                else
                    reader.pos -| pkt.header.length;
                reader.consume(pkt);
                if (comptime !@hasField(msg_reader.MessageReader, "head")) {
                    memmoved += rem;
                }
            }
        }
        return .{
            .bytes_memmoved = memmoved,
            .bytes_processed = self.batch_bytes.len * self.rounds,
            .checksum = sum,
        };
    }
};

// ── Phase 3 (P1): VT UTF-8, CSI K, and Sixel Render ──

const VtUtf8Ctx = struct {
    payload: []const u8,

    fn timed(self: @This(), alloc: std.mem.Allocator) !u64 {
        var scr = try Screen.init(alloc, 120, 40);
        defer scr.deinit();
        var parser = InputParser.init(&scr);
        defer parser.deinit();
        const t0 = compat.monotonicNs();
        try parser.advanceBatch(self.payload);
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(checksumGrid(&scr.grid));
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var scr = try Screen.init(alloc, 120, 40);
        defer scr.deinit();
        var parser = InputParser.init(&scr);
        defer parser.deinit();
        ca.resetStatsKeepLive();
        try parser.advanceBatch(self.payload);
        return .{
            .allocs = ca.snapshot(),
            .bytes_processed = self.payload.len,
            .checksum = checksumGrid(&scr.grid),
        };
    }
};

const VtCsiKCtx = struct {
    scr: *Screen,
    ops: usize,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        var sum: u64 = 0;
        const t0 = compat.monotonicNs();
        var i: usize = 0;
        while (i < self.ops) : (i += 1) {
            self.scr.cursor.y = @intCast(i % 40);
            self.scr.cursor.x = 0;
            self.scr.eraseLine(0);
            sum +%= self.scr.grid.getLine(self.scr.cursor.y).cells.items[0].char;
        }
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(sum);
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        const alloc = ca.allocator();
        var scr = try Screen.init(alloc, 200, 40);
        defer scr.deinit();
        ca.resetStatsKeepLive();
        var i: usize = 0;
        while (i < self.ops) : (i += 1) {
            scr.cursor.y = @intCast(i % 40);
            scr.cursor.x = 0;
            scr.eraseLine(0);
        }
        return .{
            .allocs = ca.snapshot(),
            .checksum = self.ops,
        };
    }
};

fn seedSixelSlot(scr: *Screen, slot: usize, img: screen_mod.SixelImage, refcount: usize) void {
    scr.sixel_images[slot] = img;
    scr.sixel_refcounts[slot] = refcount;
    if (comptime @hasField(Screen, "active_sixel_count")) {
        scr.active_sixel_count += 1;
    }
}

const RenderSixelState = struct {
    alloc: std.mem.Allocator,
    win: Window,
    capture_buf: std.ArrayList(u8),
    last_cells: std.ArrayList(Cell),
    last_sx: u32 = 0,
    last_sy: u32 = 0,
    merged_screen: ?Screen = null,

    fn init(alloc: std.mem.Allocator, num_sixels: usize) !RenderSixelState {
        var win = try Window.init(alloc, 1, "sixel", 200, 60, null, null);
        errdefer win.deinit(alloc);
        const pane = win.active_pane.?;
        pane.screen.cell_size_known = true;
        pane.screen.cell_px_width = 10;
        pane.screen.cell_px_height = 20;

        const vis_count = (num_sixels * 4) / 5;
        var idx: usize = 0;
        while (idx < num_sixels) : (idx += 1) {
            const col: u32 = if (idx < vis_count)
                @intCast((idx % 10) * 20)
            else
                190;
            const row: u32 = if (idx < vis_count)
                @intCast((idx / 10) * 5)
            else
                @intCast(((idx - vis_count) % 12) * 5);
            const id: u32 = @intCast(idx + 1);
            const dcs = try alloc.dupe(u8, "\x1bPqA\x1b\\");
            var refs: usize = 0;
            var dy: u32 = 0;
            while (dy < 5 and row + dy < 60) : (dy += 1) {
                const line = pane.screen.grid.getLineMut(row + dy);
                var dx: u32 = 0;
                while (dx < 20 and col + dx < 200) : (dx += 1) {
                    var cell = &line.cells.items[col + dx];
                    cell.attr.sixel = true;
                    cell.char = @intCast(id);
                    cell.comb1 = 0;
                    cell.comb2 = 0;
                    refs += 1;
                }
            }
            seedSixelSlot(&pane.screen, idx, .{
                .data = dcs,
                .col = col,
                .row = @intCast(row),
                .px_width = 200,
                .px_height = 100,
                .id = id,
                .anchor_col = col,
                .anchor_row = @intCast(row),
            }, refs);
        }

        var capture_buf: std.ArrayList(u8) = .empty;
        errdefer capture_buf.deinit(alloc);
        try capture_buf.ensureTotalCapacity(alloc, 65536);

        var st = RenderSixelState{
            .alloc = alloc,
            .win = win,
            .capture_buf = capture_buf,
            .last_cells = .empty,
        };

        const disp = st.display();
        const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 200, .h = 60 }};
        const wins = [_]*Window{&st.win};
        pane.dirty = true;
        try disp.renderAll(
            alloc,
            &bounds,
            pane,
            "bench",
            &wins,
            &st.win,
            st.win.layout.root,
            defaultTheme(),
            null,
            false,
            "",
            0,
            false,
            true,
            null,
            false,
        );
        return st;
    }

    fn deinit(self: *RenderSixelState) void {
        if (self.merged_screen) |*ms| ms.deinit();
        self.last_cells.deinit(self.alloc);
        self.capture_buf.deinit(self.alloc);
        self.win.deinit(self.alloc);
    }

    fn display(self: *RenderSixelState) Display {
        return .{
            .fd = -1,
            .sx = 200,
            .sy = 60,
            .capture = &self.capture_buf,
            .capture_allocator = self.alloc,
            .last_cells = &self.last_cells,
            .last_sx = &self.last_sx,
            .last_sy = &self.last_sy,
            .merged_screen = &self.merged_screen,
        };
    }

    fn stepOnce(self: *RenderSixelState) !u64 {
        const pane = self.win.active_pane.?;
        const bounds = [_]PaneBounds{.{ .pane = pane, .x = 0, .y = 0, .w = 200, .h = 60 }};
        const wins = [_]*Window{&self.win};
        self.capture_buf.clearRetainingCapacity();
        pane.dirty = true;

        const disp = self.display();
        const t0 = compat.monotonicNs();
        try disp.renderAll(
            self.alloc,
            &bounds,
            pane,
            "bench",
            &wins,
            &self.win,
            self.win.layout.root,
            defaultTheme(),
            null,
            false,
            "",
            0,
            false,
            false,
            null,
            false,
        );
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(self.capture_buf.items.len);
        return t1 - t0;
    }
};

const RenderSixelGridCtx = struct {
    state: *RenderSixelState,
    num_sixels: usize,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        return self.state.stepOnce();
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        var st = try RenderSixelState.init(ca.allocator(), self.num_sixels);
        defer st.deinit();
        ca.resetStatsKeepLive();
        _ = try st.stepOnce();
        return .{
            .allocs = ca.snapshot(),
            .checksum = st.capture_buf.items.len,
        };
    }
};

// ── Phase 4 (P2): Split-Pane 1-Row Incremental Render ──

const RenderSplitState = struct {
    alloc: std.mem.Allocator,
    win: Window,
    bounds: std.ArrayList(PaneBounds),
    capture_buf: std.ArrayList(u8),
    last_cells: std.ArrayList(Cell),
    last_sx: u32 = 0,
    last_sy: u32 = 0,
    merged_screen: ?Screen = null,
    toggle: bool = false,

    fn init(alloc: std.mem.Allocator, pane_count: usize) !RenderSplitState {
        var win = try Window.init(alloc, 1, "split", 200, 60, null, null);
        errdefer win.deinit(alloc);

        if (pane_count >= 4) {
            const p0 = win.active_pane.?;
            const p1 = try win.splitPane(alloc, p0, false, 0.5);
            const p2 = try win.splitPane(alloc, p0, true, 0.5);
            const p3 = try win.splitPane(alloc, p1, true, 0.5);
            if (pane_count >= 8) {
                _ = try win.splitPane(alloc, p0, false, 0.5);
                _ = try win.splitPane(alloc, p1, false, 0.5);
                _ = try win.splitPane(alloc, p2, false, 0.5);
                _ = try win.splitPane(alloc, p3, false, 0.5);
            }
        }
        try win.resize(200, 60);

        // Fill every pane with text so incremental diffs compare non-blank cells
        for (win.panes.items, 0..) |p, pi| {
            var y: u32 = 0;
            while (y < p.screen.grid.height) : (y += 1) {
                const line = p.screen.grid.getLineMut(y);
                var x: u32 = 0;
                while (x < p.screen.grid.width) : (x += 1) {
                    line.cells.items[x] = Cell.withChar(@intCast('a' + ((pi + x + y) % 26)));
                }
                line.dirty = true;
            }
            p.dirty = true;
        }

        var bounds: std.ArrayList(PaneBounds) = .empty;
        errdefer bounds.deinit(alloc);
        try collectBounds(alloc, win.layout.root, 0, 0, 200, 60, &bounds);

        var capture_buf: std.ArrayList(u8) = .empty;
        errdefer capture_buf.deinit(alloc);
        try capture_buf.ensureTotalCapacity(alloc, 65536);

        var state = RenderSplitState{
            .alloc = alloc,
            .win = win,
            .bounds = bounds,
            .capture_buf = capture_buf,
            .last_cells = .empty,
        };

        // Initial full rebuild to prime merged_screen and last_cells
        const disp = state.display();
        const wins = [_]*Window{&state.win};
        try disp.renderAll(
            alloc,
            state.bounds.items,
            state.win.panes.items[0],
            "bench",
            &wins,
            &state.win,
            state.win.layout.root,
            defaultTheme(),
            null,
            false,
            "",
            0,
            false,
            true,
            null,
            false,
        );
        for (state.win.panes.items) |p| p.dirty = false;
        return state;
    }

    fn deinit(self: *RenderSplitState) void {
        if (self.merged_screen) |*ms| ms.deinit();
        self.last_cells.deinit(self.alloc);
        self.capture_buf.deinit(self.alloc);
        self.bounds.deinit(self.alloc);
        self.win.deinit(self.alloc);
    }

    fn display(self: *RenderSplitState) Display {
        return .{
            .fd = -1,
            .sx = 200,
            .sy = 60,
            .capture = &self.capture_buf,
            .capture_allocator = self.alloc,
            .last_cells = &self.last_cells,
            .last_sx = &self.last_sx,
            .last_sy = &self.last_sy,
            .merged_screen = &self.merged_screen,
        };
    }

    fn stepOnce(self: *RenderSplitState) !u64 {
        const p0 = self.win.panes.items[0];
        self.toggle = !self.toggle;
        p0.screen.grid.setCell(1, 0, Cell.withChar(if (self.toggle) 'X' else 'Y'));
        p0.dirty = true;
        self.capture_buf.clearRetainingCapacity();

        const disp = self.display();
        const wins = [_]*Window{&self.win};
        const t0 = compat.monotonicNs();
        try disp.renderAll(
            self.alloc,
            self.bounds.items,
            p0,
            "bench",
            &wins,
            &self.win,
            self.win.layout.root,
            defaultTheme(),
            null,
            false,
            "",
            0,
            false,
            false,
            null,
            false,
        );
        const t1 = compat.monotonicNs();
        p0.dirty = false;
        std.mem.doNotOptimizeAway(self.capture_buf.items.len);
        return t1 - t0;
    }
};

const RenderSplitCtx = struct {
    state: *RenderSplitState,
    pane_count: usize,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        return self.state.stepOnce();
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        var st = try RenderSplitState.init(ca.allocator(), self.pane_count);
        defer st.deinit();

        // Non-invasive row-skip probe: stamp column 0 of every row in last_cells
        // with sentinel 0x1FFFFE while merged_screen still matches pane cells.
        // Rows skipped by renderContent retain the sentinel; rows processed overwrite it.
        const sentinel: u21 = 0x1FFFFE;
        const w: usize = 200;
        const h: usize = 60;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            st.last_cells.items[y * w + 0].char = sentinel;
        }

        ca.resetStatsKeepLive();
        _ = try st.stepOnce();
        const snap = ca.snapshot();

        var skipped: u64 = 0;
        y = 0;
        while (y < h) : (y += 1) {
            if (st.last_cells.items[y * w + 0].char == sentinel) {
                skipped += 1;
            }
        }
        return .{
            .allocs = snap,
            .rows_skipped = skipped,
            .total_rows = h,
            .checksum = st.capture_buf.items.len,
        };
    }
};

// ── Phase 5 (P3): Region Scroll & charWidth ──

const RegionScrollCtx = struct {
    scr: *Screen,
    height: u32,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        const count = self.height / 2;
        const t0 = compat.monotonicNs();
        try self.scr.insertLines(count);
        try self.scr.deleteLines(count);
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(checksumGrid(&self.scr.grid));
        return t1 - t0;
    }

    fn counters(self: @This(), backing: std.mem.Allocator) !CounterResult {
        var ca = CountingAllocator.init(backing);
        var scr = try Screen.init(ca.allocator(), 80, self.height);
        defer scr.deinit();
        scr.setScrollRegion(1, self.height - 2);
        scr.cursorPosition(0, 1);
        const count = self.height / 2;

        ca.resetStatsKeepLive();
        try scr.insertLines(count);
        try scr.deleteLines(count);
        return .{
            .allocs = ca.snapshot(),
            .checksum = checksumGrid(&scr.grid),
        };
    }
};

const CharWidthCtx = struct {
    table: []const u21,
    total_calls: usize,

    fn timed(self: @This(), _: std.mem.Allocator) !u64 {
        const mask = self.table.len - 1;
        var sum: u64 = 0;
        const t0 = compat.monotonicNs();
        var i: usize = 0;
        while (i < self.total_calls) : (i += 1) {
            sum +%= char_width.charWidth(self.table[i & mask]);
        }
        const t1 = compat.monotonicNs();
        std.mem.doNotOptimizeAway(sum);
        return t1 - t0;
    }

    fn counters(self: @This(), _: std.mem.Allocator) !CounterResult {
        const mask = self.table.len - 1;
        var sum: u64 = 0;
        var i: usize = 0;
        while (i < 1024) : (i += 1) {
            sum +%= char_width.charWidth(self.table[i & mask]);
        }
        return .{
            .bytes_processed = self.total_calls,
            .checksum = sum,
        };
    }
};

fn configureOverrides64() !void {
    char_width.clearOverrides();
    // 64 realistic non-ASCII ambiguous-width overrides across Box Drawing / Symbols / PUA
    var i: u21 = 0;
    while (i < 64) : (i += 1) {
        const cp: u21 = 0x2500 + i * 4;
        try char_width.setOverride(cp, cp + 1, if (i % 2 == 0) 2 else 1);
    }
}

// ── Host metadata probes ──

fn runProbeCmd(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    defer gpa.free(res.stderr);
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(res.stdout);
        return null;
    }
    const copy = gpa.dupe(u8, trimmed) catch {
        gpa.free(res.stdout);
        return null;
    };
    gpa.free(res.stdout);
    return copy;
}

fn detectCpuModel(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    if (builtin.os.tag == .macos) {
        if (runProbeCmd(gpa, io, &.{ "sysctl", "-n", "machdep.cpu.brand_string" })) |s| return s;
    } else if (builtin.os.tag == .linux) {
        if (runProbeCmd(gpa, io, &.{ "sh", "-c", "awk -F: '/model name/{gsub(/^ +/, \"\", $2); print $2; exit}' /proc/cpuinfo" })) |s| return s;
    }
    return "unknown";
}

fn detectVcsRev(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    if (runProbeCmd(gpa, io, &.{ "hg", "id", "-i" })) |s| return s;
    if (runProbeCmd(gpa, io, &.{ "git", "rev-parse", "--short", "HEAD" })) |s| return s;
    return "unknown";
}

fn computeScaling(alloc: std.mem.Allocator, cases: []const CaseResult) ![]ScalingEntry {
    var out: std.ArrayList(ScalingEntry) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 1;
    while (i < cases.len) : (i += 1) {
        const prev = cases[i - 1];
        const cur = cases[i];
        if (!std.mem.eql(u8, prev.id, cur.id)) continue;
        if (prev.param == 0 or cur.param <= prev.param) continue;
        if (prev.median_ns == 0 or cur.median_ns == 0) continue;

        const size_ratio = @as(f64, @floatFromInt(cur.param)) / @as(f64, @floatFromInt(prev.param));
        const time_ratio = @as(f64, @floatFromInt(cur.median_ns)) / @as(f64, @floatFromInt(prev.median_ns));
        const alpha = @log2(time_ratio) / @log2(size_ratio);
        try out.append(alloc, .{
            .id = cur.id,
            .from_param = prev.param,
            .to_param = cur.param,
            .alpha = alpha,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseArgs(arena: std.mem.Allocator, raw_args: std.process.Args) !Config {
    var cfg = Config{};
    const args = try raw_args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--quick")) {
            cfg.warmup_iters = 2;
            cfg.min_iters = 5;
            cfg.min_duration_ns = 100_000_000;
        } else if (std.mem.eql(u8, a, "--output") and i + 1 < args.len) {
            i += 1;
            cfg.output_path = args[i];
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < args.len) {
            i += 1;
            cfg.filter = args[i];
        } else if (std.mem.eql(u8, a, "--warmup") and i + 1 < args.len) {
            i += 1;
            cfg.warmup_iters = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--min-iters") and i + 1 < args.len) {
            i += 1;
            cfg.min_iters = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--min-ms") and i + 1 < args.len) {
            i += 1;
            cfg.min_duration_ns = (try std.fmt.parseInt(u64, args[i], 10)) * 1_000_000;
        } else if (std.mem.eql(u8, a, "--vcs-rev") and i + 1 < args.len) {
            i += 1;
            cfg.vcs_rev = args[i];
        } else if (std.mem.eql(u8, a, "--cpu-model") and i + 1 < args.len) {
            i += 1;
            cfg.cpu_model = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "Usage: bench_algo [--output FILE] [--filter SUBSTR] [--warmup N] [--min-iters N] [--min-ms MS] [--quick]\n",
                .{},
            );
            std.process.exit(0);
        }
    }
    return cfg;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const alloc = std.heap.c_allocator;

    const cfg = try parseArgs(arena, init.minimal.args);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Trigger lazy libthai load once so metadata accurately reflects availability
    const libthai_ok = thai.getLibThai() != null;

    const cpu_model = cfg.cpu_model orelse detectCpuModel(arena, io);
    const vcs_rev = cfg.vcs_rev orelse detectVcsRev(arena, io);

    try stderr.print(
        "szn bench_algo v{s} | zig {s} | {s} | {s}-{s} | cpu={s} | libthai={any}\n",
        .{
            build_options.version,
            builtin.zig_version_string,
            compat.optimize_mode_name,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            cpu_model,
            libthai_ok,
        },
    );
    try stderr.flush();

    var results: std.ArrayList(CaseResult) = .empty;
    defer results.deinit(alloc);

    // ── Phase 1 (P0): Reflow & Copy Mode ──
    const thai_sample = "ภาษาไทยทดสอบการตัดคำอัตโนมัติในเทอร์มินัลเพื่อวัดความเร็วของอัลกอริทึม";
    const thai_pattern = try decodeUtf8ToCells(alloc, thai_sample);
    defer alloc.free(thai_pattern);

    if (shouldRun(cfg, "rewrap_thai_breaks")) {
        const sizes = [_]usize{ 16384, 32768, 65536, 131072 };
        for (sizes) |n| {
            const cells = try repeatCells(alloc, thai_pattern, n);
            defer alloc.free(cells);
            const num_breaks = (n - 1) / 4;
            const breaks = try alloc.alloc(usize, num_breaks);
            defer alloc.free(breaks);
            for (breaks, 0..) |*b, idx| {
                b.* = (idx + 1) * 4;
            }
            const ctx = RewrapBreaksCtx{ .cells = cells, .word_breaks = breaks, .new_width = 16 };
            try results.append(alloc, try runMeasured(alloc, cfg, "rewrap_thai_breaks", "P0", "cells", n, ctx, RewrapBreaksCtx.timed, RewrapBreaksCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "reflow_thai_e2e_w16")) {
        const sizes = [_]usize{ 4096, 8192, 16384, 32768, 65536 };
        for (sizes) |n| {
            const cells = try repeatCells(alloc, thai_pattern, n);
            defer alloc.free(cells);
            const ctx = ReflowLogicalLineCtx{ .cells = cells, .init_width = 80, .target_width = 16, .history_limit = @intCast(n) };
            try results.append(alloc, try runMeasured(alloc, cfg, "reflow_thai_e2e_w16", "P0", "cells", n, ctx, ReflowLogicalLineCtx.timed, ReflowLogicalLineCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "reflow_thai_e2e_w40")) {
        const sizes = [_]usize{ 4096, 8192, 16384, 32768, 65536 };
        for (sizes) |n| {
            const cells = try repeatCells(alloc, thai_pattern, n);
            defer alloc.free(cells);
            const ctx = ReflowLogicalLineCtx{ .cells = cells, .init_width = 80, .target_width = 40, .history_limit = @intCast(n) };
            try results.append(alloc, try runMeasured(alloc, cfg, "reflow_thai_e2e_w40", "P0", "cells", n, ctx, ReflowLogicalLineCtx.timed, ReflowLogicalLineCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "reflow_numeric_dots")) {
        const num_pattern = try decodeUtf8ToCells(alloc, "1234567890.");
        defer alloc.free(num_pattern);
        const sizes = [_]usize{ 16384, 32768, 65536, 131072, 262144 };
        for (sizes) |n| {
            const cells = try repeatCells(alloc, num_pattern, n);
            defer alloc.free(cells);
            const ctx = ReflowLogicalLineCtx{ .cells = cells, .init_width = 80, .target_width = 40, .history_limit = @intCast(n) };
            try results.append(alloc, try runMeasured(alloc, cfg, "reflow_numeric_dots", "P0", "cells", n, ctx, ReflowLogicalLineCtx.timed, ReflowLogicalLineCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "reflow_ascii_history")) {
        const sizes = [_]usize{ 500, 1000, 2000, 4000 };
        for (sizes) |h| {
            const ctx = ReflowAsciiHistoryCtx{ .total_lines = h };
            try results.append(alloc, try runMeasured(alloc, cfg, "reflow_ascii_history", "P0", "lines", h, ctx, ReflowAsciiHistoryCtx.timed, ReflowAsciiHistoryCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "copy_mode_enter_noop")) {
        var pane = try Pane.init(alloc, 1, 120, 40);
        defer pane.deinit();
        try populateUnwrappedPane(&pane, 2000);
        const ctx = CopyModeEnterCtx{ .pane = &pane, .history_lines = 2000, .width = 120, .height = 40 };
        try results.append(alloc, try runMeasured(alloc, cfg, "copy_mode_enter_noop", "P0", "lines", 2000, ctx, CopyModeEnterCtx.timed, CopyModeEnterCtx.counters, stderr));
    }

    // ── Phase 2 (P1): Non-Blocking I/O Queue Drains ──
    if (shouldRun(cfg, "queue_drain_1k") or shouldRun(cfg, "queue_drain_4k")) {
        const max_bytes: usize = 8 * 1024 * 1024;
        const payload = try alloc.alloc(u8, max_bytes);
        defer alloc.free(payload);
        for (payload, 0..) |*b, idx| {
            b.* = @truncate((idx *% 31 +% 7) & 0xFF);
        }

        if (shouldRun(cfg, "queue_drain_1k")) {
            const sizes = [_]usize{ 512 * 1024, 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024 };
            for (sizes) |n| {
                const ctx = QueueDrainCtx{ .payload = payload[0..n], .chunk_size = 1024, .interleaved = false };
                try results.append(alloc, try runMeasured(alloc, cfg, "queue_drain_1k", "P1", "bytes", n, ctx, QueueDrainCtx.timed, QueueDrainCtx.counters, stderr));
            }
        }

        if (shouldRun(cfg, "queue_drain_4k")) {
            const sizes = [_]usize{ 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024 };
            for (sizes) |n| {
                const ctx = QueueDrainCtx{ .payload = payload[0..n], .chunk_size = 4096, .interleaved = true };
                try results.append(alloc, try runMeasured(alloc, cfg, "queue_drain_4k", "P1", "bytes", n, ctx, QueueDrainCtx.timed, QueueDrainCtx.counters, stderr));
            }
        }
    }

    if (shouldRun(cfg, "message_reader_drain")) {
        const sizes = [_]usize{ 1024, 2048, 4096, 8192 };
        for (sizes) |n| {
            // Pack 16-byte stdin_data packets (5-byte header + 11-byte payload)
            const pkt_data = "0123456789A";
            const pkt = protocol.Packet.make(.stdin_data, pkt_data);
            var pkt_ser_buf: [32]u8 = undefined;
            const ser = pkt.serialize(&pkt_ser_buf);
            std.debug.assert(ser.len == 16);

            const batch = try alloc.alloc(u8, n);
            defer alloc.free(batch);
            var off: usize = 0;
            while (off + 16 <= n) : (off += 16) {
                @memcpy(batch[off .. off + 16], ser);
            }
            const ctx = MessageReaderCtx{ .batch_bytes = batch, .rounds = 200 };
            try results.append(alloc, try runMeasured(alloc, cfg, "message_reader_drain", "P1", "bytes", n, ctx, MessageReaderCtx.timed, MessageReaderCtx.counters, stderr));
        }
    }

    // ── Phase 3 (P1): Sixel Refcount Guard & Render ──
    if (shouldRun(cfg, "vt_utf8_stream")) {
        const unit_str = "\x1b[38;5;196m┌────────┐\x1b[0m ภาษาไทยทดสอบการแสดงผล │ ข้อความตัวอย่าง\r\n";
        const sizes = [_]usize{ 256 * 1024, 1024 * 1024, 4 * 1024 * 1024 };
        for (sizes) |n| {
            const buf = try alloc.alloc(u8, n);
            defer alloc.free(buf);
            var off: usize = 0;
            while (off + unit_str.len <= n) : (off += unit_str.len) {
                @memcpy(buf[off .. off + unit_str.len], unit_str);
            }
            if (off < n) @memset(buf[off..n], ' ');
            const ctx = VtUtf8Ctx{ .payload = buf };
            try results.append(alloc, try runMeasured(alloc, cfg, "vt_utf8_stream", "P1", "bytes", n, ctx, VtUtf8Ctx.timed, VtUtf8Ctx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "vt_csi_k_clear")) {
        var scr = try Screen.init(alloc, 200, 40);
        defer scr.deinit();
        const sizes = [_]usize{ 25000, 50000, 100000 };
        for (sizes) |ops| {
            const ctx = VtCsiKCtx{ .scr = &scr, .ops = ops };
            try results.append(alloc, try runMeasured(alloc, cfg, "vt_csi_k_clear", "P1", "ops", ops, ctx, VtCsiKCtx.timed, VtCsiKCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "render_sixel_grid")) {
        const sizes = [_]usize{ 10, 20, 40, 64 };
        for (sizes) |s| {
            var state = try RenderSixelState.init(alloc, s);
            defer state.deinit();
            const ctx = RenderSixelGridCtx{ .state = &state, .num_sixels = s };
            try results.append(alloc, try runMeasured(alloc, cfg, "render_sixel_grid", "P1", "sixels", s, ctx, RenderSixelGridCtx.timed, RenderSixelGridCtx.counters, stderr));
        }
    }

    // ── Phase 4 (P2): Split-Pane 1-Row Render ──
    if (shouldRun(cfg, "render_split_1row")) {
        const sizes = [_]usize{ 1, 4, 8 };
        for (sizes) |pcount| {
            var state = try RenderSplitState.init(alloc, pcount);
            defer state.deinit();
            const ctx = RenderSplitCtx{ .state = &state, .pane_count = pcount };
            try results.append(alloc, try runMeasured(alloc, cfg, "render_split_1row", "P2", "panes", pcount, ctx, RenderSplitCtx.timed, RenderSplitCtx.counters, stderr));
        }
    }

    // ── Phase 5 (P3): Region Scroll & charWidth ──
    if (shouldRun(cfg, "screen_region_scroll")) {
        const sizes = [_]u32{ 100, 400, 1600, 4000 };
        for (sizes) |h| {
            var scr = try Screen.init(alloc, 80, h);
            defer scr.deinit();
            scr.setScrollRegion(1, h - 2);
            scr.cursorPosition(0, 1);
            const ctx = RegionScrollCtx{ .scr = &scr, .height = h };
            try results.append(alloc, try runMeasured(alloc, cfg, "screen_region_scroll", "P3", "rows", h, ctx, RegionScrollCtx.timed, RegionScrollCtx.counters, stderr));
        }
    }

    if (shouldRun(cfg, "char_width_ascii") or shouldRun(cfg, "char_width_mixed")) {
        try configureOverrides64();
        defer char_width.clearOverrides();

        const table_len: usize = 1024;
        if (shouldRun(cfg, "char_width_ascii")) {
            var ascii_tbl: [table_len]u21 = undefined;
            for (&ascii_tbl, 0..) |*slot, i| {
                slot.* = @intCast(0x20 + (i % 95));
            }
            const ctx = CharWidthCtx{ .table = &ascii_tbl, .total_calls = 10_000_000 };
            try results.append(alloc, try runMeasured(alloc, cfg, "char_width_ascii", "P3", "calls", 10_000_000, ctx, CharWidthCtx.timed, CharWidthCtx.counters, stderr));
        }

        if (shouldRun(cfg, "char_width_mixed")) {
            var mixed_tbl: [table_len]u21 = undefined;
            for (&mixed_tbl, 0..) |*slot, i| {
                const bucket = i % 20;
                if (bucket < 10) {
                    // 50% ASCII
                    slot.* = @intCast(0x20 + (i % 95));
                } else if (bucket < 14) {
                    // 20% Thai
                    slot.* = @intCast(0x0E01 + (i % 78));
                } else if (bucket < 17) {
                    // 15% CJK
                    slot.* = @intCast(0x4E00 + (i * 19) % 4096);
                } else {
                    // 15% Emoji & Symbols (hits overrides & emoji_presentation_ranges)
                    slot.* = if (i % 2 == 0)
                        @intCast(0x2500 + (i % 256))
                    else
                        @intCast(0x1F300 + (i % 512));
                }
            }
            const ctx = CharWidthCtx{ .table = &mixed_tbl, .total_calls = 10_000_000 };
            try results.append(alloc, try runMeasured(alloc, cfg, "char_width_mixed", "P3", "calls", 10_000_000, ctx, CharWidthCtx.timed, CharWidthCtx.counters, stderr));
        }
    }

    const scaling = try computeScaling(alloc, results.items);
    defer alloc.free(scaling);

    const report = Report{
        .metadata = .{
            .szn_version = build_options.version,
            .zig_version = builtin.zig_version_string,
            .optimize_mode = compat.optimize_mode_name,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .cpu_model = cpu_model,
            .vcs_rev = vcs_rev,
            .libthai_available = libthai_ok,
            .timestamp_unix = @divFloor(io_mod.currentMillis(), 1000),
            .warmup_iters = cfg.warmup_iters,
            .min_iters = cfg.min_iters,
            .min_duration_ms = cfg.min_duration_ns / 1_000_000,
        },
        .cases = results.items,
        .scaling = scaling,
    };

    var json_out: std.Io.Writer.Allocating = .init(alloc);
    defer json_out.deinit();
    try json_out.writer.print("{f}\n", .{std.json.fmt(report, .{ .whitespace = .indent_2 })});

    if (cfg.output_path) |out_path| {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = out_path,
            .data = json_out.written(),
        });
        try stderr.print("Wrote benchmark JSON to {s}\n", .{out_path});
        try stderr.flush();
    } else {
        var stdout_buf: [8192]u8 = undefined;
        var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
        try stdout_writer.interface.writeAll(json_out.written());
        try stdout_writer.interface.flush();
    }
}
