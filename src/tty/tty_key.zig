const std = @import("std");
const testing = std.testing;
const key = @import("../key.zig");
const Key = key.Key;
const Modifier = key.Modifier;
const MouseButton = key.MouseButton;

pub const Event = union(enum) {
    key: Key,
    mouse: MouseEvent,
    focus_in: void,
    focus_out: void,
    paste_start: void,
    paste_end: void,
    resize: struct { cols: u32, rows: u32 },
};

pub const MouseEvent = struct {
    button: MouseButton,
    x: u32,
    y: u32,
    mod: Modifier = .{},
};

const State = enum {
    ground,
    esc,
    csi_params,
    sgr_mouse,
    ss3,
    utf8_2,
    utf8_3,
    utf8_4,
};

pub const InputReader = struct {
    state: State = .ground,
    buf: [64]u8 = undefined,
    pos: usize = 0,

    pub fn reset(self: *InputReader) void {
        self.state = .ground;
        self.pos = 0;
    }

    /// Process one byte; returns an Event when a complete sequence is recognised.
    pub fn feed(self: *InputReader, byte: u8) ?Event {
        switch (self.state) {
            .ground => return feedGround(self, byte),
            .esc => return feedEsc(self, byte),
            .csi_params => return feedCsi(self, byte),
            .sgr_mouse => return feedSgrMouse(self, byte),
            .ss3 => return feedSs3(self, byte),
            .utf8_2 => return feedUtf8(self, byte, 2),
            .utf8_3 => return feedUtf8(self, byte, 3),
            .utf8_4 => return feedUtf8(self, byte, 4),
        }
    }

    fn feedGround(rd: *InputReader, byte: u8) ?Event {
        if (byte == 0x09) return Event{ .key = .{ .special = .{ .key = .tab } } };
        if (byte == 0x0a or byte == 0x0d) return Event{ .key = .{ .special = .{ .key = .enter } } };
        if (byte == 0x1b) {
            rd.state = .esc;
            return null;
        }
        if (byte == 0x7f) return Event{ .key = .{ .special = .{ .key = .backspace } } };
        if (byte < 0x20) {
            const c = byte | 0x40;
            return Event{ .key = .{ .char = .{ .code = c, .mod = .{ .ctrl = true } } } };
        }
        if (byte >= 0x20 and byte <= 0x7e) return Event{ .key = .{ .char = .{ .code = byte } } };
        if (byte >= 0xc0 and byte <= 0xdf) {
            rd.buf[0] = byte;
            rd.pos = 1;
            rd.state = .utf8_2;
            return null;
        }
        if (byte >= 0xe0 and byte <= 0xef) {
            rd.buf[0] = byte;
            rd.pos = 1;
            rd.state = .utf8_3;
            return null;
        }
        if (byte >= 0xf0 and byte <= 0xf7) {
            rd.buf[0] = byte;
            rd.pos = 1;
            rd.state = .utf8_4;
            return null;
        }
        return null;
    }

    fn feedEsc(rd: *InputReader, byte: u8) ?Event {
        if (byte == '[') {
            rd.state = .csi_params;
            rd.pos = 0;
            return null;
        }
        if (byte == 'O') {
            rd.state = .ss3;
            return null;
        }
        rd.state = .ground;
        return Event{ .key = .{ .char = .{ .code = byte, .mod = .{ .alt = true } } } };
    }

    fn feedCsi(rd: *InputReader, byte: u8) ?Event {
        if (byte == '<') {
            rd.state = .sgr_mouse;
            rd.pos = 0;
            return null;
        }
        if (byte >= 0x30 and byte <= 0x3f) {
            rd.buf[rd.pos] = byte;
            rd.pos += 1;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) {
            rd.buf[rd.pos] = byte;
            rd.pos += 1;
            return null;
        }
        rd.state = .ground;
        rd.buf[rd.pos] = byte;
        rd.pos += 1;
        return dispatchCsi(rd.buf[0..rd.pos]);
    }

    fn feedSgrMouse(rd: *InputReader, byte: u8) ?Event {
        if (byte == 'M' or byte == 'm') {
            const seq = rd.buf[0..rd.pos];
            rd.state = .ground;
            return parseSgrMouse(seq, byte == 'm');
        }
        rd.buf[rd.pos] = byte;
        rd.pos += 1;
        return null;
    }

    fn feedSs3(rd: *InputReader, byte: u8) ?Event {
        rd.state = .ground;
        const k = key.parseSs3(byte) catch {
            std.log.debug("input: unknown SS3 sequence ESC O {c}", .{byte});
            return null;
        };
        return Event{ .key = k };
    }

    fn feedUtf8(rd: *InputReader, byte: u8, expected: usize) ?Event {
        if (byte & 0xc0 != 0x80) {
            rd.state = .ground;
            return null;
        }
        rd.buf[rd.pos] = byte;
        rd.pos += 1;
        if (rd.pos < expected) return null;
        rd.state = .ground;
        const codepoint = std.unicode.utf8Decode(rd.buf[0..expected]) catch {
            std.log.debug("input: invalid UTF-8 sequence", .{});
            return null;
        };
        return Event{ .key = .{ .char = .{ .code = codepoint } } };
    }

    fn dispatchCsi(seq: []const u8) ?Event {
        if (seq.len == 0) return null;
        const final = seq[seq.len - 1];
        const params = seq[0 .. seq.len - 1];

        if (final == 'I' and params.len == 0) return Event{ .focus_in = {} };
        if (final == 'O' and params.len == 0) return Event{ .focus_out = {} };

        if (final == '~') {
            const tilde_params = params;
            const num = std.fmt.parseInt(u16, tilde_params, 10) catch {
                std.log.debug("input: invalid tilde params '{s}'", .{tilde_params});
                return null;
            };
            if (num == 200) return Event{ .paste_start = {} };
            if (num == 201) return Event{ .paste_end = {} };
        }

        const k = key.parseCsi(seq) catch {
            std.log.debug("input: unknown CSI sequence ESC[{s}", .{seq});
            return null;
        };
        return Event{ .key = k };
    }
};

pub fn parseSgrMouse(params: []const u8, release: bool) ?Event {
    var it = std.mem.splitScalar(u8, params, ';');
    const btn_str = it.first();
    const btn = std.fmt.parseInt(u32, btn_str, 10) catch {
        std.log.debug("input: invalid SGR mouse button '{s}'", .{btn_str});
        return null;
    };
    const x_str = it.next() orelse {
        std.log.debug("input: SGR mouse missing X coordinate", .{});
        return null;
    };
    const x = std.fmt.parseInt(u32, x_str, 10) catch {
        std.log.debug("input: invalid SGR mouse X '{s}'", .{x_str});
        return null;
    };
    const y_str = it.next() orelse {
        std.log.debug("input: SGR mouse missing Y coordinate", .{});
        return null;
    };
    const y = std.fmt.parseInt(u32, y_str, 10) catch {
        std.log.debug("input: invalid SGR mouse Y '{s}'", .{y_str});
        return null;
    };

    const col: u32 = if (x > 0) x - 1 else 0;
    const row: u32 = if (y > 0) y - 1 else 0;

    const mod = Modifier{
        .shift = btn & 0x04 != 0,
        .alt = btn & 0x08 != 0,
        .ctrl = btn & 0x10 != 0,
    };

    const btn_type = btn & 0x03;
    const wheel_up = (btn & 0xC3) == 0x40;
    const wheel_down = (btn & 0xC3) == 0x41;

    const button: MouseButton = if (release)
        .release
    else if (wheel_up)
        .scroll_up
    else if (wheel_down)
        .scroll_down
    else switch (btn_type) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .release,
        else => .left,
    };

    return Event{ .mouse = .{
        .button = button,
        .x = col,
        .y = row,
        .mod = mod,
    } };
}

// ── Tests ──

test "ground tab" {
    var rd = InputReader{};
    const ev = rd.feed(0x09).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(.tab, ev.key.special.key);
}

test "ground enter" {
    var rd = InputReader{};
    const ev = rd.feed(0x0d).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(.enter, ev.key.special.key);
}

test "ground ctrl a" {
    var rd = InputReader{};
    const ev = rd.feed(0x01).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'A'), ev.key.char.code);
    try testing.expect(ev.key.char.mod.ctrl);
}

test "ground ctrl h" {
    var rd = InputReader{};
    const ev = rd.feed(0x08).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'H'), ev.key.char.code);
    try testing.expect(ev.key.char.mod.ctrl);
}

test "ground literal a" {
    var rd = InputReader{};
    const ev = rd.feed('a').?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.char.code);
}

test "ground del (0x7f)" {
    var rd = InputReader{};
    const ev = rd.feed(0x7f).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(.backspace, ev.key.special.key);
}

test "ground utf-8 2-byte" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0xc3) == null);
    const ev = rd.feed(0xa9).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 0xe9), ev.key.char.code); // é
}

test "ground utf-8 3-byte" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0xe2) == null);
    try testing.expect(rd.feed(0x82) == null);
    const ev = rd.feed(0xac).?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 0x20ac), ev.key.char.code); // €
}

test "alt char" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    const ev = rd.feed('a').?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.char.code);
    try testing.expect(ev.key.char.mod.alt);
}

test "arrow up" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    const ev = rd.feed('A').?;
    try testing.expect(ev == .key);
    try testing.expectEqual(.up, ev.key.arrow.key);
}

test "focus in" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    const ev = rd.feed('I').?;
    try testing.expect(ev == .focus_in);
}

test "focus out" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    const ev = rd.feed('O').?;
    try testing.expect(ev == .focus_out);
}

test "paste start" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('2') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed('0') == null);
    const ev = rd.feed('~').?;
    try testing.expect(ev == .paste_start);
}

test "paste end" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('2') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed('1') == null);
    const ev = rd.feed('~').?;
    try testing.expect(ev == .paste_end);
}

test "sgr mouse press" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('<') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('2') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('1') == null);
    try testing.expect(rd.feed('0') == null);
    const ev = rd.feed('M').?;
    try testing.expect(ev == .mouse);
    try testing.expectEqual(.left, ev.mouse.button);
    try testing.expectEqual(@as(u32, 19), ev.mouse.x);
    try testing.expectEqual(@as(u32, 9), ev.mouse.y);
}

test "sgr mouse release" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('<') == null);
    try testing.expect(rd.feed('3') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('1') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('5') == null);
    const ev = rd.feed('m').?;
    try testing.expect(ev == .mouse);
    try testing.expectEqual(.release, ev.mouse.button);
}

test "sgr mouse wheel up" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('<') == null);
    try testing.expect(rd.feed('6') == null);
    try testing.expect(rd.feed('4') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('5') == null);
    try testing.expect(rd.feed('0') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('2') == null);
    try testing.expect(rd.feed('0') == null);
    const ev = rd.feed('M').?;
    try testing.expect(ev == .mouse);
    try testing.expectEqual(.scroll_up, ev.mouse.button);
}

test "kitty key" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('[') == null);
    try testing.expect(rd.feed('9') == null);
    try testing.expect(rd.feed('7') == null);
    try testing.expect(rd.feed(';') == null);
    try testing.expect(rd.feed('5') == null);
    const ev = rd.feed('u').?;
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.char.code);
    try testing.expect(ev.key.char.mod.ctrl);
}

test "ss3 function key f1" {
    var rd = InputReader{};
    try testing.expect(rd.feed(0x1b) == null);
    try testing.expect(rd.feed('O') == null);
    const ev = rd.feed('P').?;
    try testing.expect(ev == .key);
    try testing.expectEqual(.f1, ev.key.function.key);
}

test "reset reader" {
    var rd = InputReader{};
    _ = rd.feed(0x1b);
    try testing.expectEqual(.esc, rd.state);
    rd.reset();
    try testing.expectEqual(.ground, rd.state);
}

test "multiple events in buffer" {
    var rd = InputReader{};
    const ev1 = rd.feed('a').?;
    try testing.expectEqual(@as(u21, 'a'), ev1.key.char.code);
    const ev2 = rd.feed('b').?;
    try testing.expectEqual(@as(u21, 'b'), ev2.key.char.code);
}

