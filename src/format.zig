const std = @import("std");
const testing = std.testing;

pub const FormatError = error{
    OutOfMemory,
    InvalidFormat,
    UnterminatedBrace,
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

pub fn expand(allocator: std.mem.Allocator, template: []const u8, ctx: *const Context) FormatError![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '#') {
            if (i + 1 < template.len) {
                switch (template[i + 1]) {
                    '#' => {
                        try result.append(allocator, '#');
                        i += 2;
                        continue;
                    },
                    ',' => {
                        try result.append(allocator, ',');
                        i += 2;
                        continue;
                    },
                    '{' => {
                        const expanded = try expandBrace(allocator, template[i + 2 ..], ctx);
                        try result.appendSlice(allocator, expanded.value);
                        allocator.free(expanded.value);
                        i += 2 + expanded.consumed + 1;
                        continue;
                    },
                    else => {},
                }
            }
            try result.append(allocator, '#');
            i += 1;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

const ExpandResult = struct {
    value: []const u8,
    consumed: usize,
};

fn expandBrace(allocator: std.mem.Allocator, input: []const u8, ctx: *const Context) FormatError!ExpandResult {
    const close = findClosingBrace(input) orelse return error.UnterminatedBrace;
    const content = input[0..close];

    const value = try expandContent(allocator, content, ctx);
    return .{ .value = value, .consumed = close };
}

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
    if (content.len == 0) return try allocator.dupe(u8, "");

    if (content[0] == '?') {
        return try expandConditional(allocator, content[1..], ctx);
    }

    if (content[0] == 'l' and content.len > 1 and content[1] == ':') {
        return try expandLiteral(allocator, content[2..], ctx);
    }

    if (content[0] == '!' and content.len > 1 and content[1] == '!') {
        if (content.len > 2 and content[2] == ':') {
            return try expandDoubleNegation(allocator, content[3..], ctx);
        }
    }

    if (content[0] == '!' and content.len > 1 and content[1] == ':') {
        return try expandNot(allocator, content[2..], ctx);
    }

    if (content.len >= 2 and content[0] == '=' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        return try expandCompareEq(allocator, content[3..], ctx);
    }

    if (content.len >= 2 and content[0] == '!' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        return try expandCompareNeq(allocator, content[3..], ctx);
    }

    if (content.len >= 2 and content[0] == '<' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        return try expandCompareLe(allocator, content[3..], ctx);
    }

    if (content.len >= 2 and content[0] == '>' and content[1] == '=' and content.len > 2 and content[2] == ':') {
        return try expandCompareGe(allocator, content[3..], ctx);
    }

    if (content[0] == '<' and content.len > 1 and content[1] == ':') {
        return try expandCompareLt(allocator, content[2..], ctx);
    }

    if (content[0] == '>' and content.len > 1 and content[1] == ':') {
        return try expandCompareGt(allocator, content[2..], ctx);
    }

    if (content.len >= 2 and content[0] == '&' and content[1] == '&' and content.len > 2 and content[2] == ':') {
        return try expandAnd(allocator, content[3..], ctx);
    }

    if (content.len >= 2 and content[0] == '|' and content[1] == '|' and content.len > 2 and content[2] == ':') {
        return try expandOr(allocator, content[3..], ctx);
    }

    if (content[0] == 's' and content.len > 1 and content[1] == '/') {
        return try expandSubstitute(allocator, content[1..], ctx);
    }

    if (content[0] == '=' and content.len > 1 and (std.ascii.isDigit(content[1]) or content[1] == '-')) {
        return try expandTruncate(allocator, content[1..], ctx);
    }

    if (content[0] == 'n' and content.len == 1) {
        return try allocator.dupe(u8, "0");
    }

    return try expandVariable(allocator, content, ctx);
}

fn expandVariable(allocator: std.mem.Allocator, name: []const u8, ctx: *const Context) FormatError![]const u8 {
    if (ctx.get(name)) |value| {
        return try allocator.dupe(u8, value);
    }
    return try allocator.dupe(u8, "");
}

fn freeArgs(allocator: std.mem.Allocator, args: *std.ArrayListUnmanaged([]const u8)) void {
    for (args.items) |arg| allocator.free(arg);
    args.deinit(allocator);
}

fn expandConditional(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len == 0) return try allocator.dupe(u8, "");

    const cond_value = try expand(allocator, args.items[0], ctx);
    defer allocator.free(cond_value);
    const is_true = isTruthy(cond_value);

    if (args.items.len == 1) {
        if (is_true) return try allocator.dupe(u8, cond_value);
        return try allocator.dupe(u8, "");
    }

    if (args.items.len == 2) {
        if (is_true) return try expand(allocator, args.items[1], ctx);
        return try allocator.dupe(u8, "");
    }

    if (is_true) return try expand(allocator, args.items[1], ctx);
    return try expand(allocator, args.items[2], ctx);
}

fn expandLiteral(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    _ = ctx;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '#' and i + 1 < content.len) {
            switch (content[i + 1]) {
                '#' => {
                    try result.append(allocator, '#');
                    i += 2;
                    continue;
                },
                ',' => {
                    try result.append(allocator, ',');
                    i += 2;
                    continue;
                },
                '{' => {
                    try result.appendSlice(allocator, "#{");
                    i += 2;
                    continue;
                },
                '}' => {
                    try result.append(allocator, '}');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try result.append(allocator, content[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn expandDoubleNegation(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    const value = try expand(allocator, content, ctx);
    defer allocator.free(value);
    if (isTruthy(value)) return try allocator.dupe(u8, "1");
    return try allocator.dupe(u8, "0");
}

fn expandNot(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    const value = try expand(allocator, content, ctx);
    defer allocator.free(value);
    if (isTruthy(value)) return try allocator.dupe(u8, "0");
    return try allocator.dupe(u8, "1");
}

fn expandCompareEq(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .eq);
}

fn expandCompareNeq(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .neq);
}

fn expandCompareLt(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .lt);
}

fn expandCompareGt(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .gt);
}

fn expandCompareLe(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .le);
}

fn expandCompareGe(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    return try expandCompareBinary(allocator, content, ctx, .ge);
}

const CompareOp = enum { eq, neq, lt, gt, le, ge };

fn expandCompareBinary(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context, op: CompareOp) FormatError![]const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len < 2) return try allocator.dupe(u8, "0");

    const left = try expand(allocator, args.items[0], ctx);
    defer allocator.free(left);
    const right = try expand(allocator, args.items[1], ctx);
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

    return try allocator.dupe(u8, if (result) "1" else "0");
}

fn expandAnd(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len == 0) return try allocator.dupe(u8, "0");

    for (args.items) |arg| {
        const value = try expand(allocator, arg, ctx);
        defer allocator.free(value);
        if (!isTruthy(value)) return try allocator.dupe(u8, "0");
    }
    return try allocator.dupe(u8, "1");
}

fn expandOr(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArgs(allocator, &args);

    try splitArgs(allocator, content, &args);

    if (args.items.len == 0) return try allocator.dupe(u8, "0");

    for (args.items) |arg| {
        const value = try expand(allocator, arg, ctx);
        defer allocator.free(value);
        if (isTruthy(value)) return try allocator.dupe(u8, "1");
    }
    return try allocator.dupe(u8, "0");
}

fn expandSubstitute(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    if (content.len < 2) return try allocator.dupe(u8, "");

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

    if (part_count < 2) return try allocator.dupe(u8, "");

    const pattern = content[1..parts[0]];
    const replacement = content[parts[0] + 1 .. parts[1]];
    const var_name_start = parts[1] + 1;
    var var_name = if (part_count >= 3) content[var_name_start..parts[2]] else content[var_name_start..];
    if (var_name.len > 0 and var_name[0] == ':') var_name = var_name[1..];

    const expanded_name = try expand(allocator, var_name, ctx);
    defer allocator.free(expanded_name);

    const value = if (ctx.get(expanded_name)) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, expanded_name);
    defer allocator.free(value);

    return try std.mem.replaceOwned(u8, allocator, value, pattern, replacement);
}

fn expandTruncate(allocator: std.mem.Allocator, content: []const u8, ctx: *const Context) FormatError![]const u8 {
    var i: usize = 0;
    var negative = false;

    if (i < content.len and content[i] == '-') {
        negative = true;
        i += 1;
    }

    var n: usize = 0;
    while (i < content.len and std.ascii.isDigit(content[i])) {
        n = n * 10 + (content[i] - '0');
        i += 1;
    }

    if (i >= content.len or content[i] != ':') return try allocator.dupe(u8, "");

    const var_content = content[i + 1 ..];
    const expanded = try expand(allocator, var_content, ctx);
    defer allocator.free(expanded);

    const value = if (ctx.get(expanded)) |v| v else expanded;

    if (n == 0) return try allocator.dupe(u8, "");

    if (negative) {
        if (value.len <= n) return try allocator.dupe(u8, value);
        return try allocator.dupe(u8, value[value.len - n ..]);
    }

    if (value.len <= n) return try allocator.dupe(u8, value);
    return try allocator.dupe(u8, value[0..n]);
}

fn splitArgs(allocator: std.mem.Allocator, content: []const u8, args: *std.ArrayListUnmanaged([]const u8)) FormatError!void {
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
            const arg = try allocator.dupe(u8, content[start..i]);
            try args.append(allocator, arg);
            start = i + 1;
        }
        i += 1;
    }

    if (start <= content.len) {
        const arg = try allocator.dupe(u8, content[start..]);
        try args.append(allocator, arg);
    }
}

fn isTruthy(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

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

test "conditional in conditional" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.set("a", "1");
    try ctx.set("b", "1");

    const result = try expand(testing.allocator, "#{?a,#{?b,both},none}", &ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("both", result);
}
