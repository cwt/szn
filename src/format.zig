const std = @import("std");
const testing = std.testing;
const colour_mod = @import("colour.zig");

pub const FormatError = error{
    OutOfMemory,
    InvalidFormat,
    UnterminatedBrace,
};

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(timep: ?*const i64, result: *Tm) ?*Tm;
extern "c" fn strftime(buf: [*]u8, maxsize: usize, fmt: [*:0]const u8, tm: *const Tm) usize;

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

pub const Context = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .map = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *Context) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.map.allocator.free(entry.key_ptr.*);
            self.map.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn set(self: *Context, key: []const u8, value: []const u8) !void {
        if (self.map.getEntry(key)) |entry| {
            const new_value = try self.map.allocator.dupe(u8, value);
            self.map.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = new_value;
            return;
        }
        const k = try self.map.allocator.dupe(u8, key);
        errdefer self.map.allocator.free(k);
        const v = try self.map.allocator.dupe(u8, value);
        errdefer self.map.allocator.free(v);
        try self.map.put(k, v);
    }

    pub fn get(self: *const Context, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

/// Compiled template op. Slices point into the original template string.
pub const Op = union(enum) {
    literal: []const u8,
    brace: []const u8,
    style: []const u8,
    alias: u8,
};

/// Cache of compiled ops for a stable template string (e.g. an option value).
pub const TemplateCache = struct {
    source_ptr: ?[*]const u8 = null,
    source_len: usize = 0,
    ops: std.ArrayList(Op) = .empty,

    pub fn deinit(self: *TemplateCache, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.* = .{};
    }

    pub fn getOrCompile(self: *TemplateCache, allocator: std.mem.Allocator, template: []const u8) FormatError![]const Op {
        if (self.source_ptr) |ptr| {
            if (self.source_len == template.len and ptr == template.ptr and self.ops.items.len > 0) {
                return self.ops.items;
            }
        }
        self.ops.clearRetainingCapacity();
        try compileInto(allocator, template, &self.ops);
        self.source_ptr = template.ptr;
        self.source_len = template.len;
        return self.ops.items;
    }
};

fn compileInto(allocator: std.mem.Allocator, template: []const u8, ops: *std.ArrayList(Op)) FormatError!void {
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < template.len) {
        if (template[i] != '#') {
            i += 1;
            continue;
        }
        if (i > lit_start) {
            try ops.append(allocator, .{ .literal = template[lit_start..i] });
        }
        if (i + 1 >= template.len) {
            try ops.append(allocator, .{ .literal = template[i .. i + 1] });
            i += 1;
            lit_start = i;
            continue;
        }
        switch (template[i + 1]) {
            '#' => {
                try ops.append(allocator, .{ .literal = "#" });
                i += 2;
                lit_start = i;
            },
            ',' => {
                try ops.append(allocator, .{ .literal = "," });
                i += 2;
                lit_start = i;
            },
            '{' => {
                const rest = template[i + 2 ..];
                const close = findClosingBrace(rest) orelse return error.UnterminatedBrace;
                try ops.append(allocator, .{ .brace = rest[0..close] });
                i += 2 + close + 1;
                lit_start = i;
            },
            '[' => {
                const rest = template[i + 2 ..];
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidFormat;
                try ops.append(allocator, .{ .style = rest[0..close] });
                i += 2 + close + 1;
                lit_start = i;
            },
            else => {
                const ch = template[i + 1];
                if (aliasName(ch) != null) {
                    try ops.append(allocator, .{ .alias = ch });
                    i += 2;
                    lit_start = i;
                } else {
                    try ops.append(allocator, .{ .literal = template[i .. i + 1] });
                    i += 1;
                    lit_start = i;
                }
            },
        }
    }
    if (lit_start < template.len) {
        try ops.append(allocator, .{ .literal = template[lit_start..] });
    }
}

fn aliasName(ch: u8) ?[]const u8 {
    return switch (ch) {
        'S' => "session_name",
        'I' => "window_index",
        'W' => "window_name",
        'P' => "pane_index",
        'T' => "pane_title",
        'H' => "host",
        'h' => "host_short",
        'F' => "window_flags",
        'D' => "pane_id",
        else => null,
    };
}

pub fn expand(allocator: std.mem.Allocator, template: []const u8, ctx: *const Context) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try expandInto(allocator, &result, template, ctx, true);
    return try result.toOwnedSlice(allocator);
}

/// Expand using a pre-compiled op list (from TemplateCache).
pub fn expandOps(allocator: std.mem.Allocator, ops: []const Op, ctx: *const Context) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try expandOpsInto(allocator, &result, ops, ctx, true);
    return try result.toOwnedSlice(allocator);
}

fn expandInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    template: []const u8,
    ctx: *const Context,
    do_strftime: bool,
) FormatError!void {
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(allocator);
    try compileInto(allocator, template, &ops);
    try expandOpsInto(allocator, out, ops.items, ctx, do_strftime);
}

fn expandOpsInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ops: []const Op,
    ctx: *const Context,
    do_strftime: bool,
) FormatError!void {
    for (ops) |op| {
        switch (op) {
            .literal => |lit| {
                if (do_strftime) {
                    try appendWithStrftime(allocator, out, lit);
                } else {
                    try out.appendSlice(allocator, lit);
                }
            },
            .brace => |content| {
                try expandContentInto(allocator, out, content, ctx);
            },
            .style => |content| {
                try expandStyleInto(allocator, out, content);
            },
            .alias => |ch| {
                if (aliasName(ch)) |name| {
                    try appendVariable(allocator, out, name, ctx);
                }
            },
        }
    }
}

fn appendVariable(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, ctx: *const Context) FormatError!void {
    if (ctx.get(name)) |value| {
        try out.appendSlice(allocator, value);
    }
}

fn appendWithStrftime(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) FormatError!void {
    var i: usize = 0;
    var tm_cache: ?Tm = null;
    while (i < text.len) {
        if (text[i] == '%' and i + 1 < text.len) {
            if (text[i + 1] == '%') {
                try out.append(allocator, '%');
                i += 2;
                continue;
            }
            var fmt_buf: [4]u8 = undefined;
            fmt_buf[0] = '%';
            fmt_buf[1] = text[i + 1];
            fmt_buf[2] = 0;
            if (tm_cache == null) {
                const now = time(null);
                var tm: Tm = undefined;
                if (localtime_r(&now, &tm) != null) {
                    tm_cache = tm;
                } else {
                    tm_cache = std.mem.zeroes(Tm);
                }
            }
            var result_buf: [64]u8 = undefined;
            const n = strftime(&result_buf, result_buf.len, @ptrCast(&fmt_buf), &tm_cache.?);
            if (n > 0) {
                try out.appendSlice(allocator, result_buf[0..n]);
                i += 2;
                continue;
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
}

fn expandStyleInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8) FormatError!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i < content.len and content[i] != ',') continue;
        const part = std.mem.trim(u8, content[start..i], " \t");
        start = i + 1;
        if (part.len == 0) continue;
        try applyStyleAttr(allocator, out, part);
    }
}

fn applyStyleAttr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attr: []const u8) FormatError!void {
    if (std.mem.eql(u8, attr, "default")) {
        try out.appendSlice(allocator, "\x1b[m");
        return;
    }
    if (std.mem.eql(u8, attr, "bold") or std.mem.eql(u8, attr, "bright")) {
        try out.appendSlice(allocator, "\x1b[1m");
        return;
    }
    if (std.mem.eql(u8, attr, "nobold") or std.mem.eql(u8, attr, "nobright")) {
        try out.appendSlice(allocator, "\x1b[22m");
        return;
    }
    if (std.mem.eql(u8, attr, "dim")) {
        try out.appendSlice(allocator, "\x1b[2m");
        return;
    }
    if (std.mem.eql(u8, attr, "nodim")) {
        try out.appendSlice(allocator, "\x1b[22m");
        return;
    }
    if (std.mem.eql(u8, attr, "italics") or std.mem.eql(u8, attr, "italic")) {
        try out.appendSlice(allocator, "\x1b[3m");
        return;
    }
    if (std.mem.eql(u8, attr, "noitalics") or std.mem.eql(u8, attr, "noitalic")) {
        try out.appendSlice(allocator, "\x1b[23m");
        return;
    }
    if (std.mem.eql(u8, attr, "underscore") or std.mem.eql(u8, attr, "underline")) {
        try out.appendSlice(allocator, "\x1b[4m");
        return;
    }
    if (std.mem.eql(u8, attr, "nounderscore") or std.mem.eql(u8, attr, "nounderline")) {
        try out.appendSlice(allocator, "\x1b[24m");
        return;
    }
    if (std.mem.eql(u8, attr, "reverse")) {
        try out.appendSlice(allocator, "\x1b[7m");
        return;
    }
    if (std.mem.eql(u8, attr, "noreverse")) {
        try out.appendSlice(allocator, "\x1b[27m");
        return;
    }
    if (std.mem.eql(u8, attr, "hidden")) {
        try out.appendSlice(allocator, "\x1b[8m");
        return;
    }
    if (std.mem.eql(u8, attr, "nohidden")) {
        try out.appendSlice(allocator, "\x1b[28m");
        return;
    }
    if (std.mem.startsWith(u8, attr, "fg=")) {
        try appendColourSgr(allocator, out, attr[3..], true);
        return;
    }
    if (std.mem.startsWith(u8, attr, "bg=")) {
        try appendColourSgr(allocator, out, attr[3..], false);
        return;
    }
}

fn appendColourSgr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, is_fg: bool) FormatError!void {
    const col = colour_mod.parse(name) catch return;
    var buf: [32]u8 = undefined;
    const s = switch (col.tag) {
        .default_, .terminal => if (is_fg) "\x1b[39m" else "\x1b[49m",
        .indexed => blk: {
            const base: u8 = if (is_fg) 38 else 48;
            break :blk std.fmt.bufPrint(&buf, "\x1b[{d};5;{d}m", .{ base, @as(u8, @truncate(col.value)) }) catch return;
        },
        .rgb => blk: {
            const rgb = col.toRgb().?;
            const base: u8 = if (is_fg) 38 else 48;
            break :blk std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ base, rgb[0], rgb[1], rgb[2] }) catch return;
        },
    };
    try out.appendSlice(allocator, s);
}

const ExpandResult = struct {
    value: []const u8,
    consumed: usize,
};

fn findClosingBrace(input: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '#') {
            if (i + 1 < input.len and input[i + 1] == '{') {
                depth += 1;
                i += 2;
                continue;
            }
            if (i + 1 < input.len and input[i + 1] == '#') {
                i += 2;
                continue;
            }
        }
        if (input[i] == '}') {
            if (depth == 0) return i;
            depth -= 1;
        }
        i += 1;
    }
    return null;
}

fn expandContent(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try expandContentInto(allocator, &result, content, ctx);
    return try result.toOwnedSlice(allocator);
}

fn expandContentInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context) FormatError!void {
    if (content.len == 0) return;

    if (content[0] == '?') {
        try expandConditionalInto(allocator, out, content[1..], ctx);
        return;
    }

    if (content[0] == 'l' and content.len > 1 and content[1] == ':') {
        try expandLiteralInto(allocator, out, content[2..]);
        return;
    }

    if (content[0] == '!' and content.len > 1 and content[1] == '!') {
        if (content.len > 2 and content[2] == ':') {
            try expandBoolInto(allocator, out, content[3..], ctx, true);
            return;
        }
    }

    if (content[0] == '!' and content.len > 1 and content[1] == ':') {
        try expandBoolInto(allocator, out, content[2..], ctx, false);
        return;
    }

    if (content.len >= 2 and content[0] == '=' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        try expandCompareBinaryInto(allocator, out, content[3..], ctx, .eq);
        return;
    }

    if (content.len >= 2 and content[0] == '!' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        try expandCompareBinaryInto(allocator, out, content[3..], ctx, .neq);
        return;
    }

    if (content.len >= 2 and content[0] == '<' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        try expandCompareBinaryInto(allocator, out, content[3..], ctx, .le);
        return;
    }

    if (content.len >= 2 and content[0] == '>' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        try expandCompareBinaryInto(allocator, out, content[3..], ctx, .ge);
        return;
    }

    if (content[0] == '<' and content.len > 1 and content[1] == ':') {
        try expandCompareBinaryInto(allocator, out, content[2..], ctx, .lt);
        return;
    }

    if (content[0] == '>' and content.len > 1 and content[1] == ':') {
        try expandCompareBinaryInto(allocator, out, content[2..], ctx, .gt);
        return;
    }

    if (content.len >= 2 and content[0] == '&' and content[1] == '&' and content.len > 2 and content[2] == ':') {
        try expandAndOrInto(allocator, out, content[3..], ctx, true);
        return;
    }

    if (content.len >= 2 and content[0] == '|' and content[1] == '|' and content.len > 2 and content[2] == ':') {
        try expandAndOrInto(allocator, out, content[3..], ctx, false);
        return;
    }

    if (content[0] == 's' and content.len > 1 and content[1] == '/') {
        try expandSubstituteInto(allocator, out, content[1..], ctx);
        return;
    }

    if (content[0] == '=' and content.len > 1 and (std.ascii.isDigit(content[1]) or content[1] == '-')) {
        try expandTruncateInto(allocator, out, content[1..], ctx);
        return;
    }

    if (content[0] == 'n' and content.len == 1) {
        try out.append(allocator, '0');
        return;
    }

    try appendVariable(allocator, out, content, ctx);
}

/// Scratch buffer for intermediate expansions that need a temporary owned string.
fn expandTemp(allocator: std.mem.Allocator, template: []const u8, ctx: *const Context) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    // Nested expansions should not re-apply strftime on already-expanded text.
    try expandInto(allocator, &result, template, ctx, false);
    return try result.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: *std.ArrayList([]const u8)) void {
    // Args are slices into the original input — do not free individual items.
    args.deinit(allocator);
}

fn splitArgs(allocator: std.mem.Allocator, content: []const u8, args: *std.ArrayList([]const u8)) FormatError!void {
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        if (content[i] == '#' and i + 1 < content.len and content[i + 1] == '{') {
            depth += 1;
            i += 2;
            continue;
        }
        if (content[i] == '}') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (content[i] == ',' and depth == 0) {
            try args.append(allocator, content[start..i]);
            start = i + 1;
        }
        i += 1;
    }

    if (start < content.len) {
        try args.append(allocator, content[start..]);
    } else if (start == content.len and content.len > 0 and content[content.len - 1] == ',') {
        try args.append(allocator, "");
    }
}

fn expandConditionalInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context) FormatError!void {
    var args: std.ArrayList([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len == 0) return;

    const cond_value = try expandTemp(allocator, args.items[0], ctx);
    defer allocator.free(cond_value);
    const is_true = isTruthy(cond_value);

    if (args.items.len == 1) {
        if (is_true) try out.appendSlice(allocator, cond_value);
        return;
    }

    if (args.items.len == 2) {
        if (is_true) try expandInto(allocator, out, args.items[1], ctx, false);
        return;
    }

    if (is_true) {
        try expandInto(allocator, out, args.items[1], ctx, false);
    } else {
        try expandInto(allocator, out, args.items[2], ctx, false);
    }
}

fn expandLiteralInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8) FormatError!void {
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '#' and i + 1 < content.len) {
            switch (content[i + 1]) {
                '#' => {
                    try out.append(allocator, '#');
                    i += 2;
                    continue;
                },
                ',' => {
                    try out.append(allocator, ',');
                    i += 2;
                    continue;
                },
                '{' => {
                    try out.appendSlice(allocator, "#{");
                    i += 2;
                    continue;
                },
                '}' => {
                    try out.append(allocator, '}');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, content[i]);
        i += 1;
    }
}

fn expandBoolInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context, double_neg: bool) FormatError!void {
    const value = try expandTemp(allocator, content, ctx);
    defer allocator.free(value);
    const truthy = isTruthy(value);
    const result = if (double_neg) truthy else !truthy;
    try out.append(allocator, if (result) '1' else '0');
}

const CompareOp = enum { eq, neq, lt, gt, le, ge };

fn expandCompareBinaryInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context, op: CompareOp) FormatError!void {
    var args: std.ArrayList([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len < 2) {
        try out.append(allocator, '0');
        return;
    }

    const left = try expandTemp(allocator, args.items[0], ctx);
    defer allocator.free(left);
    const right = try expandTemp(allocator, args.items[1], ctx);
    defer allocator.free(right);

    const cmp = std.mem.order(u8, left, right);
    const result = switch (op) {
        .eq => cmp == .eq,
        .neq => cmp != .eq,
        .lt => cmp == .lt,
        .gt => cmp == .gt,
        .le => cmp != .gt,
        .ge => cmp != .lt,
    };

    try out.append(allocator, if (result) '1' else '0');
}

fn expandAndOrInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context, is_and: bool) FormatError!void {
    var args: std.ArrayList([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len == 0) {
        try out.append(allocator, '0');
        return;
    }

    for (args.items) |arg| {
        const value = try expandTemp(allocator, arg, ctx);
        defer allocator.free(value);
        if (is_and) {
            if (!isTruthy(value)) {
                try out.append(allocator, '0');
                return;
            }
        } else {
            if (isTruthy(value)) {
                try out.append(allocator, '1');
                return;
            }
        }
    }
    try out.append(allocator, if (is_and) '1' else '0');
}

fn expandSubstituteInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context) FormatError!void {
    if (content.len < 2) return;

    const delim = content[0];
    var parts: [3]usize = .{ 0, 0, 0 };
    var part_count: usize = 0;
    var i: usize = 1;

    while (i < content.len and part_count < 3) {
        if (content[i] == delim) {
            parts[part_count] = i;
            part_count += 1;
            if (part_count >= 3) break;
        }
        i += 1;
    }

    if (part_count < 2) return;

    const pattern = content[1..parts[0]];
    const replacement = content[parts[0] + 1 .. parts[1]];
    const var_name_start = parts[1] + 1;
    var var_name = if (part_count >= 3) content[var_name_start..parts[2]] else content[var_name_start..];
    if (var_name.len > 0 and var_name[0] == ':') var_name = var_name[1..];

    const expanded_name = try expandTemp(allocator, var_name, ctx);
    defer allocator.free(expanded_name);

    const value_src = if (ctx.get(expanded_name)) |v| v else expanded_name;
    const replaced = try std.mem.replaceOwned(u8, allocator, value_src, pattern, replacement);
    defer allocator.free(replaced);
    try out.appendSlice(allocator, replaced);
}

fn expandTruncateInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8, ctx: *const Context) FormatError!void {
    var i: usize = 0;
    var negative = false;

    if (i < content.len and content[i] == '-') {
        negative = true;
        i += 1;
    }

    var n: usize = 0;
    while (i < content.len and std.ascii.isDigit(content[i])) {
        n = n *% 10 +% (content[i] - '0');
        i += 1;
    }

    if (i >= content.len or content[i] != ':') return;

    const var_content = content[i + 1 ..];
    const expanded = try expandTemp(allocator, var_content, ctx);
    defer allocator.free(expanded);

    const value = if (ctx.get(expanded)) |v| v else expanded;

    if (n == 0) return;

    if (negative) {
        if (value.len <= n) {
            try out.appendSlice(allocator, value);
        } else {
            try out.appendSlice(allocator, value[value.len - n ..]);
        }
        return;
    }

    if (value.len <= n) {
        try out.appendSlice(allocator, value);
    } else {
        try out.appendSlice(allocator, value[0..n]);
    }
}

fn isTruthy(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "expand plain text" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "hello world", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "expand variable" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("name", "szn");

    const result = try expand(testing.allocator, "hello #{name}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello szn", result);
}

test "expand missing variable returns empty" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "hello #{missing}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello ", result);
}

test "expand multiple variables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "foo");
    try ctx.set("b", "bar");

    const result = try expand(testing.allocator, "#{a}-#{b}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo-bar", result);
}

test "expand escaped hash" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "a##b", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a#b", result);
}

test "expand escaped comma" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "a#,b", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a,b", result);
}

test "conditional true" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("active", "1");

    const result = try expand(testing.allocator, "#{?active,yes,no}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("yes", result);
}

test "conditional false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("active", "0");

    const result = try expand(testing.allocator, "#{?#{active},yes,no}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("no", result);
}

test "conditional empty is false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("active", "");

    const result = try expand(testing.allocator, "#{?#{active},yes,no}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("no", result);
}

test "conditional missing variable is false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{?#{missing},yes,no}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("no", result);
}

test "conditional with nested expansion" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("flag", "1");
    try ctx.set("name", "test");

    const result = try expand(testing.allocator, "#{?flag,#{name},none}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("test", result);
}

test "conditional two args true returns value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("x", "hello");

    const result = try expand(testing.allocator, "#{?x,found}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("found", result);
}

test "conditional two args false returns empty" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("x", "0");

    const result = try expand(testing.allocator, "#{?#{x},found}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "conditional single arg truthy returns value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("x", "hello");

    const result = try expand(testing.allocator, "#{?#{x}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "compare equal true" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "hello");

    const result = try expand(testing.allocator, "#{==:#{a},hello}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "compare equal false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "hello");

    const result = try expand(testing.allocator, "#{==:#{a},world}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "compare not equal" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "hello");

    const result = try expand(testing.allocator, "#{!=:#{a},world}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "compare less than" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{<:abc,def}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "compare greater than" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{>:def,abc}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "compare less or equal" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const r1 = try expand(testing.allocator, "#{<=:abc,abc}", &ctx);
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("1", r1);

    const r2 = try expand(testing.allocator, "#{<=:abc,def}", &ctx);
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("1", r2);
}

test "compare greater or equal" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const r1 = try expand(testing.allocator, "#{>=:abc,abc}", &ctx);
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("1", r1);

    const r2 = try expand(testing.allocator, "#{>=:def,abc}", &ctx);
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("1", r2);
}

test "logical and both true" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");
    try ctx.set("b", "1");

    const result = try expand(testing.allocator, "#{&&:#{a},#{b}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "logical and one false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");
    try ctx.set("b", "0");

    const result = try expand(testing.allocator, "#{&&:#{a},#{b}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "logical or one true" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "0");
    try ctx.set("b", "1");

    const result = try expand(testing.allocator, "#{||:#{a},#{b}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "logical or both false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "0");
    try ctx.set("b", "0");

    const result = try expand(testing.allocator, "#{||:#{a},#{b}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "logical not true" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");

    const result = try expand(testing.allocator, "#{!:#{a}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "logical not false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "0");

    const result = try expand(testing.allocator, "#{!:#{a}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "double negation truthy" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "hello");

    const result = try expand(testing.allocator, "#{!!:#{a}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "double negation falsy" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{!!:#{missing}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "literal passthrough" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{l:#{name}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("#{name}", result);
}

test "literal escapes" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "#{l:##{}test}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("#{test}", result);
}

test "substitute simple" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("path", "foo:bar:baz");

    const result = try expand(testing.allocator, "#{s/:/_/:path}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo_bar_baz", result);
}

test "substitute no match" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("path", "hello");

    const result = try expand(testing.allocator, "#{s/x/y/:path}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "truncate positive" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("name", "hello world");

    const result = try expand(testing.allocator, "#{=5:name}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "truncate negative (from end)" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("name", "hello world");

    const result = try expand(testing.allocator, "#{=-5:name}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("world", result);
}

test "truncate shorter than value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("name", "hi");

    const result = try expand(testing.allocator, "#{=10:name}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hi", result);
}

test "nested conditionals" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");
    try ctx.set("b", "0");

    const result = try expand(testing.allocator, "#{?#{a},#{?#{b},both,only-a},none}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("only-a", result);
}

test "conditional with compare" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "main");

    const result = try expand(testing.allocator, "#{?#{==:#{session_name},main},yes,no}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("yes", result);
}

test "empty template" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "hash at end of string" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "test#", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("test#", result);
}

test "unterminated brace" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try testing.expectError(error.UnterminatedBrace, expand(testing.allocator, "#{unclosed", &ctx));
}

test "context set and get" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.set("key", "value");
    try testing.expectEqualStrings("value", ctx.get("key").?);
}

test "context overwrite" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.set("key", "old");
    try ctx.set("key", "new");
    try testing.expectEqualStrings("new", ctx.get("key").?);
}

test "context missing key" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.get("missing") == null);
}

test "and with three args" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");
    try ctx.set("b", "1");
    try ctx.set("c", "1");

    const result = try expand(testing.allocator, "#{&&:#{a},#{b},#{c}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "or with three args all false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "0");
    try ctx.set("b", "0");
    try ctx.set("c", "0");

    const result = try expand(testing.allocator, "#{||:#{a},#{b},#{c}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0", result);
}

test "complex status line" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "dev");
    try ctx.set("window_index", "0");
    try ctx.set("window_name", "editor");
    try ctx.set("window_active", "1");

    const result = try expand(testing.allocator, "[#{session_name}] #{window_index}:#{window_name}#{?window_active,*,}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[dev] 0:editor*", result);
}

test "compare with nested variables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("x", "abc");
    try ctx.set("y", "abc");

    const result = try expand(testing.allocator, "#{==:#{x},#{y}}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("1", result);
}

test "single-char aliases" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "dev");
    try ctx.set("window_index", "2");
    try ctx.set("window_name", "vim");
    try ctx.set("window_flags", "*");

    const result = try expand(testing.allocator, "[#S] #I:#W#F", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[dev] 2:vim*", result);
}

test "style sequence fg" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("window_name", "x");

    const result = try expand(testing.allocator, "#[fg=red]#W#[default]", &ctx);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x") != null);
}

test "template cache reuses ops" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("session_name", "a");

    const tmpl = "[#S]";
    var cache: TemplateCache = .{};
    defer cache.deinit(testing.allocator);

    const ops1 = try cache.getOrCompile(testing.allocator, tmpl);
    const ops2 = try cache.getOrCompile(testing.allocator, tmpl);
    try testing.expect(ops1.ptr == ops2.ptr);

    const r = try expandOps(testing.allocator, ops1, &ctx);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[a]", r);
}

test "strftime hour minute present" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try expand(testing.allocator, "%H:%M", &ctx);
    defer testing.allocator.free(result);
    try testing.expect(result.len >= 4);
    try testing.expect(result[2] == ':');
}
