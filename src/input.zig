const std = @import("std");
const testing = std.testing;
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const key = @import("key.zig");

pub const Error = screen_mod.Error;

pub const InputParser = struct {
    screen: *Screen,
    state: State = .ground,
    params: [16]u32 = undefined,
    sub_params: [16]bool = undefined,
    param_count: u32 = 0,
    param_val: u32 = 0,
    collecting_param: bool = false,
    params_started: bool = false,
    intermediate: u8 = 0,
    osc_buf: [256]u8 = undefined,
    osc_len: u32 = 0,
    pty: ?*@import("server/pty.zig").Pty = null,
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,
    title_cb: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
    title_ctx: ?*anyopaque = null,
    /// Growable buffer for accumulating raw DCS / sixel bytes.
    /// Re-used across calls; reset to len=0 on each new DCS.
    dcs_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// True when the current DCS sequence is a sixel stream (final byte 'q').
    dcs_is_sixel: bool = false,

    const State = enum {
        ground,
        esc,
        esc_intermediate,
        csi_param,
        csi_intermediate,
        csi_final,
        osc_string,
        osc_esc,
        dcs_entry,
        dcs_param,
        dcs_intermediate,
        dcs_final,
        dcs_sixel,      // accumulating sixel payload bytes
        dcs_sixel_esc,  // saw ESC inside sixel — waiting for \\ (ST)
        sos_pm_apc_string,
    };

    pub fn init(screen: *Screen) InputParser {
        return InputParser{
            .screen = screen,
            .utf8_len = 0,
            .utf8_expected = 0,
            .title_cb = null,
            .title_ctx = null,
        };
    }

    pub fn reset(self: *InputParser) void {
        self.state = .ground;
        self.param_count = 0;
        self.param_val = 0;
        self.collecting_param = false;
        self.params_started = false;
        self.intermediate = 0;
        self.osc_len = 0;
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.title_cb = null;
        self.title_ctx = null;
        self.dcs_buf.clearRetainingCapacity();
        self.dcs_is_sixel = false;
    }

    pub fn deinit(self: *InputParser, allocator: std.mem.Allocator) void {
        self.dcs_buf.deinit(allocator);
    }

    fn clearParams(self: *InputParser) void {
        for (&self.params) |*p| p.* = 0;
        for (&self.sub_params) |*s| s.* = false;
        self.param_count = 0;
        self.param_val = 0;
        self.collecting_param = false;
        self.params_started = false;
    }

    fn pushParam(self: *InputParser) void {
        if (self.param_count < self.params.len) {
            if (self.params_started) {
                self.params[self.param_count] = self.param_val;
            } else {
                self.params[self.param_count] = 0;
            }
            self.param_count += 1;
        }
        self.param_val = 0;
        self.collecting_param = false;
        self.params_started = false;
    }

    fn param(self: *InputParser, idx: u32) u32 {
        if (idx < self.param_count) return self.params[idx];
        return 0;
    }

    fn paramDefault(self: *InputParser, idx: u32, default: u32) u32 {
        const p = self.param(idx);
        return if (p == 0) default else p;
    }

    pub fn advance(self: *InputParser, byte: u8) Error!void {
        if (self.state == .ground) {
            if (self.utf8_expected > 0) {
                self.utf8_buf[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_expected) {
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_expected]) catch '?';
                    try self.screen.writeChar(cp);
                    self.utf8_expected = 0;
                    self.utf8_len = 0;
                }
                return;
            } else if (byte >= 0xC2 and byte <= 0xF4) {
                const expected = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                if (expected >= 2 and expected <= 4) {
                    self.utf8_expected = @intCast(expected);
                    self.utf8_buf[0] = byte;
                    self.utf8_len = 1;
                    return;
                }
            }
        }

        switch (self.state) {
            .ground => try self.advanceGround(byte),
            .esc => try self.advanceEsc(byte),
            .esc_intermediate => try self.advanceEscIntermediate(byte),
            .csi_param => try self.advanceCsiParam(byte),
            .csi_intermediate => try self.advanceCsiIntermediate(byte),
            .csi_final => self.advanceCsiFinal(byte),
            .osc_string => try self.advanceOsc(byte),
            .osc_esc => self.advanceOscEsc(byte),
            .dcs_entry => try self.advanceDcsEntry(byte),
            .dcs_param => try self.advanceDcsParam(byte),
            .dcs_intermediate => self.advanceDcsIntermediate(byte),
            .dcs_final => self.advanceDcsFinal(byte),
            .dcs_sixel => try self.advanceDcsSixel(byte),
            .dcs_sixel_esc => try self.advanceDcsSixelEsc(byte),
            .sos_pm_apc_string => self.advanceSosPmApc(byte),
        }
    }

    fn toGround(self: *InputParser) void {
        self.state = .ground;
        self.clearParams();
        self.intermediate = 0;
        self.osc_len = 0;
    }

    fn advanceGround(self: *InputParser, byte: u8) Error!void {
        switch (byte) {
            0x00...0x06, 0x0B, 0x0C, 0x0E...0x1A, 0x1C...0x1F => {},
            0x07 => {},
            0x08 => {
                if (self.screen.cursor.x > 0) self.screen.cursor.x -= 1;
            },
            0x09 => try self.screen.writeChar('\t'),
            0x0A => try self.screen.writeChar('\n'),
            0x0D => try self.screen.writeChar('\r'),
            0x1B => {
                self.state = .esc;
            },
            0x7F => {},
            0x20...0x7E => try self.screen.writeChar(byte),
            0x80...0x8F => {
                // SS2, SS3, DCS, SOS, ESC, CSI, ST, OSC, PM, APC (8-bit)
                self.state = .esc;
                self.clearParams();
            },
            0x90 => self.state = .dcs_entry,
            0x98 => self.state = .sos_pm_apc_string,
            0x9B => {
                self.state = .csi_param;
                self.clearParams();
                self.params_started = true;
            },
            0x9C => {},
            0x9D => self.state = .sos_pm_apc_string,
            0x9E => self.state = .sos_pm_apc_string,
            0x9F => self.state = .sos_pm_apc_string,
            0x91...0x97, 0x99...0x9A, 0xA0...0xBF, 0xC0...0xFF => {},
        }
    }

    fn advanceEsc(self: *InputParser, byte: u8) Error!void {
        self.state = .ground;
        switch (byte) {
            '[' => {
                self.state = .csi_param;
                self.clearParams();
                self.params_started = true;
            },
            ']' => {
                self.state = .osc_string;
                self.osc_len = 0;
                self.clearParams();
            },
            'P' => self.state = .dcs_entry,
            'X' => self.state = .sos_pm_apc_string,
            '^' => self.state = .sos_pm_apc_string,
            '_' => self.state = .sos_pm_apc_string,
            '7' => self.screen.saveCursor(),
            '8' => self.screen.restoreCursor(),
            'D' => try self.screen.index(),
            'M' => try self.screen.reverseIndex(),
            'c' => try self.screen.resetHard(),
            '=', '>' => {},
            '<' => {},
            0x20...0x2F => {
                self.intermediate = byte;
                self.state = .esc_intermediate;
            },
            else => {},
        }
    }

    fn advanceEscIntermediate(self: *InputParser, byte: u8) Error!void {
        switch (byte) {
            0x20...0x2F => {
                self.intermediate = byte;
            },
            0x30...0x7E => {
                // Ignore G0/G1 charset selections and other 3-byte ESC sequences
                self.toGround();
            },
            else => self.toGround(),
        }
    }

    fn advanceCsiParam(self: *InputParser, byte: u8) Error!void {
        switch (byte) {
            '0'...'9' => {
                self.collecting_param = true;
                self.params_started = true;
                self.param_val = self.param_val * 10 + (byte - '0');
            },
            ':' => {
                self.pushParam();
                if (self.param_count < self.sub_params.len) {
                    self.sub_params[self.param_count] = true;
                }
                self.collecting_param = true;
                self.params_started = true;
                self.param_val = 0;
            },
            ';' => {
                self.pushParam();
            },
            0x3C...0x3F => {
                // < = > ? — private marker prefix, stay in param state
                self.intermediate = byte;
            },
            0x20...0x2F => {
                // intermediate bytes — transition to intermediate state
                self.intermediate = byte;
                self.state = .csi_intermediate;
            },
            0x40...0x7E => {
                self.pushParam();
                try self.dispatchCsi(byte);
            },
            else => self.toGround(),
        }
    }

    fn advanceCsiIntermediate(self: *InputParser, byte: u8) Error!void {
        switch (byte) {
            0x20...0x2F => {
                self.intermediate = byte;
            },
            0x40...0x7E => {
                try self.dispatchCsi(byte);
            },
            else => self.toGround(),
        }
    }

    fn advanceCsiFinal(self: *InputParser, _: u8) void {
        self.toGround();
    }

    fn advanceOsc(self: *InputParser, byte: u8) Error!void {
        switch (byte) {
            0x07 => {
                try self.dispatchOsc();
                self.toGround();
            },
            0x1B => {
                self.state = .osc_esc;
            },
            0x00...0x06, 0x08...0x1A, 0x1C...0x1F => {},
            0x20...0x7E, 0x7F, 0x80...0xFF => {
                if (self.osc_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_len] = byte;
                    self.osc_len += 1;
                }
            },
        }
    }

    fn advanceOscEsc(self: *InputParser, byte: u8) void {
        if (byte == '\\') {
            self.dispatchOsc() catch {};
        }
        self.toGround();
    }

    fn advanceDcsEntry(self: *InputParser, byte: u8) !void {
        // Prepend "ESC P" to the accumulation buffer so we can re-emit the
        // complete sequence later. We do this lazily on the first byte of the
        // DCS body rather than when ESC P is first seen, to avoid allocating
        // for non-sixel DCS sequences that will be discarded.
        switch (byte) {
            '0'...'9', ';', ':', '<', '=', '>', '?' => {
                self.state = .dcs_param;
            },
            0x20...0x2F => {
                self.state = .dcs_intermediate;
            },
            'q' => {
                // Sixel final byte — start accumulating
                self.dcs_is_sixel = true;
                self.dcs_buf.clearRetainingCapacity();
                // ESC P <params so far are already gone — we have no params yet
                // because we came straight from dcs_entry. Prepend the DCS intro.
                try self.dcs_buf.appendSlice(self.screen.allocator, "\x1bP");
                try self.dcs_buf.append(self.screen.allocator, byte);
                self.state = .dcs_sixel;
            },
            0x40...'p', 'r'...0x7E => {
                // Non-sixel DCS final — discard
                self.toGround();
            },
            else => self.toGround(),
        }
    }

    fn advanceDcsParam(self: *InputParser, byte: u8) !void {
        switch (byte) {
            '0'...'9', ';', ':', '<', '=', '>', '?' => {},
            0x20...0x2F => {
                self.state = .dcs_intermediate;
            },
            'q' => {
                // Sixel — collect the params that preceded this 'q'
                self.dcs_is_sixel = true;
                self.dcs_buf.clearRetainingCapacity();
                // Re-emit "ESC P q" — the params are not needed for passthrough
                // since the receiving terminal will parse them from the raw bytes.
                // We start fresh: just need ESC P then the params we already
                // consumed are gone. For passthrough we only need the payload, so
                // the outer terminal will use its own default parameters.
                // Prepend ESC P q as the intro.
                try self.dcs_buf.appendSlice(self.screen.allocator, "\x1bPq");
                self.state = .dcs_sixel;
            },
            0x40...'p', 'r'...0x7E => {
                // Non-sixel DCS final — discard
                self.toGround();
            },
            else => self.toGround(),
        }
    }

    fn advanceDcsIntermediate(self: *InputParser, byte: u8) void {
        switch (byte) {
            0x20...0x2F => {},
            'q' => {
                // Sixel final after intermediate byte(s) — still valid
                self.dcs_is_sixel = true;
                self.dcs_buf.clearRetainingCapacity();
                self.dcs_buf.appendSlice(self.screen.allocator, "\x1bPq") catch {};
                self.state = .dcs_sixel;
            },
            0x40...'p', 'r'...0x7E => {
                // Non-sixel DCS final after intermediate — discard
                self.toGround();
            },
            else => self.toGround(),
        }
    }

    fn advanceDcsFinal(self: *InputParser, _: u8) void {
        self.toGround();
    }

    /// Accumulate raw sixel payload bytes.
    /// The buffer grows without a fixed limit but is bounded in practice by the
    /// 1024-byte `esc_buf` upstream cap in server.zig that feeds us data, so a
    /// single call contributes at most ~4 KiB per read cycle.
    fn advanceDcsSixel(self: *InputParser, byte: u8) !void {
        if (byte == 0x1B) {
            // Possible ST (ESC \) — buffer the ESC, wait for \
            self.state = .dcs_sixel_esc;
            return;
        }
        if (byte == 0x9C) {
            // 8-bit ST — dispatch
            try self.dispatchDcsSixel();
            return;
        }
        // Cap raw sixel data at 16 MiB to prevent runaway memory use.
        if (self.dcs_buf.items.len < 16 * 1024 * 1024) {
            try self.dcs_buf.append(self.screen.allocator, byte);
        }
    }

    fn advanceDcsSixelEsc(self: *InputParser, byte: u8) !void {
        if (byte == '\\') {
            // ESC \ = ST — dispatch the sixel image
            try self.dispatchDcsSixel();
        } else {
            // Not a ST; the ESC was part of data. Append ESC and this byte.
            if (self.dcs_buf.items.len < 16 * 1024 * 1024) {
                try self.dcs_buf.append(self.screen.allocator, 0x1B);
                try self.dcs_buf.append(self.screen.allocator, byte);
            }
            self.state = .dcs_sixel;
        }
    }

    /// Parse sixel pixel dimensions and hand off to Screen.
    fn dispatchDcsSixel(self: *InputParser) !void {
        defer self.toGround();
        if (!self.dcs_is_sixel) return;
        self.dcs_is_sixel = false;

        // Append the ST terminator so the outer terminal can parse it.
        try self.dcs_buf.appendSlice(self.screen.allocator, "\x1b\\");

        // Rough pixel-height estimate: count sixel newline commands ('-').
        // Each '-' advances by one band = 6 pixels.
        var bands: u32 = 1;
        for (self.dcs_buf.items) |b| {
            if (b == '-') bands += 1;
        }
        const px_height: u32 = bands * 6;

        // We don't know pixel width without fully decoding; pass 0.
        // The render engine only uses px_height for cursor advancement.
        const px_width: u32 = 0;

        // Transfer buffer ownership to Screen.
        const owned = try self.screen.allocator.dupe(u8, self.dcs_buf.items);
        self.dcs_buf.clearRetainingCapacity();
        try self.screen.addSixelImage(owned, px_width, px_height);
    }

    fn advanceSosPmApc(self: *InputParser, byte: u8) void {
        switch (byte) {
            0x1B => {
                self.state = .esc;
            },
            0x9C => {
                self.toGround();
            },
            else => {},
        }
    }

    fn dispatchCsi(self: *InputParser, final: u8) Error!void {
        defer self.toGround();
        const p = self.paramDefault(0, 1);
        std.log.debug("CSI dispatch: final=0x{x}('{c}') p0={d} count={d}", .{ final, final, self.param(0), self.param_count });

        switch (final) {
            '@' => {
                const n = self.paramDefault(0, 1);
                self.screen.insertChars(n);
            },
            'A' => self.screen.cursorUp(p),
            'B' => self.screen.cursorDown(p),
            'C' => self.screen.cursorForward(p),
            'D' => self.screen.cursorBack(p),
            'E' => {
                const n = self.paramDefault(0, 1);
                self.screen.cursorDown(n);
                self.screen.cursor.x = 0;
            },
            'F' => {
                const n = self.paramDefault(0, 1);
                self.screen.cursorUp(n);
                self.screen.cursor.x = 0;
            },
            'G' => {
                const x = (self.paramDefault(0, 1) -| 1);
                self.screen.cursorColumn(x);
            },
            'H', 'f' => {
                const row = (self.paramDefault(0, 1) -| 1);
                const col = (self.paramDefault(1, 1) -| 1);
                self.screen.cursorPosition(col, row);
            },
            'J' => {
                const mode = if (self.param(0) == 0) @as(u8, 0) else @as(u8, @intCast(self.param(0) & 0xFF));
                self.screen.eraseDisplay(mode);
            },
            'K' => {
                const mode = if (self.param(0) == 0) @as(u8, 0) else @as(u8, @intCast(self.param(0) & 0xFF));
                self.screen.eraseLine(mode);
            },
            'L' => {
                const n = self.paramDefault(0, 1);
                try self.screen.insertLines(n);
            },
            'M' => {
                const n = self.paramDefault(0, 1);
                try self.screen.deleteLines(n);
            },
            'P' => {
                const n = self.paramDefault(0, 1);
                self.screen.deleteChars(n);
            },
            'S' => {
                if (self.intermediate == '?') {
                    // XTSMGRAPHICS — graphics attribute query.
                    // CSI ? Ps1 ; Ps2 S
                    //   Ps1=1 = number of colour registers
                    //   Ps1=2 = sixel geometry
                    // We report sixel as supported with no size limit (0;0).
                    const ps1 = self.param(0);
                    if (self.pty) |pty| {
                        var buf: [32]u8 = undefined;
                        const rep = std.fmt.bufPrint(&buf, "\x1b[?{d};0;0S", .{ps1}) catch "";
                        if (rep.len > 0) pty.writeInput(rep) catch {};
                    }
                } else {
                    const n = self.paramDefault(0, 1);
                    try self.screen.scrollUp(n);
                }
            },
            'T' => {
                const n = self.paramDefault(0, 1);
                try self.screen.scrollDown(n);
            },
            'X' => {
                const n = self.paramDefault(0, 1);
                self.screen.eraseChars(n);
            },
            'd' => {
                const y = (self.paramDefault(0, 1) -| 1);
                self.screen.cursorLine(y);
            },
            'e' => {
                const n = self.paramDefault(0, 1);
                self.screen.cursorDown(n);
            },
            'h' => {
                if (self.intermediate == '?') {
                    try self.dispatchDecset(true);
                } else {
                    try self.dispatchAnsiMode(true);
                }
            },
            'l' => {
                if (self.intermediate == '?') {
                    try self.dispatchDecset(false);
                } else {
                    try self.dispatchAnsiMode(false);
                }
            },
            'm' => {
                if (self.param_count == 0) {
                    self.screen.setSgr(&.{}, &.{});
                } else {
                    self.screen.setSgr(self.params[0..self.param_count], self.sub_params[0..self.param_count]);
                }
            },
            'r' => {
                const top = (self.paramDefault(0, 1) -| 1);
                const bottom = (self.paramDefault(1, self.screen.grid.height) -| 1);
                self.screen.setScrollRegion(top, bottom);
            },
            'n' => {
                const n = self.param(0);
                if (n == 6) {
                    if (self.pty) |pty| {
                        var rep_buf: [32]u8 = undefined;
                        const rep = std.fmt.bufPrint(&rep_buf, "\x1b[{d};{d}R", .{ self.screen.cursor.y + 1, self.screen.cursor.x + 1 }) catch return;
                        pty.writeInput(rep) catch |err| {
                            std.log.warn("DSR writeInput error: {any}", .{err});
                        };
                    }
                }
            },
            'c' => {
                // Device Attributes.
                // CSI c    (intermediate == 0) → Primary DA (DA1)
                //   Respond: VT300-class + sixel (4) + colour text (22)
                //   ESC [ ? 63 ; 4 ; 22 c
                //   This is the same response tmux hard-codes.
                // CSI > c  (intermediate == '>') → Secondary DA (DA2)
                //   Respond: type=0 (VT100), firmware=10, ROM cartridge=0
                //   ESC [ > 0 ; 10 ; 0 c
                if (self.pty) |pty| {
                    const rep: []const u8 = if (self.intermediate == '>')
                        "\x1b[>0;10;0c"
                    else
                        "\x1b[?63;4;22c";
                    pty.writeInput(rep) catch |err| {
                        std.log.warn("DA response writeInput error: {any}", .{err});
                    };
                }
            },
            's' => {
                self.screen.saveCursor();
            },
            'u' => {
                self.screen.restoreCursor();
            },
            else => {},
        }
    }

    fn dispatchDecset(self: *InputParser, enable: bool) Error!void {
        var i: u32 = 0;
        while (i < self.param_count) : (i += 1) {
            switch (self.params[i]) {
                1 => self.screen.mode.keypad = enable,
                12 => {}, // cursor blink — not implemented
                25 => self.screen.mode.cursor = enable,
                1000 => self.screen.mode.mouse_standard = enable,
                1002 => self.screen.mode.mouse_button = enable,
                1003 => self.screen.mode.mouse_standard = enable,
                1004 => self.screen.mode.focus = enable,
                1006 => self.screen.mode.mouse_sgr = enable,
                1049 => {
                    try self.screen.useAltScreen(enable);
                },
                2004 => self.screen.mode.paste = enable,
                else => {},
            }
        }
    }

    fn dispatchAnsiMode(self: *InputParser, enable: bool) Error!void {
        var i: u32 = 0;
        while (i < self.param_count) : (i += 1) {
            switch (self.params[i]) {
                4 => self.screen.mode.insert = enable,
                else => {},
            }
        }
    }

    fn dispatchOsc(self: *InputParser) Error!void {
        // Find first semicolon to separate command
        var cmd_end: u32 = 0;
        while (cmd_end < self.osc_len and self.osc_buf[cmd_end] != ';') : (cmd_end += 1) {}
        const cmd_str = self.osc_buf[0..cmd_end];
        const cmd = std.fmt.parseInt(u32, cmd_str, 10) catch {
            return;
        };
        const data_start = if (cmd_end < self.osc_len) cmd_end + 1 else cmd_end;
        const data = self.osc_buf[data_start..self.osc_len];

        switch (cmd) {
            0, 2 => {
                if (self.title_cb) |cb| {
                    cb(self.title_ctx, data);
                }
            },
            52 => {
                // Set clipboard: 52;Pc;data
                var semicolon: u32 = 0;
                while (semicolon < data.len and data[semicolon] != ';') : (semicolon += 1) {}
                // clipboard data after second semicolon — ignore for now
            },
            else => {},
        }
    }

    pub fn feed(self: *InputParser, bytes: []const u8) Error!void {
        for (bytes) |b| {
            try self.advance(b);
        }
    }
};

test "ground printable chars" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("Hello");
    try testing.expectEqual(@as(u21, 'H'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'o'), screen.grid.getCell(4, 0).char);
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
}

test "newline via parser" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("ab\nc");
    try testing.expectEqual(@as(u21, 'a'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'b'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'c'), screen.grid.getCell(0, 1).char);
}

test "carriage return" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("abcdefg\rX");
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(0, 0).char);
}

test "tab character" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\t");
    try testing.expectEqual(@as(u32, 8), screen.cursor.x);
}

test "CUU cursor up" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 5;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2A");
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "CUD cursor down" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 5;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[3B");
    try testing.expectEqual(@as(u32, 8), screen.cursor.y);
}

test "CUF cursor forward" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[5C");
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
}

test "CUB cursor back" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 10;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[4D");
    try testing.expectEqual(@as(u32, 6), screen.cursor.x);
}

test "CUP cursor position" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[5;10H");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
}

test "CHA cursor horizontal absolute" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[20G");
    try testing.expectEqual(@as(u32, 19), screen.cursor.x);
}

test "VPA vertical position absolute" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[15d");
    try testing.expectEqual(@as(u32, 14), screen.cursor.y);
}

test "HVP horizontal vertical position" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[3;7f");
    try testing.expectEqual(@as(u32, 6), screen.cursor.x);
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
}

test "EL erase line" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("ABCDE");
    screen.cursor.x = 2;
    try parser.feed("\x1b[K");
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(2, 0).char);
}

test "ED erase display" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("ABCDE\n12345");
    screen.cursor.x = 0;
    screen.cursor.y = 0;
    try parser.feed("\x1b[J");
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).char);
}

test "IL insert lines" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2\nline3");
    screen.cursor.y = 1;
    try parser.feed("\x1b[2L");
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 3).char);
}

test "DL delete lines" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2\nline3");
    screen.cursor.y = 1;
    try parser.feed("\x1b[M");
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 4).char);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 1).char);
}

test "DCH delete chars" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("ABCDE");
    screen.cursor.x = 2;
    try parser.feed("\x1b[P");
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'E'), screen.grid.getCell(3, 0).char);
}

test "ICH insert chars" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("ABDE");
    screen.cursor.x = 2;
    try parser.feed("\x1b[@");
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(3, 0).char);
}

test "SU scroll up" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2\nline3\nline4");
    try parser.feed("\x1b[S");
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 0).char);
}

test "SD scroll down" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2\nline3");
    try parser.feed("\x1b[T");
    // SD moves content down, line3 moves to line 2, bottom lines clear
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 0).char);
}

test "DECSC DECRC save restore cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[5;10H");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);

    try parser.feed("\x1b7");
    try parser.feed("\x1b[3;5H");
    try testing.expectEqual(@as(u32, 4), screen.cursor.x);
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);

    try parser.feed("\x1b8");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
}

test "CSI s and CSI u save restore cursor" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[5;10H");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);

    try parser.feed("\x1b[s");
    try parser.feed("\x1b[3;5H");
    try testing.expectEqual(@as(u32, 4), screen.cursor.x);
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);

    try parser.feed("\x1b[u");
    try testing.expectEqual(@as(u32, 9), screen.cursor.x);
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
}

test "IND index" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2");
    screen.cursor.y = 2;
    try parser.feed("\x1bD");
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 0).char);
}

test "RI reverse index" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("line1\nline2");
    screen.cursor.y = 1;
    try parser.feed("\x1bM");
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expectEqual(@as(u21, 'l'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u32, 5), screen.cursor.x);
}

test "RIS reset" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("hello");
    try parser.feed("\x1bc");
    try testing.expect(screen.grid.isEmpty());
}

test "SGR bold" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[1mX");
    try testing.expect(screen.grid.getCell(0, 0).attr.bold);
}

test "SGR colours indexed" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[31;42mA");
    const cell = screen.grid.getCell(0, 0);
    try testing.expectEqual(@as(u8, 1), cell.fg.value);
    try testing.expectEqual(@as(u8, 2), cell.bg.value);
}

test "SGR reset clears attributes" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[1;31mX\x1b[0mY");
    try testing.expect(screen.grid.getCell(0, 0).attr.bold);
    try testing.expect(!screen.grid.getCell(1, 0).attr.bold);
}

test "DECSTBM set scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2;4r");
    try testing.expectEqual(@as(u32, 1), screen.scroll_region.?[0]);
    try testing.expectEqual(@as(u32, 3), screen.scroll_region.?[1]);
}

test "ECH erase chars" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("ABCDE");
    screen.cursor.x = 1;
    try parser.feed("\x1b[2X");
    try testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'D'), screen.grid.getCell(3, 0).char);
}

test "multiple sequences" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[31mHello\x1b[32m World\x1b[0m!");
    try testing.expectEqual(@as(u21, 'H'), screen.grid.getCell(0, 0).char);
    try testing.expect(screen.grid.getCell(0, 0).attr.bold == false);
    try testing.expectEqual(@as(u21, '!'), screen.grid.getCell(11, 0).char);
}

test "CNL cursor next line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 5;
    screen.cursor.y = 3;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2E");
    try testing.expectEqual(@as(u32, 5), screen.cursor.y);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "CPL cursor previous line" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 5;
    screen.cursor.y = 7;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[3F");
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "default param (1) for cursor movement" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 5;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[A");
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
}

test "VPR vertical position relative" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 3;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[4e");
    try testing.expectEqual(@as(u32, 7), screen.cursor.y);
}

test "SGR 256-colour foreground" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[38;5;42mA");
    const cell = screen.grid.getCell(0, 0);
    try testing.expectEqual(@as(u8, 42), cell.fg.value);
}

test "SGR true colour foreground" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[38;2;255;128;0mA");
    const cell = screen.grid.getCell(0, 0);
    try testing.expectEqual(@as(u24, 0xFF8000), cell.fg.value);
}

test "osc title ignored no crash" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b]0;my title\x07");
    // Just verify no crash and parser returns to ground
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "BS backspace moves cursor back" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("AB\x08");
    try testing.expectEqual(@as(u32, 1), screen.cursor.x);
}

test "control chars 0x00-0x06 ignored" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed(&[_]u8{ 0x00, 0x01, 0x02 });
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "scroll region mode cursor movement" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2;4r");
    try parser.feed("\x1b[4;1H");
    try parser.feed("X");
    try testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(0, 3).char);
}

test "SGR bold off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[1;22mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.bold);
}

test "SGR italic off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[3;23mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.italic);
}

test "SGR underline off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[4;24mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.underline);
}

test "SGR blink off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[5;25mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.blink);
}

test "SGR reverse off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[7;27mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.reverse);
}

test "SGR concealed off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[8;28mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.concealed);
}

test "SGR strikethrough off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[9;29mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.strikethrough);
}

test "SGR bright foreground colours" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[91mA");
    try testing.expectEqual(@as(u8, 9), screen.grid.getCell(0, 0).fg.value);
}

test "SGR bright background colours" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[100mA");
    try testing.expectEqual(@as(u8, 8), screen.grid.getCell(0, 0).bg.value);
}

test "SGR double underline" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[21mA");
    try testing.expect(screen.grid.getCell(0, 0).attr.double_underline);
}

test "SGR subparameter double/curly underline" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);

    // Test double underline 4:2
    try parser.feed("\x1b[4:2mA");
    try testing.expect(screen.grid.getCell(0, 0).attr.double_underline);
    try testing.expect(!screen.grid.getCell(0, 0).attr.underline);

    // Test curly underline 4:3
    try parser.feed("\x1b[4:3mB");
    try testing.expect(screen.grid.getCell(1, 0).attr.curly_underline);
    try testing.expect(!screen.grid.getCell(1, 0).attr.underline);

    // Test turn off underlines 24
    try parser.feed("\x1b[24mC");
    try testing.expect(!screen.grid.getCell(2, 0).attr.underline);
    try testing.expect(!screen.grid.getCell(2, 0).attr.double_underline);
    try testing.expect(!screen.grid.getCell(2, 0).attr.curly_underline);
}


test "SGR reset fg default" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[31;39mA");
    try testing.expectEqual(@as(u8, 0), screen.grid.getCell(0, 0).fg.value);
}

test "SGR reset bg default" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[41;49mA");
    try testing.expectEqual(@as(u8, 0), screen.grid.getCell(0, 0).bg.value);
}

test "DECSET cursor keys application mode" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[?1h");
    try testing.expect(screen.mode.keypad);
    try parser.feed("\x1b[?1l");
    try testing.expect(!screen.mode.keypad);
}

test "DECSET cursor visibility" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[?25l");
    try testing.expect(!screen.mode.cursor);
    try parser.feed("\x1b[?25h");
    try testing.expect(screen.mode.cursor);
}

test "DECSET mouse modes" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[?1000h");
    try testing.expect(screen.mode.mouse_standard);
    try parser.feed("\x1b[?1002h");
    try testing.expect(screen.mode.mouse_button);
    try parser.feed("\x1b[?1006h");
    try testing.expect(screen.mode.mouse_sgr);
    try parser.feed("\x1b[?1004h");
    try testing.expect(screen.mode.focus);
    try parser.feed("\x1b[?2004h");
    try testing.expect(screen.mode.paste);
}

test "DECSET alt screen via 1049" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try screen.writeStr("normal");
    try parser.feed("\x1b[?1049h");
    try testing.expect(screen.grid.isEmpty());
    try testing.expect(screen.mode.alt_screen);
}

test "SM IRM insert mode" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[4h");
    try testing.expect(screen.mode.insert);
    try parser.feed("\x1b[4l");
    try testing.expect(!screen.mode.insert);
}

test "multiple DECSET params" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[?1000;1002;1006h");
    try testing.expect(screen.mode.mouse_standard);
    try testing.expect(screen.mode.mouse_button);
    try testing.expect(screen.mode.mouse_sgr);
}

test "OSC 52 clipboard ignored no crash" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b]52;c;dGVzdA==\x07");
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "OSC with ST terminator" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b]0;test\x1b\\");
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "OSC with ST terminator invokes title callback" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    var mock = TitleMock{};
    parser.title_cb = TitleMock.callback;
    parser.title_ctx = &mock;
    try parser.feed("\x1b]0;my title\x1b\\");
    try testing.expect(mock.called);
    try testing.expectEqualStrings("my title", mock.title[0..mock.len]);
}

test "OSC with BEL terminator still works" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    var mock = TitleMock{};
    parser.title_cb = TitleMock.callback;
    parser.title_ctx = &mock;
    try parser.feed("\x1b]0;title2\x07");
    try testing.expect(mock.called);
    try testing.expectEqualStrings("title2", mock.title[0..mock.len]);
}

test "C1 control 8-bit CSI" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed(&[_]u8{ 0x9B, 0x33, 0x42 }); // 8-bit CSI 3 B
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "UTF-8 multi-byte character parsing" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    // ❯ is E2 9D AF
    try parser.feed("❯abc");
    try testing.expectEqual(@as(u21, 0x276f), screen.grid.getCell(0, 0).char); // U+276F is ❯
    try testing.expectEqual(@as(u21, 'a'), screen.grid.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'b'), screen.grid.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'c'), screen.grid.getCell(3, 0).char);
    try testing.expectEqual(@as(u32, 4), screen.cursor.x);
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

const TitleMock = struct {
    called: bool = false,
    title: [64]u8 = undefined,
    len: usize = 0,

    fn callback(ctx: ?*anyopaque, title: []const u8) void {
        const self: *TitleMock = @ptrCast(@alignCast(ctx orelse return));
        self.called = true;
        @memcpy(self.title[0..title.len], title);
        self.len = title.len;
    }
};

test "OSC 2 window title parsing" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    var mock = TitleMock{};
    parser.title_cb = TitleMock.callback;
    parser.title_ctx = &mock;

    try parser.feed("\x1b]2;Python Editor\x07");
    try testing.expect(mock.called);
    try testing.expectEqualStrings("Python Editor", mock.title[0..mock.len]);
}

test "DCS string ignored" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed(&[_]u8{ 0x90, 0x61, 0x62, 0x9C }); // DCS "ab" ST
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "invalid CSI ignored" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[?z"); // invalid final byte
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "SGR 256-colour background" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[48;5;99mA");
    try testing.expectEqual(@as(u8, 99), screen.grid.getCell(0, 0).bg.value);
}

test "SGR true colour background" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[48;2;10;20;30mA");
    const cell = screen.grid.getCell(0, 0);
    try testing.expectEqual(@as(u24, 0x0A141E), cell.bg.value);
}

test "SGR bright fg colours" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[95mA");
    try testing.expectEqual(@as(u8, 13), screen.grid.getCell(0, 0).fg.value);
}

test "CNL with default param 1" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 3;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[E");
    try testing.expectEqual(@as(u32, 4), screen.cursor.y);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "CPL with default param 1" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.y = 3;
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[F");
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

test "SGR dim on and off" {
    var screen = try Screen.init(testing.allocator, 10, 3);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2;22mX");
    try testing.expect(!screen.grid.getCell(0, 0).attr.dim);
}

test "ESC = and > (keypad mode) no crash" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b=\x1b>");
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

test "newline at bottom of scroll region" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2;4r");
    try screen.writeStr("aaaa\nbbbb\ncccc\ndddd\neeee");
    screen.cursor.x = 0;
    screen.cursor.y = 3;
    try parser.feed("\n");
    try testing.expectEqual(@as(u32, 3), screen.cursor.y);
}

test "cursorPosition honours origin mode" {
    var screen = try Screen.init(testing.allocator, 10, 5);
    defer screen.deinit();
    screen.setScrollRegion(1, 3);
    screen.setOriginMode(true);
    var parser = InputParser.init(&screen);
    try parser.feed("\x1b[2;1H");
    try testing.expectEqual(@as(u32, 2), screen.cursor.y);
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
}

const VMIN: usize = 16;
const VTIME: usize = 17;

fn setRaw(fd: i32) void {
    var raw: std.c.termios = undefined;
    _ = std.c.tcgetattr(fd, &raw);
    raw.iflag = .{ .BRKINT = true };
    raw.lflag = .{};
    raw.oflag = .{};
    raw.cc[VMIN] = 1;
    raw.cc[VTIME] = 0;
    _ = std.c.tcsetattr(fd, std.c.TCSA.FLUSH, &raw);
}

test "DSR cursor position report" {
    const pty_mod = @import("server/pty.zig");
    var pty = try pty_mod.Pty.open();
    defer pty.deinit();
    setRaw(pty.slave);

    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    var parser = InputParser.init(&screen);
    parser.pty = &pty;

    try parser.feed("\x1b[6n");

    // Read response from the slave end: \x1b[<row>;<col>R
    var resp: [32]u8 = undefined;
    const n = std.c.read(pty.slave, &resp, resp.len);
    try testing.expect(n > 0);
    const expected = "\x1b[1;1R";
    try testing.expectEqual(@as(usize, expected.len), @as(usize, @intCast(n)));
    try testing.expectEqualStrings(expected, resp[0..@as(usize, @intCast(n))]);
}

test "DSR cursor position report with cursor moved" {
    const pty_mod = @import("server/pty.zig");
    var pty = try pty_mod.Pty.open();
    defer pty.deinit();
    setRaw(pty.slave);

    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    screen.cursor.x = 5;
    screen.cursor.y = 3;

    var parser = InputParser.init(&screen);
    parser.pty = &pty;

    try parser.feed("\x1b[6n");

    var resp: [32]u8 = undefined;
    const n = std.c.read(pty.slave, &resp, resp.len);
    try testing.expect(n > 0);
    const expected = "\x1b[4;6R";
    try testing.expectEqual(@as(usize, expected.len), @as(usize, @intCast(n)));
    try testing.expectEqualStrings(expected, resp[0..@as(usize, @intCast(n))]);
}

test "3-byte ESC sequences are consumed and ignored without cursor side effects" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);

    // Initial cursor: (0, 0)
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u32, 0), screen.cursor.y);

    // Feed G0 charset selection to ASCII: ESC ( B
    // If parsed incorrectly as CSI B, it would execute CUD (Cursor Down) and move cursor.y to 1.
    try parser.feed("\x1b(B");

    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));

    // Feed G0 charset selection to Line Drawing: ESC ( 0
    try parser.feed("\x1b(0");

    try testing.expectEqual(@as(u32, 0), screen.cursor.y);
    try testing.expectEqual(@as(u8, @intFromEnum(InputParser.State.ground)), @intFromEnum(parser.state));
}

// ─── Sixel tests ────────────────────────────────────────────────────────────

test "sixel DCS ESC-backslash terminator stores image" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // Minimal sixel: ESC P q <payload> ESC \
    // The payload is just one band of 'A' (0x41 in sixel = colour 1, 6 pixels tall).
    const sixel = "\x1bPq!1A\x1b\\";
    try parser.feed(sixel);

    // After dispatch the parser must be back in ground state.
    try testing.expectEqual(InputParser.State.ground, parser.state);

    // Exactly one image should have been stored.
    try testing.expectEqual(@as(usize, 1), screen.sixel_images.items.len);

    // The stored data must contain the raw DCS bytes including the ST.
    const img = screen.sixel_images.items[0];
    try testing.expect(std.mem.indexOf(u8, img.data, "\x1bP") != null);
    try testing.expect(std.mem.endsWith(u8, img.data, "\x1b\\"));

    // Image was anchored at cursor origin (0,0).
    try testing.expectEqual(@as(u32, 0), img.col);
    try testing.expectEqual(@as(u32, 0), img.row);
}

test "sixel DCS 8-bit ST (0x9C) terminator stores image" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // Same as above but using the 8-bit C1 ST (0x9C) instead of ESC \.
    const sixel = "\x1bPqAA\x9c";
    try parser.feed(sixel);

    try testing.expectEqual(InputParser.State.ground, parser.state);
    try testing.expectEqual(@as(usize, 1), screen.sixel_images.items.len);
    // Data should still contain the trailing ESC \ (we normalise to 7-bit).
    try testing.expect(std.mem.endsWith(u8, screen.sixel_images.items[0].data, "\x1b\\"));
}

test "sixel pixel height estimated from band count" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // 3 '-' characters = 4 bands (initial 1 + 3 newlines) = 24 px height.
    const sixel = "\x1bPqA-A-A-A\x1b\\";
    try parser.feed(sixel);

    try testing.expectEqual(@as(usize, 1), screen.sixel_images.items.len);
    // bands = 1 + count('-') = 1 + 3 = 4,  px_height = 4 * 6 = 24
    try testing.expectEqual(@as(u32, 24), screen.sixel_images.items[0].px_height);
}

test "sixel cursor advances after image" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // Single-band image (6 px tall, 1 cell row = 1 row advance).
    const sixel = "\x1bPqA\x1b\\";
    try parser.feed(sixel);

    // Cursor should have moved down by 1 row and reset to column 0.
    try testing.expectEqual(@as(u32, 0), screen.cursor.x);
    try testing.expectEqual(@as(u32, 1), screen.cursor.y);
}

test "sixel from dcs_param path (ESC P 0 ; 0 q ...)" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // With parameters before 'q': ESC P 0 ; 0 q <payload> ESC \
    const sixel = "\x1bP0;0qA\x1b\\";
    try parser.feed(sixel);

    try testing.expectEqual(InputParser.State.ground, parser.state);
    try testing.expectEqual(@as(usize, 1), screen.sixel_images.items.len);
}

test "non-sixel DCS sequence is silently discarded" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);

    // tmux passthrough DCS (final byte '!') — not sixel, must be dropped.
    const tmux_dcs = "\x1bPtmux;\x1b\x1b[31mHello\x1b\x1b[m\x1b\\";
    try parser.feed(tmux_dcs);

    try testing.expectEqual(InputParser.State.ground, parser.state);
    // No images stored.
    try testing.expectEqual(@as(usize, 0), screen.sixel_images.items.len);
}

// ─── Device Attributes tests ─────────────────────────────────────────────────
//
// We need to capture bytes that InputParser writes back to the child via
// Pty.writeInput(). writeInput() only calls write(self.master, ...), so we
// create a fake Pty with master = pipe write-end and read from the read-end.
// This avoids PTY line-discipline transformations (e.g. echo, ^[ expansion).

const Pty = @import("server/pty.zig").Pty;
const c_sys = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

/// Create a fake Pty whose writeInput writes into a pipe.
/// Returns {pty, read_fd}. Caller must close read_fd and call pty.deinit().
fn makePipePty() !struct { pty: Pty, read_fd: i32 } {
    var fds: [2]i32 = undefined;
    if (c_sys.pipe(&fds) < 0) return error.PipeFailed;
    return .{
        .pty = Pty{ .master = fds[1], .slave = -1, .pid = -1 },
        .read_fd = fds[0],
    };
}

/// Read all available bytes from a pipe fd into buf (non-blocking).
fn drainFd(fd: i32, buf: []u8) []u8 {
    _ = c_sys.fcntl(fd, c_sys.F_SETFL, c_sys.O_NONBLOCK);
    const n = c_sys.read(fd, buf.ptr, buf.len);
    if (n <= 0) return buf[0..0];
    return buf[0..@intCast(n)];
}
test "DA1 (CSI c) responds with sixel capability" {
    var p = try makePipePty();
    defer _ = c_sys.close(p.read_fd);
    defer p.pty.deinit();

    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);
    parser.pty = &p.pty;

    try parser.feed("\x1b[c"); // DA1

    var buf: [64]u8 = undefined;
    const got = drainFd(p.read_fd, &buf);
    try testing.expectEqualStrings("\x1b[?63;4;22c", got);
}

test "DA2 (CSI > c) responds with secondary attributes" {
    var p = try makePipePty();
    defer _ = c_sys.close(p.read_fd);
    defer p.pty.deinit();

    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);
    parser.pty = &p.pty;

    try parser.feed("\x1b[>c"); // DA2

    var buf: [64]u8 = undefined;
    const got = drainFd(p.read_fd, &buf);
    try testing.expectEqualStrings("\x1b[>0;10;0c", got);
}

test "XTSMGRAPHICS (CSI ? 2 ; 1 S) reports sixel supported" {
    var p = try makePipePty();
    defer _ = c_sys.close(p.read_fd);
    defer p.pty.deinit();

    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();
    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);
    parser.pty = &p.pty;

    try parser.feed("\x1b[?2;1S"); // XTSMGRAPHICS sixel query

    var buf: [64]u8 = undefined;
    const got = drainFd(p.read_fd, &buf);
    // Ps1=2 echoed back, status=0 (supported), width=0 height=0 (unlimited)
    try testing.expectEqualStrings("\x1b[?2;0;0S", got);
}

test "XTSMGRAPHICS does not interfere with scroll-up (CSI S without ?)" {
    var screen = try Screen.init(testing.allocator, 80, 5);
    defer screen.deinit();

    // Fill rows so we can detect a scroll.
    for (0..5) |i| screen.grid.writeChar(0, @intCast(i), @intCast('A' + i));

    var parser = InputParser.init(&screen);
    defer parser.deinit(testing.allocator);
    // No PTY — scroll-up must still work normally.

    try parser.feed("\x1b[1S"); // CSI 1 S = scroll up 1 line (no intermediate)

    // 'A' moved to history; visible row 0 is now what was row 1 ('B').
    try testing.expectEqual(@as(u21, 'B'), screen.grid.getCell(0, 0).char);
}
