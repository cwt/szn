const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const Colour = colour.Colour;
const key = @import("key.zig");
const Key = key.Key;

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
    map: std.StringHashMap(OptionValue),
    table: []const OptionDef,

    pub fn init(allocator: std.mem.Allocator, table: []const OptionDef) !Options {
        var map = std.StringHashMap(OptionValue).init(allocator);
        for (table) |def| {
            const name = try allocator.dupe(u8, def.name);
            try map.put(name, try cloneValue(allocator, def.default));
        }
        return Options{ .allocator = allocator, .map = map, .table = table };
    }

    pub fn clone(self: *const Options, allocator: std.mem.Allocator) !Options {
        var new_map = std.StringHashMap(OptionValue).init(allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);
            const val = try cloneValue(allocator, entry.value_ptr.*);
            try new_map.put(name, val);
        }
        return Options{ .allocator = allocator, .map = new_map, .table = self.table };
    }

    pub fn deinit(self: *Options) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn set(self: *Options, name: []const u8, value: OptionValue) !void {
        const idx = self.findDef(name) orelse return error.UnknownOption;
        const def = self.table[idx];
        try validateType(def, value);

        // Copy old key/value, remove, then free
        if (self.map.getEntry(name)) |entry| {
            const old_key = entry.key_ptr.*;
            const old_value = entry.value_ptr.*;
            _ = self.map.remove(name);
            self.allocator.free(old_key);
            freeValue(self.allocator, old_value);
        }

        const key_name = try self.allocator.dupe(u8, name);
        try self.map.put(key_name, try cloneValue(self.allocator, value));
    }

    pub fn get(self: *Options, name: []const u8) ?OptionValue {
        const entry = self.map.getEntry(name) orelse return null;
        return entry.value_ptr.*;
    }

    pub fn unset(self: *Options, name: []const u8) !void {
        // Copy old key/value, remove, then free
        if (self.map.getEntry(name)) |entry| {
            const old_key = entry.key_ptr.*;
            const old_value = entry.value_ptr.*;
            _ = self.map.remove(name);
            self.allocator.free(old_key);
            freeValue(self.allocator, old_value);
        }
        // Restore default
        if (self.findDef(name)) |idx| {
            const key_name = try self.allocator.dupe(u8, name);
            try self.map.put(key_name, try cloneValue(self.allocator, self.table[idx].default));
        }
    }

    pub fn asNumber(self: *Options, name: []const u8) ?i64 {
        const v = self.get(name) orelse return null;
        return if (v == .number) v.number else null;
    }

    pub fn asString(self: *Options, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            .choice => |c| c,
            else => null,
        };
    }

    pub fn asFlag(self: *Options, name: []const u8) ?bool {
        const v = self.get(name) orelse return null;
        return if (v == .flag) v.flag else null;
    }

    pub fn asColour(self: *Options, name: []const u8) ?Colour {
        const v = self.get(name) orelse return null;
        return if (v == .colour) v.colour else null;
    }

    fn findDef(self: *Options, name: []const u8) ?usize {
        for (self.table, 0..) |def, i| {
            if (std.mem.eql(u8, def.name, name)) return i;
        }
        return null;
    }
};

fn validateType(def: OptionDef, value: OptionValue) !void {
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

fn cloneValue(allocator: std.mem.Allocator, value: OptionValue) !OptionValue {
    return switch (value) {
        .string => |s| OptionValue{ .string = try allocator.dupe(u8, s) },
        inline else => value,
    };
}

fn freeValue(allocator: std.mem.Allocator, value: OptionValue) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number, .colour, .key, .flag, .choice => {},
    }
}

// ── Option Tables ──

pub const SESSION_OPTIONS = &[_]OptionDef{
    .{ .name = "default-shell", .type = .string, .default = OptionValue{ .string = "/bin/sh" } },
    .{ .name = "default-terminal", .type = .string, .default = OptionValue{ .string = "xterm-256color" } },
    .{ .name = "status", .type = .choice, .default = OptionValue{ .choice = "on" }, .choices = &[_][]const u8{ "off", "on", "2", "3", "4", "5" } },
    .{ .name = "status-interval", .type = .number, .default = OptionValue{ .number = 15 }, .min = 0, .max = 86400 },
    .{ .name = "history-limit", .type = .number, .default = OptionValue{ .number = 2000 }, .min = 0, .max = 1000000 },
    .{ .name = "mouse", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "prefix", .type = .key, .default = OptionValue{ .key = Key{ .char = .{ .code = 'b', .mod = .{ .ctrl = true } } } } }, // C-b
    .{ .name = "prefix2", .type = .key, .default = OptionValue{ .key = .{ .special = .{ .key = .escape } } } },
    .{ .name = "escape-time", .type = .number, .default = OptionValue{ .number = 500 }, .min = 0, .max = 10000 },
    .{ .name = "base-index", .type = .number, .default = OptionValue{ .number = 0 }, .min = 0, .max = 9999 },
    .{ .name = "pane-base-index", .type = .number, .default = OptionValue{ .number = 0 }, .min = 0, .max = 9999 },
    .{ .name = "display-time", .type = .number, .default = OptionValue{ .number = 1000 }, .min = 0, .max = 60000 },
    .{ .name = "set-titles", .type = .flag, .default = OptionValue{ .flag = false } },
    .{ .name = "set-clipboard", .type = .choice, .default = OptionValue{ .choice = "external" }, .choices = &[_][]const u8{ "off", "external", "on" } },
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
};

// ── Tests ──

test "create options with defaults" {
    var opts = try Options.init(testing.allocator, SESSION_OPTIONS);
    defer opts.deinit();

    try testing.expectEqual(@as(i64, 15), opts.asNumber("status-interval").?);
    try testing.expectEqualStrings("xterm-256color", opts.asString("default-terminal").?);
    try testing.expect(!opts.asFlag("mouse").?);
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
