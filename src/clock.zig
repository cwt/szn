const std = @import("std");
const testing = std.testing;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;

extern "c" fn time(t: ?*i64) i64;

const D0 = [_:0]u8{ ' ', ' ', ' ', ' ' };
const D1 = [_:0]u8{ ' ', 0xe2, 0x96, 0x88, ' ' };
const D2 = [_:0]u8{ ' ', 0xe2, 0x96, 0x88, ' ' };

const digit_rows = blk: {
    @setEvalBranchQuota(5000);
    const raw = [_][5][]const u8{
        .{ " ██ ", "█  █", "█  █", "█  █", " ██ " },
        .{ "  █ ", " ██ ", "  █ ", "  █ ", " ███" },
        .{ " ██ ", "█  █", "   █", "  █ ", "████" },
        .{ " ██ ", "█  █", "  █ ", "█  █", " ██ " },
        .{ "█  █", "█  █", "████", "   █", "   █" },
        .{ "████", "█   ", "███ ", "   █", "███ " },
        .{ " ██ ", "█   ", "████", "█  █", " ██ " },
        .{ "████", "   █", "  █ ", " █  ", " █  " },
        .{ " ██ ", "█  █", " ██ ", "█  █", " ██ " },
        .{ " ██ ", "█  █", " ███", "   █", " ██ " },
    };
    var result: [10][5][4]u8 = undefined;
    for (&result, 0..) |*d, di| {
        for (d, 0..) |*row, ri| {
            const s = raw[di][ri];
            for (row, 0..) |*c, ci| {
                c.* = if (ci < s.len) s[ci] else ' ';
            }
        }
    }
    break :blk result;
};

const colon_rows = blk: {
    const raw = [_][]const u8{ "   ", " █ ", "   ", " █ ", "   " };
    var result: [5][4]u8 = undefined;
    for (&result, 0..) |*row, ri| {
        const s = raw[ri];
        for (row, 0..) |*c, ci| {
            c.* = if (ci < s.len) s[ci] else ' ';
        }
    }
    break :blk result;
};

pub fn renderClock(grid: *Grid, sx: u32, sy: u32) void {
    _ = sx;

    const now_secs = @as(u64, @intCast(time(null)));
    const hour = @mod(@divFloor(now_secs, 3600), 24);
    const min = @mod(@divFloor(now_secs, 60), 60);
    const sec = @mod(now_secs, 60);

    const d0 = @divFloor(hour, 10);
    const d1 = @mod(hour, 10);
    const d2 = @divFloor(min, 10);
    const d3 = @mod(min, 10);
    const d4 = @divFloor(sec, 10);
    const d5 = @mod(sec, 10);

    const clock_w: u32 = 4 * 6 + 2 * 4; // 6 digits of 4 width + 2 colons of 4 width = 32
    const clock_h: u32 = 5;
    const offset_x = (grid.width -| clock_w) / 2;
    const offset_y = (grid.height -| clock_h) / 2;

    if (offset_y + clock_h > sy) return;

    const digit_indices = [_]usize{ d0, d1, 10, d2, d3, 10, d4, d5 };

    var row: u32 = 0;
    while (row < clock_h) : (row += 1) {
        var col: u32 = 0;
        for (digit_indices) |idx| {
            const chars = if (idx == 10) colon_rows[row] else digit_rows[idx][row];
            for (chars) |ch| {
                if (col >= clock_w) break;
                const gx = offset_x + col;
                const gy = offset_y + row;
                if (gx < grid.width and gy < grid.height) {
                    grid.setCell(gx, gy, Cell.withChar(@as(u21, @intCast(ch))));
                }
                col += 1;
            }
        }
    }
}

test "renderClock fills grid cells" {
    var grid = try Grid.init(testing.allocator, 40, 10);
    defer grid.deinit();

    renderClock(&grid, 40, 10);

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
