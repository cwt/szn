const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const Colour = colour.Colour;
const key = @import("key.zig");
const Key = key.Key;

pub const Error = error{
    OutOfMemory,
    UnknownOption,
    TypeMismatch,
    OutOfRange,
    InvalidChoice,
};

pub const OptionType = enum {
    number,
    string,
    colour,
    key,
    flag,
    choice,
};

pub const OptionValue = union(enum) {
    number: i64,
    string: []const u8,
    colour: Colour,
    key: Key,
    flag: bool,
    choice: []const u8,
};

pub const OptionDef = struct {
    name: []const u8,
    type: OptionType,
    default: OptionValue,
    choices: ?[]const []const u8 = null,
    min: ?i64 = null,
    max: ?i64 = null,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    values: []OptionValue,
    table: []const OptionDef,

    pub fn init(allocator: std.mem.Allocator, table: []const OptionDef) Error!Options {
        const values = try allocator.alloc(OptionValue, table.len);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                freeValue(allocator, values[j]);
            }
            allocator.free(values);
        }
        while (i < table.len) : (i += 1) {
            values[i] = try cloneValue(allocator, table[i].default);
        }
        return Options{ .allocator = allocator, .values = values, .table = table };
    }

    pub fn clone(self: *const Options, allocator: std.mem.Allocator) Error!Options {
        const new_values = try allocator.alloc(OptionValue, self.table.len);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                freeValue(allocator, new_values[j]);
            }
            allocator.free(new_values);
        }
        while (i < self.table.len) : (i += 1) {
            new_values[i] = try cloneValue(allocator, self.values[i]);
        }
        return Options{ .allocator = allocator, .values = new_values, .table = self.table };
    }

    pub fn deinit(self: *Options) void {
        for (self.values) |val| {
            freeValue(self.allocator, val);
        }
        self.allocator.free(self.values);
    }

    /// Set an option value. The value is **cloned** internally (strings are
    /// `allocator.dupe`'d). The caller retains ownership of the passed value
    /// and may free it immediately after this call.
    ///
    /// Coercions (tmux-friendly):
    /// - flag on/off → choice "on"/"off" when the option is a choice
    /// - string matching a choice → choice
    /// - string colour name/hex → colour when the option is a colour
    pub fn set(self: *Options, name: []const u8, value: OptionValue) Error!void {
        const idx = self.findDef(name) orelse return error.UnknownOption;
        const def = self.table[idx];
        const coerced = try coerceValue(def, value);
        try validateType(def, coerced);

        const old_value = self.values[idx];
        const cloned = try cloneValue(self.allocator, coerced);
        self.values[idx] = cloned;
        freeValue(self.allocator, old_value);
    }

    pub fn get(self: *const Options, name: []const u8) ?OptionValue {
        const idx = self.findDef(name) orelse return null;
        return self.values[idx];
    }

    pub fn unset(self: *Options, name: []const u8) Error!void {
        const idx = self.findDef(name) orelse return error.UnknownOption;
        const old_value = self.values[idx];
        const default_val = try cloneValue(self.allocator, self.table[idx].default);
        self.values[idx] = default_val;
        freeValue(self.allocator, old_value);
    }

    pub fn asNumber(self: *const Options, name: []const u8) ?i64 {
        const v = self.get(name) orelse return null;
        return if (v == .number) v.number else null;
    }

    pub fn asString(self: *const Options, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            .choice => |c| c,
            else => null,
        };
    }

    pub fn asFlag(self: *const Options, name: []const u8) ?bool {
        const v = self.get(name) orelse return null;
        return if (v == .flag) v.flag else null;
    }

    pub fn asColour(self: *const Options, name: []const u8) ?Colour {
        const v = self.get(name) orelse return null;
        return if (v == .colour) v.colour else null;
    }

    fn findDef(self: *const Options, name: []const u8) ?usize {
        for (self.table, 0..) |def, i| {
            if (std.mem.eql(u8, def.name, name)) return i;
        }
        return null;
    }
};

fn coerceValue(def: OptionDef, value: OptionValue) Error!OptionValue {
    switch (def.type) {
        .choice => {
            switch (value) {
                .flag => |b| return OptionValue{ .choice = if (b) "on" else "off" },
                .string => |s| {
                    if (def.choices) |choices| {
                        for (choices) |c| {
                            if (std.mem.eql(u8, s, c)) return OptionValue{ .choice = s };
                        }
                    }
                    return value;
                },
                else => return value,
            }
        },
        .colour => {
            switch (value) {
                .string => |s| {
                    if (colour.parse(s)) |c| return OptionValue{ .colour = c } else |_| return value;
                },
                else => return value,
            }
        },
        else => return value,
    }
}

fn validateType(def: OptionDef, value: OptionValue) Error!void {
    const tag = switch (value) {
        .number => OptionType.number,
        .string => OptionType.string,
        .colour => OptionType.colour,
        .key => OptionType.key,
        .flag => OptionType.flag,
        .choice => OptionType.choice,
    };
    if (tag != def.type) return error.TypeMismatch;

    if (tag == .number) {
        if (def.min) |min| if (value.number < min) return error.OutOfRange;
        if (def.max) |max| if (value.number > max) return error.OutOfRange;
    }

    if (tag == .choice) {
        if (def.choices) |c| {
            for (c) |choice| {
                if (std.mem.eql(u8, value.choice, choice)) return;
            }
            return error.InvalidChoice;
        }
    }
}

fn cloneValue(allocator: std.mem.Allocator, value: OptionValue) Error!OptionValue {
    return switch (value) {
        .string => |s| OptionValue{ .string = try allocator.dupe(u8, s) },
        .choice => |c| OptionValue{ .choice = try allocator.dupe(u8, c) },
        inline else => value,
    };
}

fn freeValue(allocator: std.mem.Allocator, value: OptionValue) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .choice => |c| allocator.free(c),
        .number, .colour, .key, .flag => {},
    }
}

// ── Option Tables ──

pub const SESSION_OPTIONS = &[_]OptionDef{
    .{ .name = "default-shell", .type = .string, .default = OptionValue{ .string = "" } },
    .{ .name = "default-terminal", .type = .string, .default = OptionValue{ .string = "tmux-256color" } },
    .{ .name = "status", .type = .choice, .default = OptionValue{ .choice = "on" }, .choices = &[_][]const u8{ "off", "on", "2", "3", "4", "5" } },
    .{ .name = "status-interval", .type = .number, .default = OptionValue{ .number = 15 }, .min = 0, .max = 86400 },
    .{ .name = "status-fg", .type = .colour, .default = OptionValue{ .colour = Colour.default_() } },
    .{ .name = "status-bg", .type = .colour, .default = OptionValue{ .colour = Colour.fromRgb(0x00, 0x5f, 0xaf) } },
    .{ .name = "status-left", .type = .string, .default = OptionValue{ .string = "[#{session_name}] " } },
    .{ .name = "status-right", .type = .string, .default = OptionValue{ .string = "\"#{=21:pane_title}\" %H:%M %d-%b-%y" } },
    .{ .name = "status-left-length", .type = .number, .default = OptionValue{ .number = 10 }, .min = 0, .max = 1024 },
    .{ .name = "status-right-length", .type = .number, .default = OptionValue{ .number = 40 }, .min = 0, .max = 1024 },
    .{ .name = "status-justify", .type = .choice, .default = OptionValue{ .choice = "left" }, .choices = &[_][]const u8{ "left", "centre", "center", "right" } },
    .{ .name = "pane-border-fg", .type = .colour, .default = OptionValue{ .colour = Colour.fromRgb(0x55, 0x55, 0x55) } },
    .{ .name = "pane-active-border-fg", .type = .colour, .default = OptionValue{ .colour = Colour.fromRgb(0x00, 0x5f, 0xaf) } },
    .{ .name = "pane-border-format", .type = .string, .default = OptionValue{ .string = "#P" } },
    .{ .name = "history-limit", .type = .number, .default = OptionValue{ .number = 2000 }, .min = 0, .max = 1000000 },
    .{ .name = "mouse", .type = .flag, .default = OptionValue{ .flag = true } },
    .{ .name = "prefix", .type = .key, .default = OptionValue{ .key = Key{ .char = .{ .code = 'b', .mod = .{ .ctrl = true } } } } }, // C-b
    .{ .name = "prefix2", .type = .key, .default = OptionValue{ .key = .{ .special = .{ .key = .escape } } } },
    .{ .name = "escape-time", .type = .number, .default = OptionValue{ .number = 500 }, .min = 0, .max = 10000 },
    .{ .name = "base-index", .type = .number, .default = OptionValue{ .number = 0 }, .min = 0, .max = 9999 },
    .{ .name = "pane-base-index", .type = .number, .default = OptionValue{ .number = 0 }, .min = 0, .max = 9999 },
    .{ .name = "display-time", .type = .number, .default = OptionValue{ .number = 1000 }, .min = 0, .max = 60000 },
    .{ .name = "set-titles", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "set-clipboard", .type = .choice, .default = OptionValue{ .choice = "external" }, .choices = &[_][]const u8{ "off", "external", "on" } },
    // Per-codepoint width overrides, mirroring tmux `codepoint-widths`.
    // Format: a space-separated list of entries, each "U+XXXX=W" or
    // "U+XXXX-U+YYYY=W" (W is 1 or 2). Use this to match a terminal
    // that renders ambiguous emoji/symbols at a width szn does not assume
    // by default (bug #206). Setting the option rebuilds the override
    // table from scratch; e.g. `set -g codepoint-widths "U+2705=1"`.
    .{ .name = "codepoint-widths", .type = .string, .default = OptionValue{ .string = "" } },
};

pub const WINDOW_OPTIONS = &[_]OptionDef{
    .{ .name = "aggressive-resize", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "clock-mode-colour", .type = .colour, .default = OptionValue{ .colour = Colour.default_() } },
    .{ .name = "clock-mode-style", .type = .choice, .default = OptionValue{ .choice = "24" }, .choices = &[_][]const u8{ "12", "24" } },
    .{ .name = "main-pane-height", .type = .number, .default = OptionValue{ .number = 24 }, .min = 1, .max = 9999 },
    .{ .name = "main-pane-width", .type = .number, .default = OptionValue{ .number = 80 }, .min = 1, .max = 9999 },
    .{ .name = "mode-keys", .type = .choice, .default = OptionValue{ .choice = "emacs" }, .choices = &[_][]const u8{ "emacs", "vi" } },
    .{ .name = "monitor-activity", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "monitor-silence", .type = .number, .default = OptionValue{ .number = 0 }, .min = 0, .max = 86400 },
    .{ .name = "remain-on-exit", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "synchronize-panes", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "word-separators", .type = .string, .default = OptionValue{ .string = " -_@" } },
    .{ .name = "fill-character", .type = .string, .default = OptionValue{ .string = " " } },
    .{ .name = "window-status-format", .type = .string, .default = OptionValue{ .string = "#I:#W#{?window_flags,#{window_flags}, }" } },
    .{ .name = "window-status-current-format", .type = .string, .default = OptionValue{ .string = "#I:#W#{?window_flags,#{window_flags}, }" } },
};

// ── Tests ──

test "create options with defaults" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectEqual(@as(i64, 15), opts.asNumber("status-interval").?);
    try testing.expectEqualStrings("tmux-256color", opts.asString("default-terminal").?);
    try testing.expect(opts.asFlag("mouse").?);
}

test "set and get number option" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try opts.set("status-interval", OptionValue{ .number = 30 });
    try testing.expectEqual(@as(i64, 30), opts.asNumber("status-interval").?);
}

test "set and get string option" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try opts.set("default-shell", OptionValue{ .string = "/bin/zsh" });
    try testing.expectEqualStrings("/bin/zsh", opts.asString("default-shell").?);
}

test "set and get flag option" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try opts.set("mouse", OptionValue{ .flag = true });
    try testing.expect(opts.asFlag("mouse").?);
}

test "unknown option returns null" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expect(opts.get("nonexistent") == null);
}

test "set unknown option fails" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectError(error.UnknownOption, opts.set("fake-option", OptionValue{ .number = 1 }));
}

test "type mismatch on set" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectError(error.TypeMismatch, opts.set("status-interval", OptionValue{ .flag = true }));
}

test "unset option restores default" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try opts.set("status-interval", OptionValue{ .number = 99 });
    try opts.unset("status-interval");
    try testing.expectEqual(@as(i64, 15), opts.asNumber("status-interval").?);
}

test "choice validation" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectError(error.InvalidChoice, opts.set("status", OptionValue{ .choice = "invalid" }));
    try opts.set("status", OptionValue{ .choice = "off" });
    try testing.expectEqualStrings("off", opts.asString("status").?);
}

test "range validation" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectError(error.OutOfRange, opts.set("status-interval", OptionValue{ .number = 999999 }));
    try testing.expectError(error.OutOfRange, opts.set("status-interval", OptionValue{ .number = -1 }));
}

test "window options" {
    var opts = try Options.init(testing.allocator, WINDOW_OPTIONS);
    defer opts.deinit();

    try testing.expect(!opts.asFlag("aggressive-resize").?);
    try testing.expectEqualStrings("emacs", opts.asString("mode-keys").?);
    try opts.set("mode-keys", OptionValue{ .choice = "vi" });
    try testing.expectEqualStrings("vi", opts.asString("mode-keys").?);
}

test "get non-existent typed value" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expect(opts.asNumber("nonexistent") == null);
    try testing.expect(opts.asString("nonexistent") == null);
    try testing.expect(opts.asFlag("nonexistent") == null);
    try testing.expect(opts.asColour("nonexistent") == null);
}

test "colour option" {
    var opts = try Options.init(testing.allocator, WINDOW_OPTIONS);
    defer opts.deinit();

    const red = Colour.fromIndexed(1);
    try opts.set("clock-mode-colour", OptionValue{ .colour = red });
    const c = opts.asColour("clock-mode-colour").?;
    try testing.expectEqual(@as(u8, 1), @as(u8, @truncate(c.value)));
}

test "Options.set dupes strings — caller retains ownership" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    // Allocate a string, transfer to Options.set, then free the original.
    const original = try testing.allocator.dupe(u8, "/bin/bash");
    defer testing.allocator.free(original);

    try opts.set("default-shell", OptionValue{ .string = original });

    // After freeing the original, Options must still hold its own copy.
    try testing.expectEqualStrings("/bin/bash", opts.asString("default-shell").?);
}

test "Options.set dupes choice values — caller retains ownership" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    const original = try testing.allocator.dupe(u8, "on");
    defer testing.allocator.free(original);

    try opts.set("status", OptionValue{ .choice = original });

    try testing.expectEqualStrings("on", opts.get("status").?.choice);
}

test "Options.freeValue frees choice strings — bug #116" {
    const allocator = testing.allocator;
    var opts = try Options.init(allocator, SESSION_OPTIONS);
    defer opts.deinit();

    const dyn = try allocator.dupe(u8, "off");
    try opts.set("status", OptionValue{ .choice = dyn });
    allocator.free(dyn);

    // If choice was not cloned, this would be use-after-free.
    try testing.expectEqualStrings("off", opts.get("status").?.choice);
}
