const std = @import("std");
const testing = std.testing;
const colour = @import("colour.zig");
const options_mod = @import("options.zig");
const Options = options_mod.Options;
const OptionValue = options_mod.OptionValue;
const key = @import("key.zig");
const Key = key.Key;

pub const Directive = union(enum) {
    set: SetOpt,
    bind_key: BindKey,
    unbind_key: UnbindKey,
    set_environment: SetEnv,
    source_file: []const u8,
    if_shell: IfShell,
};

pub const SetOpt = struct {
    flags: struct {
        global: bool = false,
        session: bool = false,
        window: bool = false,
        server: bool = false,
    },
    option: []const u8,
    value: OptionValue,
};

pub const BindKey = struct {
    flags: struct {
        reverse: bool = false,
        key_table: ?[]const u8 = null,
    },
    key: Key,
    command: []const u8,
};

pub const UnbindKey = struct {
    flags: struct {
        key_table: ?[]const u8 = null,
    },
    key: Key,
};

pub const SetEnv = struct {
    flags: struct {
        global: bool = false,
    },
    name: []const u8,
    value: ?[]const u8,
};

pub const IfShell = struct {
    condition: []const u8,
    command: []const u8,
};

pub const ParseResult = struct {
    directives: std.ArrayListUnmanaged(Directive),
    errors: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.directives.items) |*d| {
            switch (d.*) {
                .set => |s| {
                    allocator.free(s.option);
                    if (s.value == .string) allocator.free(s.value.string);
                },
                .bind_key => |b| {
                    allocator.free(b.command);
                },
                .unbind_key => {},
                .set_environment => |e| {
                    allocator.free(e.name);
                    if (e.value) |v| allocator.free(v);
                },
                .source_file => |p| allocator.free(p),
                .if_shell => |i| {
                    allocator.free(i.condition);
                    allocator.free(i.command);
                },
            }
        }
        self.directives.deinit(allocator);
        for (self.errors.items) |e| allocator.free(e);
        self.errors.deinit(allocator);
    }
};

pub fn parseConfig(allocator: std.mem.Allocator, input: []const u8) !ParseResult {
    var result = ParseResult{
        .directives = .empty,
        .errors = .empty,
    };

    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Strip trailing comment (inline #)
        const cmd_line = stripInlineComment(line);

        if (std.mem.startsWith(u8, cmd_line, "set ")) {
            parseSet(allocator, cmd_line[4..], &result) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "set error: {}", .{e});
                try result.errors.append(allocator, msg);
            };
        } else if (std.mem.startsWith(u8, cmd_line, "bind-key ")) {
            parseBindKey(allocator, cmd_line[9..], &result) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "bind-key error: {}", .{e});
                try result.errors.append(allocator, msg);
            };
        } else if (std.mem.startsWith(u8, cmd_line, "unbind-key ")) {
            parseUnbindKey(allocator, cmd_line[11..], &result) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "unbind-key error: {}", .{e});
                try result.errors.append(allocator, msg);
            };
        } else if (std.mem.startsWith(u8, cmd_line, "set-environment ")) {
            parseSetEnv(allocator, cmd_line[15..], &result) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "set-environment error: {}", .{e});
                try result.errors.append(allocator, msg);
            };
        } else if (std.mem.startsWith(u8, cmd_line, "source-file ")) {
            const path = try allocator.dupe(u8, std.mem.trim(u8, cmd_line[12..], " \t"));
            try result.directives.append(allocator, Directive{ .source_file = path });
        } else if (std.mem.startsWith(u8, cmd_line, "if-shell ")) {
            parseIfShell(allocator, cmd_line[9..], &result) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "if-shell error: {}", .{e});
                try result.errors.append(allocator, msg);
            };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "unknown directive: {s}", .{cmd_line});
            try result.errors.append(allocator, msg);
        }
    }

    return result;
}

fn stripInlineComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |pos| {
        // Check if # is inside quotes
        if (pos == 0) return line[0..0];
        const before = line[0..pos];
        // Count quotes before #
        var in_quote = false;
        for (before) |c| {
            if (c == '"') in_quote = !in_quote;
        }
        if (!in_quote) return std.mem.trim(u8, before, " \t");
    }
    return line;
}

fn parseSet(allocator: std.mem.Allocator, args: []const u8, result: *ParseResult) !void {
    const trimmed = std.mem.trim(u8, args, " \t");
    var flags = SetOpt{ .flags = .{}, .option = undefined, .value = undefined };
    var remaining = trimmed;

    // Parse flags: -g, -s, -w, -u
    while (remaining.len > 0 and remaining[0] == '-') {
        if (remaining.len < 2) break;
        switch (remaining[1]) {
            'g' => flags.flags.global = true,
            's' => flags.flags.session = true,
            'w' => flags.flags.window = true,
            'u' => return, // unset (handled elsewhere)
            else => break,
        }
        remaining = std.mem.trim(u8, if (remaining.len > 2) remaining[2..] else "", " \t");
    }

    // Parse option name
    const space_pos = std.mem.indexOfScalar(u8, remaining, ' ') orelse return error.MissingValue;
    flags.option = try allocator.dupe(u8, remaining[0..space_pos]);
    const val_str = std.mem.trim(u8, remaining[space_pos + 1 ..], " \t");

    // Parse value based on content
    flags.value = try parseValue(allocator, val_str);

    try result.directives.append(allocator, Directive{ .set = flags });
}

fn parseValue(allocator: std.mem.Allocator, s: []const u8) !OptionValue {
    // Boolean values
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "on")) return OptionValue{ .flag = true };
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "off")) return OptionValue{ .flag = false };

    // Quoted string
    if (s.len >= 2 and s[0] == '"') {
        const inner = s[1 .. s.len - 1];
        return OptionValue{ .string = try allocator.dupe(u8, inner) };
    }

    // Number
    if (s.len > 0 and (s[0] == '-' or std.ascii.isDigit(s[0]))) {
        if (std.fmt.parseInt(i64, s, 10)) |n| {
            return OptionValue{ .number = n };
        } else |_| {}
    }

    // Colour (hex or colourN)
    if (s.len > 0 and s[0] == '#') {
        if (colour.parse(s)) |c| return OptionValue{ .colour = c } else |_| {}
    }
    if (std.ascii.startsWithIgnoreCase(s, "colour") or std.ascii.startsWithIgnoreCase(s, "color")) {
        if (colour.parse(s)) |c| return OptionValue{ .colour = c } else |_| {}
    }

    // Key
    if (s.len > 0) {
        // Try parsing key name
        _ = key;
    }

    // Default to string
    return OptionValue{ .string = try allocator.dupe(u8, s) };
}

fn parseBindKey(allocator: std.mem.Allocator, args: []const u8, result: *ParseResult) !void {
    const trimmed = std.mem.trim(u8, args, " \t");
    const msg = try std.fmt.allocPrint(allocator, "bind-key: {s}", .{trimmed});
    try result.errors.append(allocator, msg);
}

fn parseUnbindKey(allocator: std.mem.Allocator, args: []const u8, result: *ParseResult) !void {
    const msg = try std.fmt.allocPrint(allocator, "unbind-key: {s}", .{args});
    try result.errors.append(allocator, msg);
}

fn parseSetEnv(allocator: std.mem.Allocator, args: []const u8, result: *ParseResult) !void {
    const trimmed = std.mem.trim(u8, args, " \t");
    var remaining = trimmed;
    var global = false;

    if (std.mem.startsWith(u8, remaining, "-g ")) {
        global = true;
        remaining = std.mem.trim(u8, remaining[3..], " \t");
    }

    if (std.mem.indexOfScalar(u8, remaining, '=')) |eq_pos| {
        const name = try allocator.dupe(u8, remaining[0..eq_pos]);
        const val_str = remaining[eq_pos + 1 ..];
        const value = try allocator.dupe(u8, val_str);
        try result.directives.append(allocator, Directive{ .set_environment = SetEnv{ .flags = .{ .global = global }, .name = name, .value = value } });
    } else if (std.mem.indexOfScalar(u8, remaining, ' ')) |sp_pos| {
        const name = try allocator.dupe(u8, remaining[0..sp_pos]);
        const val_str = std.mem.trim(u8, remaining[sp_pos + 1 ..], " \t");
        const value = try allocator.dupe(u8, val_str);
        try result.directives.append(allocator, Directive{ .set_environment = SetEnv{ .flags = .{ .global = global }, .name = name, .value = value } });
    } else {
        const name = try allocator.dupe(u8, remaining);
        try result.directives.append(allocator, Directive{ .set_environment = SetEnv{ .flags = .{ .global = global }, .name = name, .value = null } });
    }
}

fn parseIfShell(allocator: std.mem.Allocator, args: []const u8, result: *ParseResult) !void {
    // Format: "condition" "command"
    // Find two quoted strings
    const first_q = std.mem.indexOfScalar(u8, args, '"') orelse return error.MissingQuotes;
    const second_q = std.mem.indexOfScalarPos(u8, args, first_q + 1, '"') orelse return error.MissingQuotes;
    const condition = try allocator.dupe(u8, args[first_q + 1 .. second_q]);

    const rest = std.mem.trim(u8, args[second_q + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != '"') return error.MissingQuotes;
    const third_q = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.MissingQuotes;
    const command = try allocator.dupe(u8, rest[1..third_q]);

    try result.directives.append(allocator, Directive{ .if_shell = IfShell{ .condition = condition, .command = command } });
}

// ── Tests ──

test "parse empty config" {
    var result = try parseConfig(testing.allocator, "");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.directives.items.len);
}

test "parse comments" {
    var result = try parseConfig(testing.allocator, "# this is a comment\n  # indented comment");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.directives.items.len);
}

test "parse set flag option" {
    var result = try parseConfig(testing.allocator, "set -g mouse on");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .set);
    try testing.expect(d.set.flags.global);
    try testing.expectEqualStrings("mouse", d.set.option);
    try testing.expect(d.set.value == .flag);
    try testing.expect(d.set.value.flag);
}

test "parse set string option" {
    var result = try parseConfig(testing.allocator, "set -g default-shell \"/bin/zsh\"");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .set);
    try testing.expectEqualStrings("/bin/zsh", d.set.value.string);
}

test "parse set number option" {
    var result = try parseConfig(testing.allocator, "set -g status-interval 30");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d.set.value == .number);
    try testing.expectEqual(@as(i64, 30), d.set.value.number);
}

test "parse set flag off" {
    var result = try parseConfig(testing.allocator, "set -g mouse off");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d.set.value == .flag);
    try testing.expect(!d.set.value.flag);
}

test "inline comment stripped" {
    var result = try parseConfig(testing.allocator, "set -g mouse on # enable mouse");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d.set.value.flag);
}

test "multiple directives" {
    var result = try parseConfig(testing.allocator, "set -g mouse on\nset -g status off");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.directives.items.len);
}

test "set-environment directive" {
    var result = try parseConfig(testing.allocator, "set-environment -g FOO bar");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .set_environment);
    try testing.expect(d.set_environment.flags.global);
    try testing.expectEqualStrings("FOO", d.set_environment.name);
    try testing.expectEqualStrings("bar", d.set_environment.value.?);
}

test "set-environment without value unsets" {
    var result = try parseConfig(testing.allocator, "set-environment -g FOO");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .set_environment);
    try testing.expect(d.set_environment.value == null);
}

test "source-file directive" {
    var result = try parseConfig(testing.allocator, "source-file ~/.tmux/local.conf");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .source_file);
    try testing.expectEqualStrings("~/.tmux/local.conf", d.source_file);
}

test "parse unknown directive" {
    var result = try parseConfig(testing.allocator, "foobar 42");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.items.len);
}

test "if-shell directive" {
    var result = try parseConfig(testing.allocator, "if-shell \"test -f /tmp/x\" \"set -g mouse on\"");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.directives.items.len);
    const d = result.directives.items[0];
    try testing.expect(d == .if_shell);
    try testing.expectEqualStrings("test -f /tmp/x", d.if_shell.condition);
    try testing.expectEqualStrings("set -g mouse on", d.if_shell.command);
}
