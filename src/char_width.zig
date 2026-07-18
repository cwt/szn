const std = @import("std");

const WidthRange = struct {
    start: u21,
    end: u21,
    width: u2,
};

// ── User codepoint-width overrides ──
//
// There is no terminal capability that reports whether ambiguous-width symbols
// (emoji, dingbats, misc symbols) render as width 1 or width 2. Each
// terminal emulator makes its own choice, and szn cannot query it. This is
// exactly the situation tmux faces; tmux solves it with a per-codepoint
// override option (`codepoint-widths`, see options.zig) that fills a runtime
// cache (`utf8_default_width_cache`). We mirror that design here.
//
// Overrides are stored in a small fixed table (matching tmux's bounded cache)
// and consulted before any width table in `charWidth`. The `codepoint-widths`
// option parser calls `setOverride` / `clearOverrides` to populate it.

pub const MAX_OVERRIDES = 256;

const Override = struct {
    start: u21,
    end: u21,
    width: u2,
};

var override_count: usize = 0;
var overrides: [MAX_OVERRIDES]Override = undefined;

/// Replace the entire override table with a single codepoint range.
/// Returns `error.OverrideTableFull` if the table is saturated.
pub fn setOverride(start: u21, end: u21, width: u2) !void {
    if (override_count >= MAX_OVERRIDES) return error.OverrideTableFull;
    overrides[override_count] = .{ .start = start, .end = end, .width = width };
    override_count += 1;
}

/// Remove all overrides. The `codepoint-widths` option rebuilds the table
/// from scratch on every assignment, so we never need incremental deletion.
pub fn clearOverrides() void {
    override_count = 0;
}

pub const OverrideError = error{ OverrideTableFull };

fn overrideWidth(cp: u21) ?u2 {
    var i: usize = 0;
    while (i < override_count) : (i += 1) {
        if (cp >= overrides[i].start and cp <= overrides[i].end) {
            return overrides[i].width;
        }
    }
    return null;
}

/// Parse a `codepoint-widths` option value and (re)build the override
/// table from scratch. Accepts a space-separated list of entries:
///
///   U+2705=1            single codepoint
///   U+2600-U+26FF=2     inclusive range
///
/// The width must be 1 or 2. An empty string clears all overrides
/// (restoring szn's built-in defaults). Returns `OverrideTableFull` if
/// more than MAX_OVERRIDES distinct entries are supplied.
pub fn applyCodepointWidths(allocator: std.mem.Allocator, value: []const u8) ParseOverrideError!void {
    _ = allocator;
    clearOverrides();
    var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, value, " \t"), ' ');
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEntry;
        const cp_part = entry[0..eq];
        const w_part = entry[eq + 1 ..];
        const width: u2 = blk: {
            if (std.mem.eql(u8, w_part, "1")) break :blk 1;
            if (std.mem.eql(u8, w_part, "2")) break :blk 2;
            return error.InvalidWidth;
        };
        if (std.mem.indexOf(u8, cp_part, "-")) |dash| {
            const lo = parseCp(cp_part[0..dash]) orelse return error.InvalidCodepoint;
            const hi = parseCp(cp_part[dash + 1 ..]) orelse return error.InvalidCodepoint;
            try setOverride(lo, hi, width);
        } else {
            const cp = parseCp(cp_part) orelse return error.InvalidCodepoint;
            try setOverride(cp, cp, width);
        }
    }
}

fn parseCp(s: []const u8) ?u21 {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "U+") or std.mem.startsWith(u8, rest, "u+")) {
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) {
        rest = rest[2..];
    }
    if (rest.len == 0) return null;
    return std.fmt.parseInt(u21, rest, 16) catch null;
}

pub const ParseOverrideError = error{
    OverrideTableFull,
    InvalidEntry,
    InvalidCodepoint,
    InvalidWidth,
};

fn searchTable(key: u21, ranges: []const WidthRange) bool {
    if (ranges.len == 0) return false;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (key < ranges[mid].start) {
            hi = mid;
        } else if (key > ranges[mid].end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub const COMBINING_MAX = 8191;

fn isCombining(cp: u21) bool {
    if (cp < 0x0300) return cp >= 0x1160 and cp <= 0x11FF;
    if (cp >= 0x1100 and cp <= 0x115F) return false;
    if (cp == 0x3164) return false;
    return true;
}

const combining_mark_count = blk: {
    @setEvalBranchQuota(100000);
    var count: usize = 0;
    for (zero_width_ranges) |r| {
        var cp = r.start;
        while (cp <= r.end) : (cp += 1) {
            if (isCombining(cp)) count += 1;
        }
    }
    break :blk count;
};

const combining_marks: [combining_mark_count]u21 = blk: {
    @setEvalBranchQuota(100000);
    var buf: [combining_mark_count]u21 = undefined;
    var idx: usize = 0;
    for (zero_width_ranges) |r| {
        var cp = r.start;
        while (cp <= r.end) : (cp += 1) {
            if (isCombining(cp)) {
                buf[idx] = cp;
                idx += 1;
            }
        }
    }
    break :blk buf;
};

pub fn combiningIndex(cp: u21) u13 {
    if (combining_marks.len == 0) return 0;
    if (cp < combining_marks[0] or cp > combining_marks[combining_marks.len - 1]) return 0;
    var lo: usize = 0;
    var hi: usize = combining_marks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < combining_marks[mid]) {
            hi = mid;
        } else if (cp > combining_marks[mid]) {
            lo = mid + 1;
        } else {
            return @intCast(mid + 1);
        }
    }
    return 0;
}

pub fn combiningCodepoint(idx: u13) u21 {
    if (idx == 0 or idx > combining_marks.len) return 0;
    return combining_marks[idx - 1];
}

pub fn charWidth(cp: u21) u2 {
    // User overrides win first — these let the operator match whatever width
    // their terminal actually uses for ambiguous codepoints (bug #206).
    if (overrideWidth(cp)) |w| return w;

    // Fast path: ASCII printable + Latin-1 Supplement
    if (cp < 0x0300) {
        if (cp < 0x20 or (cp >= 0x7F and cp <= 0xA0)) return 0;
        return 1;
    }
    // Binary search in the non-trivial ranges table
    if (searchTable(cp, &zero_width_ranges)) return 0;
    if (searchTable(cp, &wide_ranges)) return 2;
    // Emoji-presentation codepoints that modern terminals (iTerm2, kitty,
    // Ghostty, WezTerm, Terminal.app) render as width 2 even though their
    // East-Asian-Width class is "ambiguous" or "neutral".  Misclassifying
    // these as width 1 makes the model cursor drift relative to the real
    // terminal, which is bug #206.
    if (searchTable(cp, &emoji_presentation_ranges)) return 2;

    return 1;
}

const zero_width_ranges = [_]WidthRange{
    // Combining Diacritical Marks
    .{ .start = 0x0300, .end = 0x036F, .width = 0 },
    .{ .start = 0x0483, .end = 0x0489, .width = 0 },
    .{ .start = 0x0591, .end = 0x05BD, .width = 0 },
    .{ .start = 0x05BF, .end = 0x05BF, .width = 0 },
    .{ .start = 0x05C1, .end = 0x05C2, .width = 0 },
    .{ .start = 0x05C4, .end = 0x05C5, .width = 0 },
    .{ .start = 0x05C7, .end = 0x05C7, .width = 0 },
    .{ .start = 0x0600, .end = 0x0605, .width = 0 },
    .{ .start = 0x0610, .end = 0x061A, .width = 0 },
    .{ .start = 0x061C, .end = 0x061C, .width = 0 },
    .{ .start = 0x064B, .end = 0x065F, .width = 0 },
    .{ .start = 0x0670, .end = 0x0670, .width = 0 },
    .{ .start = 0x06D6, .end = 0x06DD, .width = 0 },
    .{ .start = 0x06DF, .end = 0x06E4, .width = 0 },
    .{ .start = 0x06E7, .end = 0x06E8, .width = 0 },
    .{ .start = 0x06EA, .end = 0x06ED, .width = 0 },
    .{ .start = 0x070F, .end = 0x070F, .width = 0 },
    .{ .start = 0x0711, .end = 0x0711, .width = 0 },
    .{ .start = 0x0730, .end = 0x074A, .width = 0 },
    .{ .start = 0x07A6, .end = 0x07B0, .width = 0 },
    .{ .start = 0x07EB, .end = 0x07F3, .width = 0 },
    .{ .start = 0x07FD, .end = 0x07FD, .width = 0 },
    .{ .start = 0x0816, .end = 0x0819, .width = 0 },
    .{ .start = 0x081B, .end = 0x0823, .width = 0 },
    .{ .start = 0x0825, .end = 0x0827, .width = 0 },
    .{ .start = 0x0829, .end = 0x082D, .width = 0 },
    .{ .start = 0x0859, .end = 0x085B, .width = 0 },
    .{ .start = 0x0898, .end = 0x089F, .width = 0 },
    .{ .start = 0x08CA, .end = 0x08E1, .width = 0 },
    .{ .start = 0x08E3, .end = 0x0903, .width = 0 },
    .{ .start = 0x093A, .end = 0x093C, .width = 0 },
    .{ .start = 0x093E, .end = 0x094F, .width = 0 },
    .{ .start = 0x0951, .end = 0x0957, .width = 0 },
    .{ .start = 0x0962, .end = 0x0963, .width = 0 },
    .{ .start = 0x0981, .end = 0x0983, .width = 0 },
    .{ .start = 0x09BC, .end = 0x09BC, .width = 0 },
    .{ .start = 0x09BE, .end = 0x09C4, .width = 0 },
    .{ .start = 0x09C7, .end = 0x09C8, .width = 0 },
    .{ .start = 0x09CB, .end = 0x09CD, .width = 0 },
    .{ .start = 0x09D7, .end = 0x09D7, .width = 0 },
    .{ .start = 0x09E2, .end = 0x09E3, .width = 0 },
    .{ .start = 0x09FE, .end = 0x09FE, .width = 0 },
    .{ .start = 0x0A01, .end = 0x0A03, .width = 0 },
    .{ .start = 0x0A3C, .end = 0x0A3C, .width = 0 },
    .{ .start = 0x0A3E, .end = 0x0A42, .width = 0 },
    .{ .start = 0x0A47, .end = 0x0A48, .width = 0 },
    .{ .start = 0x0A4B, .end = 0x0A4D, .width = 0 },
    .{ .start = 0x0A51, .end = 0x0A51, .width = 0 },
    .{ .start = 0x0A70, .end = 0x0A71, .width = 0 },
    .{ .start = 0x0A75, .end = 0x0A75, .width = 0 },
    .{ .start = 0x0A81, .end = 0x0A83, .width = 0 },
    .{ .start = 0x0ABC, .end = 0x0ABC, .width = 0 },
    .{ .start = 0x0ABE, .end = 0x0AC5, .width = 0 },
    .{ .start = 0x0AC7, .end = 0x0AC9, .width = 0 },
    .{ .start = 0x0ACB, .end = 0x0ACD, .width = 0 },
    .{ .start = 0x0AE2, .end = 0x0AE3, .width = 0 },
    .{ .start = 0x0AFA, .end = 0x0AFF, .width = 0 },
    .{ .start = 0x0B01, .end = 0x0B03, .width = 0 },
    .{ .start = 0x0B3C, .end = 0x0B3F, .width = 0 },
    .{ .start = 0x0B41, .end = 0x0B44, .width = 0 },
    .{ .start = 0x0B4D, .end = 0x0B4D, .width = 0 },
    .{ .start = 0x0B55, .end = 0x0B56, .width = 0 },
    .{ .start = 0x0B62, .end = 0x0B63, .width = 0 },
    .{ .start = 0x0B82, .end = 0x0B82, .width = 0 },
    .{ .start = 0x0BBE, .end = 0x0BC2, .width = 0 },
    .{ .start = 0x0BC6, .end = 0x0BC8, .width = 0 },
    .{ .start = 0x0BCA, .end = 0x0BCD, .width = 0 },
    .{ .start = 0x0BD7, .end = 0x0BD7, .width = 0 },
    .{ .start = 0x0C00, .end = 0x0C04, .width = 0 },
    .{ .start = 0x0C3C, .end = 0x0C3C, .width = 0 },
    .{ .start = 0x0C3E, .end = 0x0C44, .width = 0 },
    .{ .start = 0x0C46, .end = 0x0C48, .width = 0 },
    .{ .start = 0x0C4A, .end = 0x0C4D, .width = 0 },
    .{ .start = 0x0C55, .end = 0x0C56, .width = 0 },
    .{ .start = 0x0C62, .end = 0x0C63, .width = 0 },
    .{ .start = 0x0C81, .end = 0x0C83, .width = 0 },
    .{ .start = 0x0CBC, .end = 0x0CBC, .width = 0 },
    .{ .start = 0x0CBE, .end = 0x0CC4, .width = 0 },
    .{ .start = 0x0CC6, .end = 0x0CC8, .width = 0 },
    .{ .start = 0x0CCA, .end = 0x0CCD, .width = 0 },
    .{ .start = 0x0CD5, .end = 0x0CD6, .width = 0 },
    .{ .start = 0x0CE2, .end = 0x0CE3, .width = 0 },
    .{ .start = 0x0D00, .end = 0x0D03, .width = 0 },
    .{ .start = 0x0D3B, .end = 0x0D3C, .width = 0 },
    .{ .start = 0x0D3E, .end = 0x0D44, .width = 0 },
    .{ .start = 0x0D4D, .end = 0x0D4D, .width = 0 },
    .{ .start = 0x0D57, .end = 0x0D57, .width = 0 },
    .{ .start = 0x0D62, .end = 0x0D63, .width = 0 },
    .{ .start = 0x0D81, .end = 0x0D83, .width = 0 },
    .{ .start = 0x0DCA, .end = 0x0DCA, .width = 0 },
    .{ .start = 0x0DCF, .end = 0x0DD4, .width = 0 },
    .{ .start = 0x0DD6, .end = 0x0DD6, .width = 0 },
    .{ .start = 0x0DD8, .end = 0x0DDF, .width = 0 },
    .{ .start = 0x0DF2, .end = 0x0DF3, .width = 0 },
    .{ .start = 0x0E31, .end = 0x0E31, .width = 0 },
    .{ .start = 0x0E34, .end = 0x0E3A, .width = 0 },
    .{ .start = 0x0E47, .end = 0x0E4E, .width = 0 },
    .{ .start = 0x0EB1, .end = 0x0EB1, .width = 0 },
    .{ .start = 0x0EB4, .end = 0x0EBC, .width = 0 },
    .{ .start = 0x0EC8, .end = 0x0ECD, .width = 0 },
    .{ .start = 0x0F18, .end = 0x0F19, .width = 0 },
    .{ .start = 0x0F35, .end = 0x0F35, .width = 0 },
    .{ .start = 0x0F37, .end = 0x0F37, .width = 0 },
    .{ .start = 0x0F39, .end = 0x0F39, .width = 0 },
    .{ .start = 0x0F3E, .end = 0x0F3F, .width = 0 },
    .{ .start = 0x0F71, .end = 0x0F84, .width = 0 },
    .{ .start = 0x0F86, .end = 0x0F87, .width = 0 },
    .{ .start = 0x0F8D, .end = 0x0F97, .width = 0 },
    .{ .start = 0x0F99, .end = 0x0FBC, .width = 0 },
    .{ .start = 0x0FC6, .end = 0x0FC6, .width = 0 },
    .{ .start = 0x102B, .end = 0x103E, .width = 0 },
    .{ .start = 0x1056, .end = 0x1059, .width = 0 },
    .{ .start = 0x105E, .end = 0x1060, .width = 0 },
    .{ .start = 0x1062, .end = 0x1064, .width = 0 },
    .{ .start = 0x1067, .end = 0x106D, .width = 0 },
    .{ .start = 0x1071, .end = 0x1074, .width = 0 },
    .{ .start = 0x1082, .end = 0x108D, .width = 0 },
    .{ .start = 0x108F, .end = 0x108F, .width = 0 },
    .{ .start = 0x109A, .end = 0x109D, .width = 0 },
    .{ .start = 0x1160, .end = 0x11FF, .width = 0 },
    .{ .start = 0x135D, .end = 0x135F, .width = 0 },
    .{ .start = 0x1712, .end = 0x1715, .width = 0 },
    .{ .start = 0x1732, .end = 0x1734, .width = 0 },
    .{ .start = 0x1752, .end = 0x1753, .width = 0 },
    .{ .start = 0x1772, .end = 0x1773, .width = 0 },
    .{ .start = 0x17B4, .end = 0x17D3, .width = 0 },
    .{ .start = 0x17DD, .end = 0x17DD, .width = 0 },
    .{ .start = 0x180B, .end = 0x180F, .width = 0 },
    .{ .start = 0x1885, .end = 0x1886, .width = 0 },
    .{ .start = 0x18A9, .end = 0x18A9, .width = 0 },
    .{ .start = 0x1920, .end = 0x192B, .width = 0 },
    .{ .start = 0x1930, .end = 0x193B, .width = 0 },
    .{ .start = 0x1A17, .end = 0x1A1B, .width = 0 },
    .{ .start = 0x1A55, .end = 0x1A5E, .width = 0 },
    .{ .start = 0x1A60, .end = 0x1A7C, .width = 0 },
    .{ .start = 0x1A7F, .end = 0x1A7F, .width = 0 },
    .{ .start = 0x1AB0, .end = 0x1ACE, .width = 0 },
    .{ .start = 0x1B00, .end = 0x1B04, .width = 0 },
    .{ .start = 0x1B34, .end = 0x1B44, .width = 0 },
    .{ .start = 0x1B6B, .end = 0x1B73, .width = 0 },
    .{ .start = 0x1B80, .end = 0x1B82, .width = 0 },
    .{ .start = 0x1BA1, .end = 0x1BAD, .width = 0 },
    .{ .start = 0x1BE6, .end = 0x1BF3, .width = 0 },
    .{ .start = 0x1C24, .end = 0x1C37, .width = 0 },
    .{ .start = 0x1CD0, .end = 0x1CD2, .width = 0 },
    .{ .start = 0x1CD4, .end = 0x1CE8, .width = 0 },
    .{ .start = 0x1CED, .end = 0x1CED, .width = 0 },
    .{ .start = 0x1CF4, .end = 0x1CF4, .width = 0 },
    .{ .start = 0x1CF7, .end = 0x1CF9, .width = 0 },
    .{ .start = 0x1DC0, .end = 0x1DFF, .width = 0 },
    .{ .start = 0x200B, .end = 0x200F, .width = 0 },
    .{ .start = 0x2028, .end = 0x202E, .width = 0 },
    .{ .start = 0x2060, .end = 0x2064, .width = 0 },
    .{ .start = 0x2066, .end = 0x206F, .width = 0 },
    .{ .start = 0x20D0, .end = 0x20F0, .width = 0 },
    .{ .start = 0x2CEF, .end = 0x2CF1, .width = 0 },
    .{ .start = 0x2D7F, .end = 0x2D7F, .width = 0 },
    .{ .start = 0x2DE0, .end = 0x2DFF, .width = 0 },
    .{ .start = 0xA66F, .end = 0xA672, .width = 0 },
    .{ .start = 0xA674, .end = 0xA67D, .width = 0 },
    .{ .start = 0xA69E, .end = 0xA69F, .width = 0 },
    .{ .start = 0xA6F0, .end = 0xA6F1, .width = 0 },
    .{ .start = 0xA802, .end = 0xA802, .width = 0 },
    .{ .start = 0xA806, .end = 0xA806, .width = 0 },
    .{ .start = 0xA80B, .end = 0xA80B, .width = 0 },
    .{ .start = 0xA823, .end = 0xA827, .width = 0 },
    .{ .start = 0xA82C, .end = 0xA82C, .width = 0 },
    .{ .start = 0xA880, .end = 0xA881, .width = 0 },
    .{ .start = 0xA8B4, .end = 0xA8C5, .width = 0 },
    .{ .start = 0xA8E0, .end = 0xA8F1, .width = 0 },
    .{ .start = 0xA8FF, .end = 0xA8FF, .width = 0 },
    .{ .start = 0xA926, .end = 0xA92D, .width = 0 },
    .{ .start = 0xA947, .end = 0xA953, .width = 0 },
    .{ .start = 0xA980, .end = 0xA983, .width = 0 },
    .{ .start = 0xA9B3, .end = 0xA9C0, .width = 0 },
    .{ .start = 0xA9E5, .end = 0xA9E5, .width = 0 },
    .{ .start = 0xAA29, .end = 0xAA36, .width = 0 },
    .{ .start = 0xAA43, .end = 0xAA43, .width = 0 },
    .{ .start = 0xAA4C, .end = 0xAA4D, .width = 0 },
    .{ .start = 0xAA7B, .end = 0xAA7D, .width = 0 },
    .{ .start = 0xAAB0, .end = 0xAAB0, .width = 0 },
    .{ .start = 0xAAB2, .end = 0xAAB4, .width = 0 },
    .{ .start = 0xAAB7, .end = 0xAAB8, .width = 0 },
    .{ .start = 0xAABE, .end = 0xAABF, .width = 0 },
    .{ .start = 0xAAC1, .end = 0xAAC1, .width = 0 },
    .{ .start = 0xAAEB, .end = 0xAAEF, .width = 0 },
    .{ .start = 0xAAF5, .end = 0xAAF6, .width = 0 },
    .{ .start = 0xABE3, .end = 0xABEA, .width = 0 },
    .{ .start = 0xABEC, .end = 0xABED, .width = 0 },
    .{ .start = 0xFB1E, .end = 0xFB1E, .width = 0 },
    .{ .start = 0xFE00, .end = 0xFE0F, .width = 0 },
    .{ .start = 0xFE20, .end = 0xFE2F, .width = 0 },
    .{ .start = 0xFEFF, .end = 0xFEFF, .width = 0 },
    .{ .start = 0xFFF9, .end = 0xFFFB, .width = 0 },
    .{ .start = 0x101FD, .end = 0x101FD, .width = 0 },
    .{ .start = 0x102E0, .end = 0x102E0, .width = 0 },
    .{ .start = 0x10376, .end = 0x1037A, .width = 0 },
    .{ .start = 0x10A01, .end = 0x10A03, .width = 0 },
    .{ .start = 0x10A05, .end = 0x10A06, .width = 0 },
    .{ .start = 0x10A0C, .end = 0x10A0F, .width = 0 },
    .{ .start = 0x10A38, .end = 0x10A3A, .width = 0 },
    .{ .start = 0x10A3F, .end = 0x10A3F, .width = 0 },
    .{ .start = 0x10AE5, .end = 0x10AE6, .width = 0 },
    .{ .start = 0x10D24, .end = 0x10D27, .width = 0 },
    .{ .start = 0x10EAB, .end = 0x10EAC, .width = 0 },
    .{ .start = 0x10F46, .end = 0x10F50, .width = 0 },
    .{ .start = 0x11000, .end = 0x11002, .width = 0 },
    .{ .start = 0x11038, .end = 0x11046, .width = 0 },
    .{ .start = 0x11070, .end = 0x11070, .width = 0 },
    .{ .start = 0x11073, .end = 0x11074, .width = 0 },
    .{ .start = 0x1107F, .end = 0x11082, .width = 0 },
    .{ .start = 0x110B0, .end = 0x110BA, .width = 0 },
    .{ .start = 0x110C2, .end = 0x110C2, .width = 0 },
    .{ .start = 0x11100, .end = 0x11102, .width = 0 },
    .{ .start = 0x11127, .end = 0x11134, .width = 0 },
    .{ .start = 0x11145, .end = 0x11146, .width = 0 },
    .{ .start = 0x11173, .end = 0x11173, .width = 0 },
    .{ .start = 0x11180, .end = 0x11182, .width = 0 },
    .{ .start = 0x111B3, .end = 0x111C0, .width = 0 },
    .{ .start = 0x111C9, .end = 0x111CC, .width = 0 },
    .{ .start = 0x111CE, .end = 0x111CF, .width = 0 },
    .{ .start = 0x1122C, .end = 0x11237, .width = 0 },
    .{ .start = 0x1123E, .end = 0x1123E, .width = 0 },
    .{ .start = 0x112DF, .end = 0x112EA, .width = 0 },
    .{ .start = 0x11300, .end = 0x11303, .width = 0 },
    .{ .start = 0x1133B, .end = 0x1133C, .width = 0 },
    .{ .start = 0x1133E, .end = 0x11344, .width = 0 },
    .{ .start = 0x11347, .end = 0x11348, .width = 0 },
    .{ .start = 0x1134B, .end = 0x1134D, .width = 0 },
    .{ .start = 0x11357, .end = 0x11357, .width = 0 },
    .{ .start = 0x11362, .end = 0x11363, .width = 0 },
    .{ .start = 0x11366, .end = 0x1136C, .width = 0 },
    .{ .start = 0x11370, .end = 0x11374, .width = 0 },
    .{ .start = 0x11435, .end = 0x11446, .width = 0 },
    .{ .start = 0x1145E, .end = 0x1145E, .width = 0 },
    .{ .start = 0x114B0, .end = 0x114C3, .width = 0 },
    .{ .start = 0x115AF, .end = 0x115B5, .width = 0 },
    .{ .start = 0x115B8, .end = 0x115C0, .width = 0 },
    .{ .start = 0x115DC, .end = 0x115DD, .width = 0 },
    .{ .start = 0x11630, .end = 0x11640, .width = 0 },
    .{ .start = 0x116AB, .end = 0x116B7, .width = 0 },
    .{ .start = 0x1171D, .end = 0x1172B, .width = 0 },
    .{ .start = 0x1182C, .end = 0x1183A, .width = 0 },
    .{ .start = 0x11930, .end = 0x11935, .width = 0 },
    .{ .start = 0x11937, .end = 0x11938, .width = 0 },
    .{ .start = 0x1193B, .end = 0x1193E, .width = 0 },
    .{ .start = 0x11940, .end = 0x11940, .width = 0 },
    .{ .start = 0x11942, .end = 0x11943, .width = 0 },
    .{ .start = 0x119D1, .end = 0x119D7, .width = 0 },
    .{ .start = 0x119DA, .end = 0x119E0, .width = 0 },
    .{ .start = 0x119E4, .end = 0x119E4, .width = 0 },
    .{ .start = 0x11A01, .end = 0x11A0A, .width = 0 },
    .{ .start = 0x11A33, .end = 0x11A39, .width = 0 },
    .{ .start = 0x11A3B, .end = 0x11A3E, .width = 0 },
    .{ .start = 0x11A47, .end = 0x11A47, .width = 0 },
    .{ .start = 0x11A51, .end = 0x11A5B, .width = 0 },
    .{ .start = 0x11A8A, .end = 0x11A99, .width = 0 },
    .{ .start = 0x11C2F, .end = 0x11C36, .width = 0 },
    .{ .start = 0x11C38, .end = 0x11C3F, .width = 0 },
    .{ .start = 0x11C92, .end = 0x11CA7, .width = 0 },
    .{ .start = 0x11CA9, .end = 0x11CB6, .width = 0 },
    .{ .start = 0x11D31, .end = 0x11D36, .width = 0 },
    .{ .start = 0x11D3A, .end = 0x11D3A, .width = 0 },
    .{ .start = 0x11D3C, .end = 0x11D3D, .width = 0 },
    .{ .start = 0x11D3F, .end = 0x11D45, .width = 0 },
    .{ .start = 0x11D47, .end = 0x11D47, .width = 0 },
    .{ .start = 0x11D8A, .end = 0x11D8E, .width = 0 },
    .{ .start = 0x11D90, .end = 0x11D91, .width = 0 },
    .{ .start = 0x11D93, .end = 0x11D97, .width = 0 },
    .{ .start = 0x11EF3, .end = 0x11EF6, .width = 0 },
    .{ .start = 0x16AF0, .end = 0x16AF4, .width = 0 },
    .{ .start = 0x16B30, .end = 0x16B36, .width = 0 },
    .{ .start = 0x16F4F, .end = 0x16F4F, .width = 0 },
    .{ .start = 0x16F51, .end = 0x16F87, .width = 0 },
    .{ .start = 0x16F8F, .end = 0x16F92, .width = 0 },
    .{ .start = 0x16FE4, .end = 0x16FE4, .width = 0 },
    .{ .start = 0x16FF0, .end = 0x16FF1, .width = 0 },
    .{ .start = 0x1BC9D, .end = 0x1BC9E, .width = 0 },
    .{ .start = 0x1BCA0, .end = 0x1BCA3, .width = 0 },
    .{ .start = 0x1D165, .end = 0x1D169, .width = 0 },
    .{ .start = 0x1D16D, .end = 0x1D172, .width = 0 },
    .{ .start = 0x1D17B, .end = 0x1D182, .width = 0 },
    .{ .start = 0x1D185, .end = 0x1D18B, .width = 0 },
    .{ .start = 0x1D1AA, .end = 0x1D1AD, .width = 0 },
    .{ .start = 0x1D242, .end = 0x1D244, .width = 0 },
    .{ .start = 0x1DA00, .end = 0x1DA36, .width = 0 },
    .{ .start = 0x1DA3B, .end = 0x1DA6C, .width = 0 },
    .{ .start = 0x1DA75, .end = 0x1DA75, .width = 0 },
    .{ .start = 0x1DA84, .end = 0x1DA84, .width = 0 },
    .{ .start = 0x1DA9B, .end = 0x1DA9F, .width = 0 },
    .{ .start = 0x1DAA1, .end = 0x1DAAF, .width = 0 },
    .{ .start = 0x1E000, .end = 0x1E006, .width = 0 },
    .{ .start = 0x1E008, .end = 0x1E018, .width = 0 },
    .{ .start = 0x1E01B, .end = 0x1E021, .width = 0 },
    .{ .start = 0x1E023, .end = 0x1E024, .width = 0 },
    .{ .start = 0x1E026, .end = 0x1E02A, .width = 0 },
    .{ .start = 0x1E130, .end = 0x1E136, .width = 0 },
    .{ .start = 0x1E2AE, .end = 0x1E2AE, .width = 0 },
    .{ .start = 0x1E2EC, .end = 0x1E2EF, .width = 0 },
    .{ .start = 0x1E8D0, .end = 0x1E8D6, .width = 0 },
    .{ .start = 0x1E944, .end = 0x1E94A, .width = 0 },
    .{ .start = 0xE0001, .end = 0xE0001, .width = 0 },
    .{ .start = 0xE0020, .end = 0xE007F, .width = 0 },
    .{ .start = 0xE0100, .end = 0xE01EF, .width = 0 },
};

const wide_ranges = [_]WidthRange{
    .{ .start = 0x1100, .end = 0x115F, .width = 2 },
    .{ .start = 0x2329, .end = 0x232A, .width = 2 },
    .{ .start = 0x2E80, .end = 0x303E, .width = 2 },
    .{ .start = 0x3041, .end = 0x33BF, .width = 2 },
    .{ .start = 0x3400, .end = 0x4DBF, .width = 2 },
    .{ .start = 0x4E00, .end = 0xA4CF, .width = 2 },
    .{ .start = 0xA960, .end = 0xA97C, .width = 2 },
    .{ .start = 0xAC00, .end = 0xD7A3, .width = 2 },
    .{ .start = 0xF900, .end = 0xFAFF, .width = 2 },
    .{ .start = 0xFE10, .end = 0xFE19, .width = 2 },
    .{ .start = 0xFE30, .end = 0xFE6F, .width = 2 },
    .{ .start = 0xFF01, .end = 0xFF60, .width = 2 },
    .{ .start = 0xFFE0, .end = 0xFFE6, .width = 2 },
    .{ .start = 0x1B000, .end = 0x1B2FF, .width = 2 },
    .{ .start = 0x1F000, .end = 0x1F02F, .width = 2 },
    .{ .start = 0x1F030, .end = 0x1F09F, .width = 2 },
    .{ .start = 0x1F0A0, .end = 0x1F0FF, .width = 2 },
    .{ .start = 0x1F100, .end = 0x1F64F, .width = 2 },
    .{ .start = 0x1F680, .end = 0x1F6FF, .width = 2 },
    .{ .start = 0x1F780, .end = 0x1F7FF, .width = 2 },
    .{ .start = 0x1F800, .end = 0x1F8FF, .width = 2 },
    .{ .start = 0x1F900, .end = 0x1F9FF, .width = 2 },
    .{ .start = 0x1FA00, .end = 0x1FA6F, .width = 2 },
    .{ .start = 0x1FA70, .end = 0x1FAFF, .width = 2 },
    .{ .start = 0x1FB00, .end = 0x1FBFF, .width = 2 },
    .{ .start = 0x20000, .end = 0x2FFFD, .width = 2 },
    .{ .start = 0x30000, .end = 0x3FFFD, .width = 2 },
};

// Codepoints that have emoji presentation and are rendered width 2 by
// modern terminals, even though their East-Asian-Width property is
// "ambiguous" or "neutral" (not in wide_ranges).  Without these, the model
// cursor advances by 1 while the real terminal advances by 2, drifting the
// cursor and mispositioning subsequent output (bug #206).  Variation
// selectors (U+FE0F) and skin-tone modifiers (U+1F3FB–U+1F3FF) are zero-width
// and handled by zero_width_ranges; here we list the base emoji themselves.
const emoji_presentation_ranges = [_]WidthRange{
    .{ .start = 0x231A, .end = 0x231B, .width = 2 }, // watch, hourglass
    .{ .start = 0x23E9, .end = 0x23FA, .width = 2 }, // various emoji symbols (shuffle, recycle, symbols)
    .{ .start = 0x23FC, .end = 0x23FE, .width = 2 }, // film frames, signal strength
    .{ .start = 0x2600, .end = 0x26FF, .width = 2 }, // Miscellaneous Symbols (sun, moon, weather, chess, etc.)
    .{ .start = 0x2700, .end = 0x27BF, .width = 2 }, // Dingbats (✅ ★ ♥ arrows, etc.)
    .{ .start = 0x2B00, .end = 0x2BFF, .width = 2 }, // Miscellaneous Symbols and Arrows
    .{ .start = 0x1F1E6, .end = 0x1F1FF, .width = 2 }, // regional indicators (flags)
    .{ .start = 0x1F300, .end = 0x1F5FF, .width = 2 }, // Symbols & Pictographs
    .{ .start = 0x1F650, .end = 0x1F67F, .width = 2 }, // enclosed-alphanum ext. pictographs
    .{ .start = 0x1F900, .end = 0x1F9FF, .width = 2 }, // Supplemental Symbols and Pictographs
    .{ .start = 0x1FA70, .end = 0x1FAFF, .width = 2 }, // Symbols and Pictographs Extended-A
};

test "charWidth: ASCII" {
    try std.testing.expectEqual(@as(u2, 1), charWidth('A'));
    try std.testing.expectEqual(@as(u2, 1), charWidth(' '));
    try std.testing.expectEqual(@as(u2, 1), charWidth('0'));
}

test "charWidth: control characters are zero-width" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x00));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x1F));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x7F));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x9F));
}

test "charWidth: Thai combining marks are zero-width" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E31)); // mai han akat
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E34)); // sara i
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E47)); // mai tai khu
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E48)); // mai ek
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E49)); // mai tho
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E4A)); // mai tri
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0E4B)); // mai chattawa
}

test "charWidth: Thai base characters are width 1" {
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x0E01)); // ko kai
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x0E01)); // ko kai
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x0E01)); // ko kai
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x0E01)); // ko kai
}

test "charWidth: combining diacritical marks are zero-width" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0300)); // grave accent
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0301)); // acute accent
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0308)); // diaeresis
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0327)); // cedilla
}

test "charWidth: CJK characters are wide" {
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x4E00)); // CJK unified ideograph
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x4E2D)); // zhong
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x4E3A)); // CJK
}

test "charWidth: fullwidth forms are wide" {
    try std.testing.expectEqual(@as(u2, 2), charWidth(0xFF01)); // fullwidth !
    try std.testing.expectEqual(@as(u2, 2), charWidth(0xFF21)); // fullwidth A
}

test "charWidth: emoji are wide" {
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x1F600)); // grin
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x1F602)); // joy
}

test "charWidth: emoji-presentation symbols are wide (bug #206)" {
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2705)); // white heavy check mark
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2714)); // heavy check mark
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2B50)); // star
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2764)); // heavy black heart
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2600)); // black sun with rays
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2601)); // cloud
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x231A)); // wristwatch
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x23E9)); // reverse button
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2603)); // snowman
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x1F1E6)); // regional indicator A (flag)
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x1F650)); // enclosed A in negative squared
}

test "charWidth: ZWJ and variation selectors are zero-width" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(u2, 0), charWidth(0xFE0F)); // variation selector
}

test "charWidth: Hangul Jamo are wide (bug #104)" {
    try std.testing.expectEqual(@as(u4, 2), charWidth(0x1100));
    try std.testing.expectEqual(@as(u4, 2), charWidth(0x115F));
    try std.testing.expectEqual(@as(u4, 2), charWidth(0x1102));
    try std.testing.expectEqual(@as(u4, 0), charWidth(0x1160)); // Jungseong — still zero-width
    try std.testing.expectEqual(@as(u4, 0), charWidth(0x11FF)); // Jongseong — still zero-width
}

test "charWidth: sorted tables invariant" {
    for (zero_width_ranges[1..], 0..) |r, i| {
        try std.testing.expect(zero_width_ranges[i].end < r.start);
    }
    for (wide_ranges[1..], 0..) |r, i| {
        try std.testing.expect(wide_ranges[i].end < r.start);
    }
    for (emoji_presentation_ranges[1..], 0..) |r, i| {
        try std.testing.expect(emoji_presentation_ranges[i].end < r.start);
    }
}

test "charWidth: codepoint-widths override (bug #206)" {
    // Default: U+2705 is a width-2 emoji symbol.
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2705));
    // A terminal that renders it as width 1 can override it.
    try applyCodepointWidths(std.testing.allocator, "U+2705=1");
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x2705));
    // Ranges work too.
    try applyCodepointWidths(std.testing.allocator, "U+2600-U+26FF=1");
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x2600));
    try std.testing.expectEqual(@as(u2, 1), charWidth(0x26FF));
    // And we can restore the default by clearing.
    try applyCodepointWidths(std.testing.allocator, "");
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2705));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x2600));
}
