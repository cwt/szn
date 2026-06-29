const std = @import("std");
const testing = std.testing;
const char_width = @import("char_width.zig");
const Cell = @import("grid.zig").Cell;

/// Returns true if cp is in the Thai block (U+0E00–U+0E7F).
pub fn isThai(cp: u21) bool {
    return cp >= 0x0E00 and cp <= 0x0E7F;
}

/// Returns true if cp is a Thai combining mark (GC=Mn, zero-width).
///
/// These marks attach above or below a base character and are stored
/// in the comb1/comb2 fields of the preceding Cell.
///
/// Note: FONGMAN (U+0E4F) is punctuation (GC=Po), not a combining mark.
/// SARA AM (U+0E33) is a precomposed vowel (GC=Lo), not a combining mark.
pub fn isThaiCombining(cp: u21) bool {
    return switch (cp) {
        0x0E31, // MAI HAN AKAT      ◌ั
        0x0E34, // SARA I             ◌ิ
        0x0E35, // SARA II            ◌ี
        0x0E36, // SARA UE            ◌ึ
        0x0E37, // SARA UEE           ◌ื
        0x0E38, // SARA U             ◌ุ
        0x0E39, // SARA UU            ◌ู
        0x0E3A, // PHINTHU            ◌ฺ
        0x0E47, // MAITAIKHU          ◌็
        0x0E48, // MAI EK             ◌่
        0x0E49, // MAI THO            ◌้
        0x0E4A, // MAI TRI            ◌๊
        0x0E4B, // MAI CHATTAWA       ◌๋
        0x0E4C, // THANTHAKHAT        ◌์
        0x0E4D, // NIKHAHIT           ◌ํ
        0x0E4E, // YAMAKKAN           ◌๎
        => true,
        else => false,
    };
}

/// Returns true if cp is a Thai leading vowel (U+0E40–U+0E44).
///
/// These appear before the base consonant in a syllable:
///   เ(U+0E40) แ(U+0E41) โ(U+0E42) ใ(U+0E43) ไ(U+0E44)
pub fn isThaiLeadingVowel(cp: u21) bool {
    return cp >= 0x0E40 and cp <= 0x0E44;
}

/// Returns true if cp is a Thai following vowel.
///
/// These appear after the base consonant:
///   U+0E30  SARA A        ◌ะ
///   U+0E32  SARA AA       ◌า
///   U+0E33  SARA AM       ◌ำ  (precomposed: base + NIKHAHIT)
///   U+0E45  LAKKHANGYAO   ๅ   (vowel length marker, extends SARA AA)
pub fn isThaiFollowingVowel(cp: u21) bool {
    return switch (cp) {
        0x0E30, 0x0E32, 0x0E33, 0x0E45 => true,
        else => false,
    };
}

/// Returns true if cp is a Thai right-attaching mark.
///
/// These attach to the preceding base/vowel cell and must never be
/// split onto a new line. They occupy their own cell (width 1) but
/// form a single visual cluster with the preceding character:
///   U+0E2F  PAIYANNOI    ฯ   (abbreviation marker)
///   U+0E46  MAI YAMOK    ๆ   (repetition mark)
pub fn isThaiRightAttaching(cp: u21) bool {
    return switch (cp) {
        0x0E2F, 0x0E46 => true,
        else => false,
    };
}

/// Returns true if cp is a Thai base character (width 1, non-vowel,
/// non-combining, non-attaching).
///
/// A base is any Thai codepoint with width 1 that is not a combining mark,
/// leading vowel, following vowel, or right-attaching mark. This includes
/// consonants, punctuation (FONGMAN, ANG KHANKHU, KHOMUT), digits,
/// and the BAHT currency symbol.
pub fn isThaiBase(cp: u21) bool {
    return isThai(cp) and
        !isThaiCombining(cp) and
        !isThaiLeadingVowel(cp) and
        !isThaiFollowingVowel(cp) and
        !isThaiRightAttaching(cp) and
        char_width.charWidth(cp) == 1;
}

/// Find the end of a Thai visual cluster starting at position `start`.
///
/// A Thai cluster in the grid has the form:
///   [leading vowel] + base + [following vowel] + [right-attaching marks]
///
/// Combining marks (tone marks, vowel signs) are stored in the comb1/comb2
/// fields of the base or following-vowel cell, not as separate cells.
///
/// Right-attaching marks (PAIYANNOI, MAI YAMOK) occupy their own cells
/// but are consumed into the cluster so they are never split from the
/// preceding syllable.
///
/// Returns the index after the last cell belonging to the cluster.
/// If the cell at `start` is not the start of a Thai cluster, returns
/// `start + 1`.
pub fn findThaiClusterEnd(line: []const Cell, start: usize) usize {
    if (start >= line.len) return start;

    const cp = line[start].char;
    if (!isThai(cp)) return start + 1;

    var pos = start;

    // Step past an optional leading vowel
    if (isThaiLeadingVowel(cp)) {
        pos += 1;
        if (pos >= line.len) return start + 1;
    }

    // Current cell must be a base character. Right-attaching marks
    // are not valid cluster starts (they attach to a preceding base).
    const base_cp = line[pos].char;
    if (!isThaiBase(base_cp)) {
        return start + 1;
    }

    // Advance past the base
    pos += 1;
    if (pos >= line.len) return pos;

    // Check for an optional following vowel
    if (isThaiFollowingVowel(line[pos].char)) {
        pos += 1;
    }

    // Consume any trailing right-attaching marks
    while (pos < line.len and isThaiRightAttaching(line[pos].char)) {
        pos += 1;
    }

    return pos;
}

// ── Tests ──

test "isThai: within range" {
    try testing.expect(isThai(0x0E01)); // KO KAI
    try testing.expect(isThai(0x0E3F)); // BAHT
    try testing.expect(isThai(0x0E5B)); // KHOMUT
}

test "isThai: outside range" {
    try testing.expect(!isThai(0x0000));
    try testing.expect(!isThai(0x0DFF));
    try testing.expect(!isThai(0x0E80));
    try testing.expect(!isThai(0x10FF));
}

test "isThaiCombining: all marks" {
    try testing.expect(isThaiCombining(0x0E31));
    try testing.expect(isThaiCombining(0x0E34));
    try testing.expect(isThaiCombining(0x0E35));
    try testing.expect(isThaiCombining(0x0E36));
    try testing.expect(isThaiCombining(0x0E37));
    try testing.expect(isThaiCombining(0x0E38));
    try testing.expect(isThaiCombining(0x0E39));
    try testing.expect(isThaiCombining(0x0E3A));
    try testing.expect(isThaiCombining(0x0E47));
    try testing.expect(isThaiCombining(0x0E48));
    try testing.expect(isThaiCombining(0x0E49));
    try testing.expect(isThaiCombining(0x0E4A));
    try testing.expect(isThaiCombining(0x0E4B));
    try testing.expect(isThaiCombining(0x0E4C));
    try testing.expect(isThaiCombining(0x0E4D));
    try testing.expect(isThaiCombining(0x0E4E));
}

test "isThaiCombining: FONGMAN and SARA AM are not combining" {
    try testing.expect(!isThaiCombining(0x0E4F)); // FONGMAN  — Po, not Mn
    try testing.expect(!isThaiCombining(0x0E33)); // SARA AM — Lo, not Mn
}

test "isThaiLeadingVowel: all five" {
    try testing.expect(isThaiLeadingVowel(0x0E40));
    try testing.expect(isThaiLeadingVowel(0x0E41));
    try testing.expect(isThaiLeadingVowel(0x0E42));
    try testing.expect(isThaiLeadingVowel(0x0E43));
    try testing.expect(isThaiLeadingVowel(0x0E44));
    try testing.expect(!isThaiLeadingVowel(0x0E3F));
    try testing.expect(!isThaiLeadingVowel(0x0E45));
}

test "isThaiFollowingVowel: all four" {
    try testing.expect(isThaiFollowingVowel(0x0E30)); // SARA A
    try testing.expect(isThaiFollowingVowel(0x0E32)); // SARA AA
    try testing.expect(isThaiFollowingVowel(0x0E33)); // SARA AM
    try testing.expect(isThaiFollowingVowel(0x0E45)); // LAKKHANGYAO
    try testing.expect(!isThaiFollowingVowel(0x0E31));
    try testing.expect(!isThaiFollowingVowel(0x0E01));
}

test "isThaiRightAttaching: PAIYANNOI and MAI YAMOK" {
    try testing.expect(isThaiRightAttaching(0x0E2F)); // PAIYANNOI
    try testing.expect(isThaiRightAttaching(0x0E46)); // MAI YAMOK
    try testing.expect(!isThaiRightAttaching(0x0E01)); // KO KAI
    try testing.expect(!isThaiRightAttaching(0x0E40)); // leading vowel
    try testing.expect(!isThaiRightAttaching(0x0E30)); // following vowel
}

test "isThaiBase: consonants, digits, punctuation" {
    try testing.expect(isThaiBase(0x0E01)); // KO KAI
    try testing.expect(isThaiBase(0x0E3F)); // BAHT
    try testing.expect(isThaiBase(0x0E4F)); // FONGMAN
    try testing.expect(isThaiBase(0x0E50)); // digit 0
    try testing.expect(isThaiBase(0x0E59)); // digit 9
    try testing.expect(isThaiBase(0x0E5A)); // ANG KHANKHU
    try testing.expect(isThaiBase(0x0E5B)); // KHOMUT
}

test "isThaiBase: not vowels, combining, or attaching" {
    try testing.expect(!isThaiBase(0x0E31)); // MAI HAN AKAT   (combining)
    try testing.expect(!isThaiBase(0x0E34)); // SARA I         (combining)
    try testing.expect(!isThaiBase(0x0E40)); // leading vowel
    try testing.expect(!isThaiBase(0x0E30)); // SARA A         (following vowel)
    try testing.expect(!isThaiBase(0x0E32)); // SARA AA        (following vowel)
    try testing.expect(!isThaiBase(0x0E33)); // SARA AM        (following vowel)
    try testing.expect(!isThaiBase(0x0E45)); // LAKKHANGYAO    (following vowel)
    try testing.expect(!isThaiBase(0x0E2F)); // PAIYANNOI      (right-attaching)
    try testing.expect(!isThaiBase(0x0E46)); // MAI YAMOK      (right-attaching)
}

test "isThaiBase: non-Thai chars are not base" {
    try testing.expect(!isThaiBase('A'));
    try testing.expect(!isThaiBase(0x4E00));
    try testing.expect(!isThaiBase(0x0301));
}

test "findThaiClusterEnd: non-Thai returns start+1" {
    const line = [_]Cell{Cell.withChar('A')};
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: empty line returns start" {
    const line = [_]Cell{};
    try testing.expectEqual(@as(usize, 0), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base only" {
    var line = [_]Cell{Cell.withChar(0x0E01)}; // KO KAI
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: leading vowel + base" {
    var line = [_]Cell{
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar(0x0E01), // KO KAI
    };
    try testing.expectEqual(@as(usize, 2), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base + following vowel" {
    var line = [_]Cell{
        Cell.withChar(0x0E01), // KO KAI
        Cell.withChar(0x0E32), // SARA AA
    };
    try testing.expectEqual(@as(usize, 2), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: leading vowel + base + following vowel" {
    var line = [_]Cell{
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar(0x0E01), // KO KAI
        Cell.withChar(0x0E32), // SARA AA
    };
    try testing.expectEqual(@as(usize, 3), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: leading vowel at end of line" {
    var line = [_]Cell{Cell.withChar(0x0E40)}; // SARA E at end — no base follows
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: start at following vowel alone" {
    var line = [_]Cell{Cell.withChar(0x0E32)}; // SARA AA alone
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base with combining marks in comb fields" {
    // Combining marks are stored in comb1/comb2 of the base cell,
    // not as separate cells. The cluster extent is the same.
    var line = [_]Cell{
        Cell.withChar(0x0E01), // KO KAI
    };
    line[0].comb1 = 0x0E34; // SARA I
    line[0].comb2 = 0x0E48; // MAI EK
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: leading vowel + base + comb marks on base" {
    var line = [_]Cell{
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar(0x0E01), // KO KAI
    };
    line[1].comb1 = 0x0E34; // SARA I
    line[1].comb2 = 0x0E48; // MAI EK
    try testing.expectEqual(@as(usize, 2), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: cluster does not cross non-Thai boundary" {
    var line = [_]Cell{
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar('A'), // non-Thai — cluster ends here
    };
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: mid-line start skips leading chars correctly" {
    var line = [_]Cell{
        Cell.withChar('A'), // non-Thai
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar(0x0E01), // KO KAI
    };
    try testing.expectEqual(@as(usize, 3), findThaiClusterEnd(&line, 1));
}

test "findThaiClusterEnd: LAKKHANGYAO alone" {
    // LAKKHANGYAO is a following vowel — it's not a cluster start by itself.
    var line = [_]Cell{Cell.withChar(0x0E45)};
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base + MAI YAMOK" {
    var line = [_]Cell{
        Cell.withChar(0x0E17), // THO THAHAN
        Cell.withChar(0x0E46), // MAI YAMOK
    };
    try testing.expectEqual(@as(usize, 2), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base + PAIYANNOI" {
    var line = [_]Cell{
        Cell.withChar(0x0E01), // KO KAI
        Cell.withChar(0x0E2F), // PAIYANNOI
    };
    try testing.expectEqual(@as(usize, 2), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: leading vowel + base + MAI YAMOK" {
    var line = [_]Cell{
        Cell.withChar(0x0E40), // SARA E
        Cell.withChar(0x0E17), // THO THAHAN
        Cell.withChar(0x0E46), // MAI YAMOK
    };
    try testing.expectEqual(@as(usize, 3), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: base + following vowel + MAI YAMOK" {
    var line = [_]Cell{
        Cell.withChar(0x0E01), // KO KAI
        Cell.withChar(0x0E32), // SARA AA
        Cell.withChar(0x0E46), // MAI YAMOK
    };
    try testing.expectEqual(@as(usize, 3), findThaiClusterEnd(&line, 0));
}

test "findThaiClusterEnd: right-attaching mark at start returns start+1" {
    var line = [_]Cell{
        Cell.withChar(0x0E46), // MAI YAMOK at start — no base before it
        Cell.withChar(0x0E01), // KO KAI
    };
    try testing.expectEqual(@as(usize, 1), findThaiClusterEnd(&line, 0));
}
