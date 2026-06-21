const std = @import("std");
const testing = std.testing;

pub const Modifier = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    _padding: u4 = 0,
};

pub const Function = enum(u8) {
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
};

pub const Arrow = enum(u8) {
    up, down, left, right,
};

pub const Special = enum(u8) {
    tab,
    btab,
    enter,
    escape,
    backspace,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete_,
};

pub const MouseButton = enum(u8) {
    left,
    middle,
    right,
    release,
    scroll_up,
    scroll_down,
};

pub const Key = union(enum) {
    char: struct { code: u21, mod: Modifier = .{} },
    function: struct { key: Function, mod: Modifier = .{} },
    arrow: struct { key: Arrow, mod: Modifier = .{} },
    special: struct { key: Special, mod: Modifier = .{} },
    mouse: struct {
        button: MouseButton,
        x: u32,
        y: u32,
        mod: Modifier = .{},
    },
};

const ParseError = error{
    InvalidCsi,
    UnknownKey,
};

/// Parse a CSI sequence (without the leading `\e[`) into a Key.
/// Handles standard VT sequences, xterm modified keys, and kitty extended protocol.
pub fn parseCsi(seq: []const u8) ParseError!Key {
    if (seq.len == 0) return error.InvalidCsi;

    // Extract modifier parameter if present (e.g., `1;5A` -> param=5, final='A')
    const semicolon = std.mem.indexOfScalar(u8, seq, ';');
    const final = if (semicolon) |pos| if (pos + 1 < seq.len) seq[seq.len - 1] else 0 else seq[seq.len - 1];
    const mod_param: ?u8 = if (semicolon) |pos| blk: {
        const param_str = seq[pos + 1 .. seq.len - 1];
        if (param_str.len == 0) break :blk null;
        break :blk std.fmt.parseInt(u8, param_str, 10) catch null;
    } else null;

    // Xterm uses 1-based modifiers (1=none, 2=shift, 3=alt, ...).
    // Convert to 0-based bitmask: shift=1, alt=2, ctrl=4, meta=8.
    const mod = if (mod_param) |mp| blk: {
        const bits = if (final == 'u') mp else if (mp > 0) mp - 1 else mp;
        break :blk Modifier{
            .shift = bits & 1 != 0,
            .alt = bits & 2 != 0,
            .ctrl = bits & 4 != 0,
            .meta = bits & 8 != 0,
        };
    } else Modifier{};

    // CSI final byte determines the key
    switch (final) {
        'A' => return Key{ .arrow = .{ .key = .up, .mod = mod } },
        'B' => return Key{ .arrow = .{ .key = .down, .mod = mod } },
        'C' => return Key{ .arrow = .{ .key = .right, .mod = mod } },
        'D' => return Key{ .arrow = .{ .key = .left, .mod = mod } },
        'H' => return Key{ .special = .{ .key = .home, .mod = mod } },
        'F' => return Key{ .special = .{ .key = .end, .mod = mod } },
        'Z' => return Key{ .special = .{ .key = .btab, .mod = mod } },
        '~' => {
            // Find the parameter number before '~'
            const tilde = std.mem.lastIndexOfScalar(u8, seq, '~') orelse return error.InvalidCsi;
            const num_str = seq[0..tilde];
            const num = std.fmt.parseInt(u8, num_str, 10) catch return error.InvalidCsi;

            return switch (num) {
                1 => Key{ .special = .{ .key = .home, .mod = mod } },
                2 => Key{ .special = .{ .key = .insert, .mod = mod } },
                3 => Key{ .special = .{ .key = .delete_, .mod = mod } },
                4 => Key{ .special = .{ .key = .end, .mod = mod } },
                5 => Key{ .special = .{ .key = .page_up, .mod = mod } },
                6 => Key{ .special = .{ .key = .page_down, .mod = mod } },
                11 => Key{ .function = .{ .key = .f1, .mod = mod } },
                12 => Key{ .function = .{ .key = .f2, .mod = mod } },
                13 => Key{ .function = .{ .key = .f3, .mod = mod } },
                14 => Key{ .function = .{ .key = .f4, .mod = mod } },
                15 => Key{ .function = .{ .key = .f5, .mod = mod } },
                17 => Key{ .function = .{ .key = .f6, .mod = mod } },
                18 => Key{ .function = .{ .key = .f7, .mod = mod } },
                19 => Key{ .function = .{ .key = .f8, .mod = mod } },
                20 => Key{ .function = .{ .key = .f9, .mod = mod } },
                21 => Key{ .function = .{ .key = .f10, .mod = mod } },
                23 => Key{ .function = .{ .key = .f11, .mod = mod } },
                24 => Key{ .function = .{ .key = .f12, .mod = mod } },
                else => error.UnknownKey,
            };
        },
        'u' => {
            // Kitty extended protocol.
            // Variants:
            //   basic:         CSI code;modifiers u
            //   disambiguate:  CSI > code;modifiers u      (codepoint is the base key, shift in modifiers)
            //   events:        CSI [>] code;modifiers;event u  (event=1 press, 2 repeat, 3 release)
            const u_pos = std.mem.lastIndexOfScalar(u8, seq, 'u') orelse return error.InvalidCsi;
            const inner = seq[0..u_pos];

            var body = inner;
            while (body.len > 0 and (body[0] == '>' or body[0] == '=')) {
                body = body[1..];
            }

            var it = std.mem.splitScalar(u8, body, ';');

            const codepoint_str = it.first();
            const codepoint = std.fmt.parseInt(u32, codepoint_str, 10) catch return error.InvalidCsi;

            const k_mod: Modifier = if (it.next()) |mod_str| blk: {
                const mp = std.fmt.parseInt(u8, mod_str, 10) catch return error.InvalidCsi;
                break :blk Modifier{
                    .shift = mp & 1 != 0,
                    .alt = mp & 2 != 0,
                    .ctrl = mp & 4 != 0,
                    .meta = mp & 8 != 0,
                };
            } else Modifier{};

            return Key{ .char = .{ .code = @intCast(codepoint), .mod = k_mod } };
        },
        else => return error.UnknownKey,
    }
}

/// Parse an SS3 sequence: ESC O <byte> — return the Key for the SS3 final byte.
pub fn parseSs3(byte: u8) ParseError!Key {
    return switch (byte) {
        'P' => Key{ .function = .{ .key = .f1 } },
        'Q' => Key{ .function = .{ .key = .f2 } },
        'R' => Key{ .function = .{ .key = .f3 } },
        'S' => Key{ .function = .{ .key = .f4 } },
        'H' => Key{ .special = .{ .key = .home } },
        'F' => Key{ .special = .{ .key = .end } },
        else => error.UnknownKey,
    };
}

/// Parse a raw sequence (which may or may not start with ESC) into a Key.
pub fn parse(seq: []const u8) ParseError!Key {
    if (seq.len == 0) return error.InvalidCsi;

    // Single char (no escape)
    if (seq[0] != '\x1b') {
        if (seq.len == 1) {
            return Key{ .char = .{ .code = seq[0] } };
        }
        return error.InvalidCsi;
    }

    // ESC sequence
    if (seq.len == 1) return Key{ .special = .{ .key = .escape } };

    // CSI: ESC [
    if (seq.len >= 2 and seq[1] == '[') {
        return parseCsi(seq[2..]);
    }

    // SS3: ESC O (function keys without modifiers)
    if (seq.len >= 2 and seq[1] == 'O') {
        if (seq.len < 3) return error.InvalidCsi;
        return switch (seq[2]) {
            'P' => Key{ .function = .{ .key = .f1 } },
            'Q' => Key{ .function = .{ .key = .f2 } },
            'R' => Key{ .function = .{ .key = .f3 } },
            'S' => Key{ .function = .{ .key = .f4 } },
            'H' => Key{ .special = .{ .key = .home } },
            'F' => Key{ .special = .{ .key = .end } },
            else => error.UnknownKey,
        };
    }

    // ESC followed by a single char (Alt+char)
    if (seq.len == 2) {
        return Key{ .char = .{ .code = seq[1] } };
    }

    return error.UnknownKey;
}

/// Format a Key to its canonical string representation.
pub fn format(key: Key, buf: []u8) []const u8 {
    return switch (key) {
        .char => |c| blk: {
            var pos: usize = 0;
            const mod = c.mod;
            if (mod.ctrl) { buf[pos] = 'C'; buf[pos + 1] = '-'; pos += 2; }
            if (mod.alt)  { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
            if (mod.shift) { buf[pos] = 'S'; buf[pos + 1] = '-'; pos += 2; }
            if (mod.meta) { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }

            const name = if (c.code == ' ')
                "Space"
            else if (c.code == 0x7f)
                "BSpace"
            else if (c.code < 0x20) blk_sub: {
                const names = [_][]const u8{
                    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ASC", "BEL",
                    "BS",  "HT",  "LF",  "VT",  "FF",  "CR",  "SO",  "SI",
                    "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
                    "CAN", "EM",  "SUB", "ESC", "FS",  "GS",  "RS",  "US",
                };
                break :blk_sub if (c.code < names.len) names[c.code] else "[?]";
            } else null;

            if (name) |n| {
                @memcpy(buf[pos..][0..n.len], n);
                break :blk buf[0 .. pos + n.len];
            } else {
                const char_slice = std.fmt.bufPrint(buf[pos..], "{u}", .{@as(u21, c.code)}) catch "[?]";
                break :blk buf[0 .. pos + char_slice.len];
            }
        },
        .function => |f| {
            const name = switch (f.key) {
                .f1 => "F1",
                .f2 => "F2",
                .f3 => "F3",
                .f4 => "F4",
                .f5 => "F5",
                .f6 => "F6",
                .f7 => "F7",
                .f8 => "F8",
                .f9 => "F9",
                .f10 => "F10",
                .f11 => "F11",
                .f12 => "F12",
            };
            return prependModifiers(f.mod, name, buf);
        },
        .arrow => |a| {
            const name = switch (a.key) {
                .up => "Up",
                .down => "Down",
                .left => "Left",
                .right => "Right",
            };
            return prependModifiers(a.mod, name, buf);
        },
        .special => |s| {
            const name = switch (s.key) {
                .tab => "Tab",
                .btab => "BTab",
                .enter => "Enter",
                .escape => "Escape",
                .backspace => "BSpace",
                .home => "Home",
                .end => "End",
                .page_up => "PageUp",
                .page_down => "PageDown",
                .insert => "Insert",
                .delete_ => "Delete",
            };
            return prependModifiers(s.mod, name, buf);
        },
        .mouse => |m| {
            const btn = switch (m.button) {
                .left => "MouseDown1",
                .middle => "MouseDown2",
                .right => "MouseDown3",
                .release => "MouseUp1",
                .scroll_up => "WheelUp",
                .scroll_down => "WheelDown",
            };
            return std.fmt.bufPrint(buf, "{s}({d},{d})", .{ btn, m.x, m.y }) catch "[?]";
        },
    };
}

fn prependModifiers(mod: Modifier, name: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    if (mod.ctrl) { buf[pos] = 'C'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.alt)  { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.shift) { buf[pos] = 'S'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.meta) { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }

    @memcpy(buf[pos..][0..name.len], name);
    return buf[0 .. pos + name.len];
}

pub fn parseKeyName(name: []const u8) !Key {
    if (name.len == 0) return error.UnknownKey;
    
    var remaining = name;
    var mod = Modifier{};
    
    // Parse modifiers
    while (remaining.len > 2 and remaining[1] == '-') {
        switch (remaining[0]) {
            'C', 'c' => mod.ctrl = true,
            'M', 'm' => mod.alt = true,
            'S', 's' => mod.shift = true,
            else => return error.UnknownKey,
        }
        remaining = remaining[2..];
    }
    
    if (remaining.len == 0) return error.UnknownKey;
    
    // Check for named keys
    if (std.mem.eql(u8, remaining, "Space")) return Key{ .char = .{ .code = ' ', .mod = mod } };
    if (std.mem.eql(u8, remaining, "BSpace")) return Key{ .special = .{ .key = .backspace, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Tab")) return Key{ .special = .{ .key = .tab, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Enter")) return Key{ .special = .{ .key = .enter, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Escape")) return Key{ .special = .{ .key = .escape, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Home")) return Key{ .special = .{ .key = .home, .mod = mod } };
    if (std.mem.eql(u8, remaining, "End")) return Key{ .special = .{ .key = .end, .mod = mod } };
    if (std.mem.eql(u8, remaining, "PageUp")) return Key{ .special = .{ .key = .page_up, .mod = mod } };
    if (std.mem.eql(u8, remaining, "PageDown")) return Key{ .special = .{ .key = .page_down, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Insert")) return Key{ .special = .{ .key = .insert, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Delete")) return Key{ .special = .{ .key = .delete_, .mod = mod } };
    
    if (std.mem.eql(u8, remaining, "Up")) return Key{ .arrow = .{ .key = .up, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Down")) return Key{ .arrow = .{ .key = .down, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Left")) return Key{ .arrow = .{ .key = .left, .mod = mod } };
    if (std.mem.eql(u8, remaining, "Right")) return Key{ .arrow = .{ .key = .right, .mod = mod } };
    
    if (std.mem.eql(u8, remaining, "F1")) return Key{ .function = .{ .key = .f1, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F2")) return Key{ .function = .{ .key = .f2, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F3")) return Key{ .function = .{ .key = .f3, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F4")) return Key{ .function = .{ .key = .f4, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F5")) return Key{ .function = .{ .key = .f5, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F6")) return Key{ .function = .{ .key = .f6, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F7")) return Key{ .function = .{ .key = .f7, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F8")) return Key{ .function = .{ .key = .f8, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F9")) return Key{ .function = .{ .key = .f9, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F10")) return Key{ .function = .{ .key = .f10, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F11")) return Key{ .function = .{ .key = .f11, .mod = mod } };
    if (std.mem.eql(u8, remaining, "F12")) return Key{ .function = .{ .key = .f12, .mod = mod } };
    
    if (remaining.len == 1) {
        return Key{ .char = .{ .code = remaining[0], .mod = mod } };
    }
    
    return error.UnknownKey;
}

test "parseKeyName basic" {
    const k1 = try parseKeyName("C-b");
    try testing.expectEqual(@as(u21, 'b'), k1.char.code);
    try testing.expect(k1.char.mod.ctrl);

    const k2 = try parseKeyName("M-S-Left");
    try testing.expectEqual(.left, k2.arrow.key);
    try testing.expect(k2.arrow.mod.alt);
    try testing.expect(k2.arrow.mod.shift);

    const k3 = try parseKeyName("Escape");
    try testing.expectEqual(.escape, k3.special.key);
}

// ── Tests ──

test "parse single char" {
    const key = try parse("a");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
}

test "parse literal A" {
    const key = try parse("A");
    try testing.expectEqual(@as(u21, 'A'), key.char.code);
}

test "parse arrow up" {
    const key = try parse("\x1b[A");
    try testing.expectEqual(.up, key.arrow.key);
}

test "parse arrow down" {
    const key = try parse("\x1b[B");
    try testing.expectEqual(.down, key.arrow.key);
}

test "parse arrow right" {
    const key = try parse("\x1b[C");
    try testing.expectEqual(.right, key.arrow.key);
}

test "parse arrow left" {
    const key = try parse("\x1b[D");
    try testing.expectEqual(.left, key.arrow.key);
}

test "parse ctrl up" {
    const key = try parse("\x1b[1;5A");
    try testing.expectEqual(.up, key.arrow.key);
    try testing.expect(key.arrow.mod.ctrl);
    try testing.expect(!key.arrow.mod.shift);
}

test "parse ctrl shift up" {
    const key = try parse("\x1b[1;6A");
    try testing.expectEqual(.up, key.arrow.key);
    try testing.expect(key.arrow.mod.ctrl);
    try testing.expect(key.arrow.mod.shift);
}

test "parse function key F1-F12" {
    const f_keys = [_]u8{ 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24 };
    const expected = [_]Function{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 };
    inline for (f_keys, expected) |code, func| {
        const seq = try std.fmt.allocPrint(testing.allocator, "\x1b[{d}~", .{code});
        defer testing.allocator.free(seq);
        const key = try parse(seq);
        try testing.expectEqual(func, key.function.key);
    }
}

test "parse home and end" {
    const home = try parse("\x1b[1~");
    try testing.expectEqual(.home, home.special.key);

    const end = try parse("\x1b[4~");
    try testing.expectEqual(.end, end.special.key);
}

test "parse page up down" {
    const pu = try parse("\x1b[5~");
    try testing.expectEqual(.page_up, pu.special.key);

    const pd = try parse("\x1b[6~");
    try testing.expectEqual(.page_down, pd.special.key);
}

test "parse insert delete" {
    const ins = try parse("\x1b[2~");
    try testing.expectEqual(.insert, ins.special.key);

    const del = try parse("\x1b[3~");
    try testing.expectEqual(.delete_, del.special.key);
}

test "parse btab (shift tab)" {
    const key = try parse("\x1b[Z");
    try testing.expectEqual(.btab, key.special.key);
}

test "parse ss3 function keys" {
    const f1 = try parse("\x1bOP");
    try testing.expectEqual(.f1, f1.function.key);
    const f2 = try parse("\x1bOQ");
    try testing.expectEqual(.f2, f2.function.key);
    const f3 = try parse("\x1bOR");
    try testing.expectEqual(.f3, f3.function.key);
    const f4 = try parse("\x1bOS");
    try testing.expectEqual(.f4, f4.function.key);
}

test "parse alt char" {
    const key = try parse("\x1ba");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
}

test "parse kitty extended basic" {
    const key = try parse("\x1b[97;4u");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
    try testing.expect(key.char.mod.ctrl);
}

test "parse kitty disambiguate" {
    // > prefix: codepoint is the base key, modifiers in the bitmask
    const key = try parse("\x1b[>97;1u");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
    try testing.expect(key.char.mod.shift);
}

test "parse kitty with event flags" {
    // = prefix: event field after modifiers (1=press, 2=repeat, 3=release)
    const key = try parse("\x1b[=97;4;1u");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
    try testing.expect(key.char.mod.ctrl);
}

test "parse kitty disambiguate with event" {
    // Both > and =: >code;mod;event u
    const key = try parse("\x1b[=>97;1;2u");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
    try testing.expect(key.char.mod.shift);
}

test "parse kitty unmodified" {
    const key = try parse("\x1b[97;0u");
    try testing.expectEqual(@as(u21, 'a'), key.char.code);
    try testing.expect(!key.char.mod.ctrl);
    try testing.expect(!key.char.mod.shift);
    try testing.expect(!key.char.mod.alt);
}

test "format single char" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .char = .{ .code = 'x' } }, &buf);
    try testing.expectEqualStrings("x", s);
}

test "format space" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .char = .{ .code = ' ' } }, &buf);
    try testing.expectEqualStrings("Space", s);
}

test "format escape" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .special = .{ .key = .escape } }, &buf);
    try testing.expectEqualStrings("Escape", s);
}

test "format enter" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .special = .{ .key = .enter } }, &buf);
    try testing.expectEqualStrings("Enter", s);
}

test "format ctrl up" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .arrow = .{ .key = .up, .mod = .{ .ctrl = true } } }, &buf);
    try testing.expectEqualStrings("C-Up", s);
}

test "format alt shift f1" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .function = .{ .key = .f1, .mod = .{ .alt = true, .shift = true } } }, &buf);
    try testing.expectEqualStrings("M-S-F1", s);
}

test "format ctrl alt delete" {
    var buf: [32]u8 = undefined;
    const s = format(Key{ .special = .{ .key = .delete_, .mod = .{ .ctrl = true, .alt = true } } }, &buf);
    try testing.expectEqualStrings("C-M-Delete", s);
}
