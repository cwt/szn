const std = @import("std");
const testing = std.testing;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(timep: ?*const i64, result: *Tm) ?*Tm;

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    // OS-dependent extras follow, but we don't need them
};

const digit_rows = [10][5]u6{
    // 0: "█████"
    .{ 0b111110, 0b100010, 0b100010, 0b100010, 0b111110 },
    // 1: "  █  "
    .{ 0b001000, 0b001000, 0b001000, 0b001000, 0b001000 },
    // 2: "█████"
    .{ 0b111110, 0b000010, 0b111110, 0b100000, 0b111110 },
    // 3: "█████"
    .{ 0b111110, 0b000010, 0b111110, 0b000010, 0b111110 },
    // 4: "█   █"
    .{ 0b100010, 0b100010, 0b111110, 0b000010, 0b000010 },
    // 5: "█████"
    .{ 0b111110, 0b100000, 0b111110, 0b000010, 0b111110 },
    // 6: "█████"
    .{ 0b111110, 0b100000, 0b111110, 0b100010, 0b111110 },
    // 7: "█████"
    .{ 0b111110, 0b000010, 0b000010, 0b000010, 0b000010 },
    // 8: "█████"
    .{ 0b111110, 0b100010, 0b111110, 0b100010, 0b111110 },
    // 9: "█████"
    .{ 0b111110, 0b100010, 0b111110, 0b000010, 0b111110 },
};

const colon_rows = [5]u6{
    0b000000,
    0b001000,
    0b000000,
    0b001000,
    0b000000,
};

pub fn renderClock(grid: *Grid, sx: u32, sy: u32, utc: bool) void {
    _ = sx;

    const now_secs = time(null);
    var hour: u32 = undefined;
    var min: u32 = undefined;
    var sec: u32 = undefined;

    if (utc) {
        const u = @as(u64, @intCast(now_secs));
        hour = @as(u32, @intCast(@mod(@divFloor(u, 3600), 24)));
        min = @as(u32, @intCast(@mod(@divFloor(u, 60), 60)));
        sec = @as(u32, @intCast(@mod(u, 60)));
    } else {
        var tm: Tm = undefined;
        if (localtime_r(&now_secs, &tm)) |ltm| {
            hour = @intCast(ltm.tm_hour);
            min = @intCast(ltm.tm_min);
            sec = @intCast(ltm.tm_sec);
        } else {
            hour = 0;
            min = 0;
            sec = 0;
        }
    }

    const d0 = @divFloor(hour, 10);
    const d1 = @mod(hour, 10);
    const d2 = @divFloor(min, 10);
    const d3 = @mod(min, 10);
    const d4 = @divFloor(sec, 10);
    const d5 = @mod(sec, 10);

    const clock_w: u32 = 6 * 8; // 8 components of 6 width = 48
    const clock_h: u32 = 5;
    const offset_x = (grid.width -| clock_w) / 2;
    const offset_y = (grid.height -| clock_h) / 2;

    if (offset_y + clock_h > sy) return;

    const digit_indices = [_]usize{ d0, d1, 10, d2, d3, 10, d4, d5 };

    var row: u32 = 0;
    while (row < clock_h) : (row += 1) {
        var col: u32 = 0;
        for (digit_indices) |idx| {
            const bits = if (idx == 10) colon_rows[row] else digit_rows[idx][row];
            var bit_idx: u8 = 0;
            while (bit_idx < 6) : (bit_idx += 1) {
                const shift = 5 - bit_idx;
                const is_set = (bits & (@as(u6, 1) << @intCast(shift))) != 0;
                const ch: u21 = if (is_set) 0x2588 else ' ';

                if (col >= clock_w) break;
                const gx = offset_x + col;
                const gy = offset_y + row;
                if (gx < grid.width and gy < grid.height) {
                    grid.setCell(gx, gy, Cell.withChar(ch));
                }
                col += 1;
            }
        }
    }
}

test "renderClock fills grid cells (UTC)" {
    var grid = try Grid.init(testing.allocator, 60, 10);
    defer grid.deinit();

    renderClock(&grid, 60, 10, true);

    var found_non_empty = false;
    for (grid.lines.items) |line| {
        for (line.cells.items) |cell| {
            if (cell.char != ' ' and cell.char != 0) {
                found_non_empty = true;
                break;
            }
        }
    }
    try testing.expect(found_non_empty);
}

test "renderClock fills grid cells (local time)" {
    var grid = try Grid.init(testing.allocator, 60, 10);
    defer grid.deinit();

    renderClock(&grid, 60, 10, false);

    var found_non_empty = false;
    for (grid.lines.items) |line| {
        for (line.cells.items) |cell| {
            if (cell.char != ' ' and cell.char != 0) {
                found_non_empty = true;
                break;
            }
        }
    }
    try testing.expect(found_non_empty);
}
