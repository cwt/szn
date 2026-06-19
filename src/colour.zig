const std = @import("std");
const testing = std.testing;

pub const Tag = enum(u8) {
    indexed,
    rgb,
    default_,
    terminal,
};

pub const Colour = packed struct(u32) {
    tag: Tag,
    value: u24,

    pub fn fromRgb(r: u8, g: u8, b: u8) Colour {
        const rgb: u24 = @as(u24, r) << 16 | @as(u24, g) << 8 | @as(u24, b);
        return .{ .tag = .rgb, .value = rgb };
    }

    pub fn fromIndexed(n: u8) Colour {
        return .{ .tag = .indexed, .value = n };
    }

    pub fn default_() Colour {
        return .{ .tag = .default_, .value = 0 };
    }

    pub fn terminal() Colour {
        return .{ .tag = .terminal, .value = 0 };
    }

    pub fn toRgb(self: Colour) ?[3]u8 {
        return switch (self.tag) {
            .rgb => .{
                @truncate(self.value >> 16),
                @truncate(self.value >> 8),
                @truncate(self.value),
            },
            .indexed => indexedToRgb(@truncate(self.value)),
            .default_, .terminal => null,
        };
    }

    pub fn fmt(self: Colour, buf: []u8) []const u8 {
        return switch (self.tag) {
            .rgb => {
                const rgb = self.toRgb().?;
                _ = std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch return "<err>";
                return std.mem.sliceTo(buf, 0);
            },
            .indexed => {
                _ = std.fmt.bufPrint(buf, "colour{d}", .{@as(u8, @truncate(self.value))}) catch return "<err>";
                return std.mem.sliceTo(buf, 0);
            },
            .default_ => @as([]const u8, "default"),
            .terminal => "terminal",
        };
    }
};

pub const ParseError = error{
    InvalidHexColour,
    InvalidIndexedColour,
    UnknownColourName,
};

pub fn parse(s: []const u8) ParseError!Colour {
    if (s.len == 0) return ParseError.UnknownColourName;

    if (s[0] == '#') {
        if (s.len != 7) return ParseError.InvalidHexColour;
        const r = try hexByte(s[1..3]);
        const g = try hexByte(s[3..5]);
        const b = try hexByte(s[5..7]);
        return Colour.fromRgb(r, g, b);
    }

    if (std.ascii.eqlIgnoreCase(s, "default")) {
        return Colour.default_();
    }
    if (std.ascii.eqlIgnoreCase(s, "terminal")) {
        return Colour.terminal();
    }

    if (std.ascii.startsWithIgnoreCase(s, "colour")) {
        const n = std.fmt.parseInt(u8, s[6..], 10) catch return ParseError.InvalidIndexedColour;
        return Colour.fromIndexed(n);
    }
    if (std.ascii.startsWithIgnoreCase(s, "color")) {
        const n = std.fmt.parseInt(u8, s[5..], 10) catch return ParseError.InvalidIndexedColour;
        return Colour.fromIndexed(n);
    }

    inline for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(s, entry.name)) {
            return if (entry.is_bright)
                Colour.fromIndexed(entry.index + 90)
            else
                Colour.fromIndexed(entry.index);
        }
    }

    return ParseError.UnknownColourName;
}

fn hexByte(hex: []const u8) !u8 {
    if (hex.len < 2) return ParseError.InvalidHexColour;
    return (try hexNibble(hex[0])) << 4 | try hexNibble(hex[1]);
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => ParseError.InvalidHexColour,
    };
}

const NamedEntry = struct {
    name: []const u8,
    index: u8,
    is_bright: bool,
};

const named = [_]NamedEntry{
    .{ .name = "black", .index = 0, .is_bright = false },
    .{ .name = "red", .index = 1, .is_bright = false },
    .{ .name = "green", .index = 2, .is_bright = false },
    .{ .name = "yellow", .index = 3, .is_bright = false },
    .{ .name = "blue", .index = 4, .is_bright = false },
    .{ .name = "magenta", .index = 5, .is_bright = false },
    .{ .name = "cyan", .index = 6, .is_bright = false },
    .{ .name = "white", .index = 7, .is_bright = false },
    .{ .name = "brightblack", .index = 0, .is_bright = true },
    .{ .name = "brightred", .index = 1, .is_bright = true },
    .{ .name = "brightgreen", .index = 2, .is_bright = true },
    .{ .name = "brightyellow", .index = 3, .is_bright = true },
    .{ .name = "brightblue", .index = 4, .is_bright = true },
    .{ .name = "brightmagenta", .index = 5, .is_bright = true },
    .{ .name = "brightcyan", .index = 6, .is_bright = true },
    .{ .name = "brightwhite", .index = 7, .is_bright = true },
    // "default" and "terminal" handled separately before named lookup
};

fn indexedToRgb(n: u8) ?[3]u8 {
    if (n < 16) {
        return ansiPalette[n];
    }
    if (n < 232) {
        const i = n - 16;
        const r = cubeValue(@truncate(i / 36));
        const g = cubeValue(@truncate((i % 36) / 6));
        const b = cubeValue(@truncate(i % 6));
        return .{ r, g, b };
    }
    // Greyscale 232-255
    const v: u8 = @intCast(8 + (n - 232) * 10);
    return .{ v, v, v };
}

fn cubeValue(i: u6) u8 {
    return switch (i) {
        0 => 0,
        1 => 0x5f,
        2 => 0x87,
        3 => 0xaf,
        4 => 0xd7,
        5 => 0xff,
        else => 0,
    };
}

const ansiPalette = [_][3]u8{
    .{ 0x00, 0x00, 0x00 }, // black
    .{ 0x80, 0x00, 0x00 }, // red
    .{ 0x00, 0x80, 0x00 }, // green
    .{ 0x80, 0x80, 0x00 }, // yellow
    .{ 0x00, 0x00, 0x80 }, // blue
    .{ 0x80, 0x00, 0x80 }, // magenta
    .{ 0x00, 0x80, 0x80 }, // cyan
    .{ 0xc0, 0xc0, 0xc0 }, // white
    .{ 0x80, 0x80, 0x80 }, // bright black
    .{ 0xff, 0x00, 0x00 }, // bright red
    .{ 0x00, 0xff, 0x00 }, // bright green
    .{ 0xff, 0xff, 0x00 }, // bright yellow
    .{ 0x00, 0x00, 0xff }, // bright blue
    .{ 0xff, 0x00, 0xff }, // bright magenta
    .{ 0x00, 0xff, 0xff }, // bright cyan
    .{ 0xff, 0xff, 0xff }, // bright white
};

// ── Tests ──

test "parse hex colour #FF0000" {
    const c = try parse("#FF0000");
    try testing.expectEqual(Tag.rgb, c.tag);
    try testing.expectEqualDeep(.{ 0xFF, 0x00, 0x00 }, c.toRgb().?);
}

test "parse hex colour #00ff00" {
    const c = try parse("#00ff00");
    try testing.expectEqualDeep(.{ 0x00, 0xFF, 0x00 }, c.toRgb().?);
}

test "parse hex colour #0000ff" {
    const c = try parse("#0000ff");
    try testing.expectEqualDeep(.{ 0x00, 0x00, 0xFF }, c.toRgb().?);
}

test "parse hex colour black" {
    const c = try parse("#000000");
    try testing.expectEqualDeep(.{ 0x00, 0x00, 0x00 }, c.toRgb().?);
}

test "reject invalid hex length" {
    try testing.expectError(ParseError.InvalidHexColour, parse("#FFF"));
    try testing.expectError(ParseError.InvalidHexColour, parse("#"));
}

test "reject invalid hex chars" {
    try testing.expectError(ParseError.InvalidHexColour, parse("#GG0000"));
    try testing.expectError(ParseError.InvalidHexColour, parse("#-0ff00"));
}

test "parse indexed colour 0" {
    const c = try parse("colour0");
    try testing.expectEqual(Tag.indexed, c.tag);
    try testing.expectEqual(0, @as(u8, @truncate(c.value)));
}

test "parse indexed colour 255" {
    const c = try parse("colour255");
    try testing.expectEqual(Tag.indexed, c.tag);
    try testing.expectEqual(255, @as(u8, @truncate(c.value)));
}

test "parse indexed colour with 'color' spelling" {
    const c = try parse("color231");
    try testing.expectEqual(Tag.indexed, c.tag);
    try testing.expectEqual(231, @as(u8, @truncate(c.value)));
}

test "reject out of range indexed" {
    try testing.expectError(ParseError.InvalidIndexedColour, parse("colour256"));
}

test "parse named colour red" {
    const c = try parse("red");
    try testing.expectEqual(Tag.indexed, c.tag);
}

test "parse named colour brightgreen" {
    const c = try parse("brightgreen");
    try testing.expectEqual(Tag.indexed, c.tag);
    try testing.expectEqual(92, @as(u8, @truncate(c.value)));
}

test "parse default" {
    const c = try parse("default");
    try testing.expectEqual(Tag.default_, c.tag);
}

test "parse terminal" {
    const c = try parse("terminal");
    try testing.expectEqual(Tag.terminal, c.tag);
}

test "reject unknown colour name" {
    try testing.expectError(ParseError.UnknownColourName, parse("DarkSlateGray4"));
    try testing.expectError(ParseError.UnknownColourName, parse("blanchedalmond"));
    try testing.expectError(ParseError.UnknownColourName, parse(""));
}

test "indexed colour 0-15 ANSI palette" {
    const expected = [_][3]u8{
        .{ 0x00, 0x00, 0x00 },
        .{ 0x80, 0x00, 0x00 },
        .{ 0x00, 0x80, 0x00 },
        .{ 0x80, 0x80, 0x00 },
        .{ 0x00, 0x00, 0x80 },
        .{ 0x80, 0x00, 0x80 },
        .{ 0x00, 0x80, 0x80 },
        .{ 0xc0, 0xc0, 0xc0 },
    };
    for (0..8) |i| {
        const c = Colour.fromIndexed(@intCast(i));
        try testing.expectEqualDeep(expected[i], c.toRgb().?);
    }
}

test "indexed colour 16-231 6x6x6 cube" {
    const c = Colour.fromIndexed(16);
    try testing.expectEqualDeep(.{ 0x00, 0x00, 0x00 }, c.toRgb().?);

    const c2 = Colour.fromIndexed(46);
    try testing.expectEqualDeep(.{ 0x00, 0xff, 0x00 }, c2.toRgb().?);

    const c3 = Colour.fromIndexed(231);
    try testing.expectEqualDeep(.{ 0xff, 0xff, 0xff }, c3.toRgb().?);
}

test "indexed colour 232-255 greyscale" {
    const c = Colour.fromIndexed(232);
    try testing.expectEqualDeep(.{ 0x08, 0x08, 0x08 }, c.toRgb().?);

    const c2 = Colour.fromIndexed(255);
    try testing.expectEqualDeep(.{ 0xee, 0xee, 0xee }, c2.toRgb().?);
}

test "default colour has no RGB" {
    const c = Colour.default_();
    try testing.expectEqual(@as(?[3]u8, null), c.toRgb());
}

test "terminal colour has no RGB" {
    const c = Colour.terminal();
    try testing.expectEqual(@as(?[3]u8, null), c.toRgb());
}

test "format hex colour" {
    const c = Colour.fromRgb(0xFF, 0x00, 0x80);
    try testing.expectEqual(@as(u24, 0xFF0080), c.value);
    try testing.expectEqual(Tag.rgb, c.tag);
}

test "format indexed colour" {
    const c = Colour.fromIndexed(42);
    try testing.expectEqual(@as(u24, 42), c.value);
    try testing.expectEqual(Tag.indexed, c.tag);
}

test "format default colour" {
    const c = Colour.default_();
    try testing.expectEqual(Tag.default_, c.tag);
}
