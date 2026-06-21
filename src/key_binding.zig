const std = @import("std");
const testing = std.testing;
const key_mod = @import("key.zig");
const Key = key_mod.Key;
const Modifier = key_mod.Modifier;

pub const Error = error{OutOfMemory};

pub const Action = enum(u8) {
    new_window,
    split_horizontal,
    split_vertical,
    select_pane_left,
    select_pane_right,
    select_pane_up,
    select_pane_down,
    kill_pane,
    select_window_0,
    select_window_1,
    select_window_2,
    select_window_3,
    select_window_4,
    select_window_5,
    select_window_6,
    select_window_7,
    select_window_8,
    select_window_9,
    next_window,
    prev_window,
    copy_mode,
    paste_buffer,
    detach,
    clock_mode,
    last_window,
    resize_left,
    resize_right,
    resize_up,
    resize_down,
    swap_pane_up,
    swap_pane_down,
    rotate_window,
    rename_window,
    command_prompt,
};

pub const Binding = struct {
    key: Key,
    action: Action,
};

pub const KeyTable = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,

    pub fn init(allocator: std.mem.Allocator) KeyTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KeyTable) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn bind(self: *KeyTable, k: Key, action: Action) Error!void {
        for (self.bindings.items, 0..) |*b, i| {
            if (keysEqual(b.key, k)) {
                self.bindings.items[i].action = action;
                return;
            }
        }
        try self.bindings.append(self.allocator, .{ .key = k, .action = action });
    }

    pub fn unbind(self: *KeyTable, k: Key) void {
        for (self.bindings.items, 0..) |b, i| {
            if (keysEqual(b.key, k)) {
                _ = self.bindings.swapRemove(i);
                return;
            }
        }
    }

    pub fn lookup(self: *const KeyTable, k: Key) ?Action {
        for (self.bindings.items) |b| {
            if (keysEqual(b.key, k)) return b.action;
        }
        return null;
    }

    pub fn count(self: *const KeyTable) usize {
        return self.bindings.items.len;
    }
};

pub const PrefixState = enum(u8) {
    normal,
    prefix_seen,
};

pub const KeyDispatcher = struct {
    prefix: Key,
    prefix_state: PrefixState = .normal,
    root_table: KeyTable,
    prefix_table: KeyTable,

    pub fn init(allocator: std.mem.Allocator, prefix: Key) KeyDispatcher {
        return .{
            .prefix = prefix,
            .root_table = KeyTable.init(allocator),
            .prefix_table = KeyTable.init(allocator),
        };
    }

    pub fn deinit(self: *KeyDispatcher) void {
        self.root_table.deinit();
        self.prefix_table.deinit();
    }

    pub fn dispatch(self: *KeyDispatcher, k: Key) ?Action {
        switch (self.prefix_state) {
            .normal => {
                if (keysEqual(k, self.prefix)) {
                    self.prefix_state = .prefix_seen;
                    return null;
                }
                return self.root_table.lookup(k);
            },
            .prefix_seen => {
                self.prefix_state = .normal;
                return self.prefix_table.lookup(k);
            },
        }
    }

    pub fn reset(self: *KeyDispatcher) void {
        self.prefix_state = .normal;
    }
};

pub fn keysEqual(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    return switch (a) {
        .char => |ac| blk: {
            const bc = b.char;
            const ac_code = if (ac.mod.ctrl and ac.code <= 127) std.ascii.toLower(@as(u8, @intCast(ac.code))) else ac.code;
            const bc_code = if (bc.mod.ctrl and bc.code <= 127) std.ascii.toLower(@as(u8, @intCast(bc.code))) else bc.code;
            break :blk ac_code == bc_code and
                ac.mod.ctrl == bc.mod.ctrl and
                ac.mod.alt == bc.mod.alt and
                ac.mod.shift == bc.mod.shift;
        },
        .function => |af| blk: {
            const bf = b.function;
            break :blk af.key == bf.key and
                af.mod.ctrl == bf.mod.ctrl and
                af.mod.alt == bf.mod.alt and
                af.mod.shift == bf.mod.shift;
        },
        .arrow => |aa| blk: {
            const ba = b.arrow;
            break :blk aa.key == ba.key and
                aa.mod.ctrl == ba.mod.ctrl and
                aa.mod.alt == ba.mod.alt and
                aa.mod.shift == ba.mod.shift;
        },
        .special => |as| blk: {
            const bs = b.special;
            break :blk as.key == bs.key and
                as.mod.ctrl == bs.mod.ctrl and
                as.mod.alt == bs.mod.alt and
                as.mod.shift == bs.mod.shift;
        },
        .mouse => false,
    };
}

pub fn loadDefaults(table: *KeyTable) Error!void {
    const defaults = [_]Binding{
        .{ .key = Key{ .char = .{ .code = 'c', .mod = .{} } }, .action = .new_window },
        .{ .key = Key{ .char = .{ .code = '%', .mod = .{} } }, .action = .split_horizontal },
        .{ .key = Key{ .char = .{ .code = '"', .mod = .{} } }, .action = .split_vertical },
        .{ .key = Key{ .arrow = .{ .key = .left, .mod = .{} } }, .action = .select_pane_left },
        .{ .key = Key{ .arrow = .{ .key = .right, .mod = .{} } }, .action = .select_pane_right },
        .{ .key = Key{ .arrow = .{ .key = .up, .mod = .{} } }, .action = .select_pane_up },
        .{ .key = Key{ .arrow = .{ .key = .down, .mod = .{} } }, .action = .select_pane_down },
        .{ .key = Key{ .char = .{ .code = 'x', .mod = .{} } }, .action = .kill_pane },
        .{ .key = Key{ .char = .{ .code = '0', .mod = .{} } }, .action = .select_window_0 },
        .{ .key = Key{ .char = .{ .code = '1', .mod = .{} } }, .action = .select_window_1 },
        .{ .key = Key{ .char = .{ .code = '2', .mod = .{} } }, .action = .select_window_2 },
        .{ .key = Key{ .char = .{ .code = '3', .mod = .{} } }, .action = .select_window_3 },
        .{ .key = Key{ .char = .{ .code = '4', .mod = .{} } }, .action = .select_window_4 },
        .{ .key = Key{ .char = .{ .code = '5', .mod = .{} } }, .action = .select_window_5 },
        .{ .key = Key{ .char = .{ .code = '6', .mod = .{} } }, .action = .select_window_6 },
        .{ .key = Key{ .char = .{ .code = '7', .mod = .{} } }, .action = .select_window_7 },
        .{ .key = Key{ .char = .{ .code = '8', .mod = .{} } }, .action = .select_window_8 },
        .{ .key = Key{ .char = .{ .code = '9', .mod = .{} } }, .action = .select_window_9 },
        .{ .key = Key{ .char = .{ .code = 'n', .mod = .{} } }, .action = .next_window },
        .{ .key = Key{ .char = .{ .code = 'p', .mod = .{} } }, .action = .prev_window },
        .{ .key = Key{ .char = .{ .code = '[', .mod = .{} } }, .action = .copy_mode },
        .{ .key = Key{ .char = .{ .code = ']', .mod = .{} } }, .action = .paste_buffer },
        .{ .key = Key{ .char = .{ .code = 'd', .mod = .{} } }, .action = .detach },
        .{ .key = Key{ .char = .{ .code = 't', .mod = .{} } }, .action = .clock_mode },
        .{ .key = Key{ .char = .{ .code = 'l', .mod = .{} } }, .action = .last_window },
        .{ .key = Key{ .char = .{ .code = ',', .mod = .{} } }, .action = .rename_window },
        .{ .key = Key{ .char = .{ .code = ':', .mod = .{} } }, .action = .command_prompt },
        .{ .key = Key{ .char = .{ .code = 'o', .mod = .{} } }, .action = .rotate_window },
    };

    for (defaults) |b| {
        try table.bind(b.key, b.action);
    }
}

test "key table bind and lookup" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k = Key{ .char = .{ .code = 'c', .mod = .{} } };
    try table.bind(k, .new_window);

    try testing.expectEqual(Action.new_window, table.lookup(k).?);
}

test "key table lookup missing" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k = Key{ .char = .{ .code = 'z', .mod = .{} } };
    try testing.expect(table.lookup(k) == null);
}

test "key table rebind" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k = Key{ .char = .{ .code = 'c', .mod = .{} } };
    try table.bind(k, .new_window);
    try table.bind(k, .copy_mode);

    try testing.expectEqual(Action.copy_mode, table.lookup(k).?);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "key table unbind" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k = Key{ .char = .{ .code = 'c', .mod = .{} } };
    try table.bind(k, .new_window);
    table.unbind(k);

    try testing.expect(table.lookup(k) == null);
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "key table unbind missing is no-op" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k = Key{ .char = .{ .code = 'z', .mod = .{} } };
    table.unbind(k);
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "key table multiple bindings" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k1 = Key{ .char = .{ .code = 'c', .mod = .{} } };
    const k2 = Key{ .char = .{ .code = 'x', .mod = .{} } };
    try table.bind(k1, .new_window);
    try table.bind(k2, .kill_pane);

    try testing.expectEqual(@as(usize, 2), table.count());
    try testing.expectEqual(Action.new_window, table.lookup(k1).?);
    try testing.expectEqual(Action.kill_pane, table.lookup(k2).?);
}

test "key table different modifiers are different keys" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    const k1 = Key{ .char = .{ .code = 'a', .mod = .{} } };
    const k2 = Key{ .char = .{ .code = 'a', .mod = .{ .ctrl = true } } };
    try table.bind(k1, .new_window);
    try table.bind(k2, .copy_mode);

    try testing.expectEqual(@as(usize, 2), table.count());
    try testing.expectEqual(Action.new_window, table.lookup(k1).?);
    try testing.expectEqual(Action.copy_mode, table.lookup(k2).?);
}

test "load defaults" {
    var table = KeyTable.init(testing.allocator);
    defer table.deinit();

    try loadDefaults(&table);

    try testing.expect(table.count() > 20);
    try testing.expectEqual(Action.new_window, table.lookup(Key{ .char = .{ .code = 'c', .mod = .{} } }).?);
    try testing.expectEqual(Action.copy_mode, table.lookup(Key{ .char = .{ .code = '[', .mod = .{} } }).?);
    try testing.expectEqual(Action.detach, table.lookup(Key{ .char = .{ .code = 'd', .mod = .{} } }).?);
}

test "dispatcher normal mode prefix key" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    const result = disp.dispatch(prefix);
    try testing.expect(result == null);
    try testing.expectEqual(PrefixState.prefix_seen, disp.prefix_state);
}

test "dispatcher prefix then bound key" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    const k = Key{ .char = .{ .code = 'c', .mod = .{} } };
    try disp.prefix_table.bind(k, .new_window);

    _ = disp.dispatch(prefix);
    const result = disp.dispatch(k);
    try testing.expectEqual(Action.new_window, result.?);
    try testing.expectEqual(PrefixState.normal, disp.prefix_state);
}

test "dispatcher normal mode non-prefix key" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    const k = Key{ .char = .{ .code = 'x', .mod = .{} } };
    try disp.root_table.bind(k, .kill_pane);

    const result = disp.dispatch(k);
    try testing.expectEqual(Action.kill_pane, result.?);
}

test "dispatcher prefix then unbound key" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    const k = Key{ .char = .{ .code = 'z', .mod = .{} } };

    _ = disp.dispatch(prefix);
    const result = disp.dispatch(k);
    try testing.expect(result == null);
    try testing.expectEqual(PrefixState.normal, disp.prefix_state);
}

test "dispatcher reset" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    _ = disp.dispatch(prefix);
    try testing.expectEqual(PrefixState.prefix_seen, disp.prefix_state);

    disp.reset();
    try testing.expectEqual(PrefixState.normal, disp.prefix_state);
}

test "keys equal same char" {
    const a = Key{ .char = .{ .code = 'a', .mod = .{} } };
    const b = Key{ .char = .{ .code = 'a', .mod = .{} } };
    try testing.expect(keysEqual(a, b));
}

test "keys not equal different char" {
    const a = Key{ .char = .{ .code = 'a', .mod = .{} } };
    const b = Key{ .char = .{ .code = 'b', .mod = .{} } };
    try testing.expect(!keysEqual(a, b));
}

test "keys not equal different modifier" {
    const a = Key{ .char = .{ .code = 'a', .mod = .{} } };
    const b = Key{ .char = .{ .code = 'a', .mod = .{ .ctrl = true } } };
    try testing.expect(!keysEqual(a, b));
}

test "keys equal same arrow" {
    const a = Key{ .arrow = .{ .key = .up, .mod = .{} } };
    const b = Key{ .arrow = .{ .key = .up, .mod = .{} } };
    try testing.expect(keysEqual(a, b));
}

test "keys not equal different arrow" {
    const a = Key{ .arrow = .{ .key = .up, .mod = .{} } };
    const b = Key{ .arrow = .{ .key = .down, .mod = .{} } };
    try testing.expect(!keysEqual(a, b));
}

test "keys not equal different types" {
    const a = Key{ .char = .{ .code = 'a', .mod = .{} } };
    const b = Key{ .arrow = .{ .key = .up, .mod = .{} } };
    try testing.expect(!keysEqual(a, b));
}

test "keys equal same function" {
    const a = Key{ .function = .{ .key = .f1, .mod = .{} } };
    const b = Key{ .function = .{ .key = .f1, .mod = .{} } };
    try testing.expect(keysEqual(a, b));
}

test "keys equal same special" {
    const a = Key{ .special = .{ .key = .enter, .mod = .{} } };
    const b = Key{ .special = .{ .key = .enter, .mod = .{} } };
    try testing.expect(keysEqual(a, b));
}

test "dispatcher two prefixes in sequence" {
    const prefix = Key{ .char = .{ .code = 0x02, .mod = .{ .ctrl = true } } };
    var disp = KeyDispatcher.init(testing.allocator, prefix);
    defer disp.deinit();

    const k = Key{ .char = .{ .code = 'c', .mod = .{} } };
    try disp.prefix_table.bind(k, .new_window);

    _ = disp.dispatch(prefix);
    _ = disp.dispatch(k);

    _ = disp.dispatch(prefix);
    const result = disp.dispatch(k);
    try testing.expectEqual(Action.new_window, result.?);
}

pub fn mapCommandToAction(cmd: []const u8) ?Action {
    const trimmed = std.mem.trim(u8, cmd, " \t\"");
    if (std.mem.eql(u8, trimmed, "new-window") or std.mem.eql(u8, trimmed, "neww")) return .new_window;

    if (std.mem.startsWith(u8, trimmed, "split-window") or std.mem.startsWith(u8, trimmed, "splitw")) {
        if (std.mem.indexOf(u8, trimmed, " -h")) |idx| {
            const after = idx + 3;
            if (after >= trimmed.len or trimmed[after] == ' ') return .split_horizontal;
        }
        return .split_vertical;
    }

    if (std.mem.eql(u8, trimmed, "select-pane -L")) return .select_pane_left;
    if (std.mem.eql(u8, trimmed, "select-pane -R")) return .select_pane_right;
    if (std.mem.eql(u8, trimmed, "select-pane -U")) return .select_pane_up;
    if (std.mem.eql(u8, trimmed, "select-pane -D")) return .select_pane_down;

    if (std.mem.eql(u8, trimmed, "kill-pane") or std.mem.eql(u8, trimmed, "killp")) return .kill_pane;
    if (std.mem.eql(u8, trimmed, "next-window") or std.mem.eql(u8, trimmed, "next")) return .next_window;
    if (std.mem.eql(u8, trimmed, "previous-window") or std.mem.eql(u8, trimmed, "prev")) return .prev_window;
    if (std.mem.eql(u8, trimmed, "last-window") or std.mem.eql(u8, trimmed, "last")) return .last_window;
    if (std.mem.eql(u8, trimmed, "copy-mode")) return .copy_mode;
    if (std.mem.eql(u8, trimmed, "paste-buffer")) return .paste_buffer;
    if (std.mem.eql(u8, trimmed, "detach-client") or std.mem.eql(u8, trimmed, "detach")) return .detach;
    if (std.mem.eql(u8, trimmed, "clock-mode")) return .clock_mode;
    if (std.mem.eql(u8, trimmed, "rename-window")) return .rename_window;
    if (std.mem.eql(u8, trimmed, "command-prompt")) return .command_prompt;

    if (std.mem.startsWith(u8, trimmed, "select-window -t ") or std.mem.startsWith(u8, trimmed, "selectw -t ")) {
        const idx_str = trimmed[std.mem.lastIndexOfScalar(u8, trimmed, ' ').? + 1 ..];
        if (std.fmt.parseInt(u8, idx_str, 10)) |val| {
            if (val >= 0 and val <= 9) {
                return @enumFromInt(@intFromEnum(Action.select_window_0) + val);
            }
        } else |_| {}
    }
    return null;
}
