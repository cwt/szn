const std = @import("std");
const testing = std.testing;
const window = @import("window.zig");
const Pane = window.Pane;

pub const LayoutError = error{
    OutOfMemory,
    PaneNotFound,
};

pub const SplitDir = enum(u8) {
    horizontal,
    vertical,
};

pub const Node = union(enum) {
    leaf: *Pane,
    split: *Split,
};

pub const Split = struct {
    direction: SplitDir,
    proportion: f64,
    a: *Node,
    b: *Node,
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    root: *Node,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, pane: *Pane, width: u32, height: u32) LayoutError!Layout {
        const node = try allocator.create(Node);
        node.* = Node{ .leaf = pane };
        return Layout{
            .allocator = allocator,
            .root = node,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Layout) void {
        self.deinitNode(self.root);
        self.allocator.destroy(self.root);
    }

    fn deinitNode(self: *Layout, node: *Node) void {
        switch (node.*) {
            .leaf => |pane| {
                pane.deinit();
                self.allocator.destroy(pane);
            },
            .split => |s| {
                self.deinitNode(s.a);
                self.deinitNode(s.b);
                self.allocator.destroy(s.a);
                self.allocator.destroy(s.b);
                self.allocator.destroy(s);
            },
        }
    }

    pub fn splitPane(self: *Layout, allocator: std.mem.Allocator, pane: *Pane, direction: SplitDir, proportion: f64) window.Error!*Pane {
        const leaf_node = self.findLeafParent(self.root, pane) orelse return error.PaneNotFound;

        const child_w, const child_h = self.calculateChildSize(direction, proportion);
        const new_pane = try allocator.create(Pane);
        new_pane.* = try Pane.init(allocator, 0, child_w, child_h);

        const split = try allocator.create(Split);
        const a_node = try allocator.create(Node);
        const b_node = try allocator.create(Node);

        a_node.* = Node{ .leaf = leaf_node.leaf };
        b_node.* = Node{ .leaf = new_pane };
        split.* = Split{
            .direction = direction,
            .proportion = proportion,
            .a = a_node,
            .b = b_node,
        };

        leaf_node.* = Node{ .split = split };
        return new_pane;
    }

    pub fn findLeafParent(self: *Layout, node: *Node, target: *Pane) ?*Node {
        switch (node.*) {
            .leaf => |p| {
                if (p == target) return node;
                return null;
            },
            .split => |s| {
                if (self.findLeafParent(s.a, target)) |found| return found;
                if (self.findLeafParent(s.b, target)) |found| return found;
                return null;
            },
        }
    }

    pub fn removePane(self: *Layout, pane: *Pane) void {
        if (self.root.* == .leaf) return;
        _ = self.removeFromNode(self.root, null, pane);
    }

    pub fn extractPane(self: *Layout, pane: *Pane) void {
        if (self.root.* == .leaf) return;
        _ = self.extractFromNode(self.root, null, pane);
    }

    fn extractFromNode(self: *Layout, node: *Node, parent_split: ?*Split, target: *Pane) bool {
        switch (node.*) {
            .leaf => |p| {
                if (p == target and parent_split != null) return true;
                return false;
            },
            .split => |s| {
                if (self.extractFromNode(s.a, s, target)) {
                    const survivor_value = s.b.*;
                    self.allocator.destroy(s.a);
                    self.allocator.destroy(s.b);
                    self.allocator.destroy(s);
                    node.* = survivor_value;
                    return false;
                }
                if (self.extractFromNode(s.b, s, target)) {
                    const survivor_value = s.a.*;
                    self.allocator.destroy(s.a);
                    self.allocator.destroy(s.b);
                    self.allocator.destroy(s);
                    node.* = survivor_value;
                    return false;
                }
                return false;
            },
        }
    }

    fn removeFromNode(self: *Layout, node: *Node, parent_split: ?*Split, target: *Pane) bool {
        switch (node.*) {
            .leaf => |p| {
                if (p == target and parent_split != null) return true;
                return false;
            },
            .split => |s| {
                if (self.removeFromNode(s.a, s, target)) {
                    const survivor_value = s.b.*;
                    self.deinitNode(s.a);
                    self.allocator.destroy(s.b);
                    self.allocator.destroy(s.a);
                    self.allocator.destroy(s);
                    node.* = survivor_value;
                    return false;
                }
                if (self.removeFromNode(s.b, s, target)) {
                    const survivor_value = s.a.*;
                    self.deinitNode(s.b);
                    self.allocator.destroy(s.a);
                    self.allocator.destroy(s.b);
                    self.allocator.destroy(s);
                    node.* = survivor_value;
                    return false;
                }
                return false;
            },
        }
    }

    pub fn calculateChildSize(self: *Layout, direction: SplitDir, proportion: f64) struct { u32, u32 } {
        if (direction == .horizontal) {
            const child_w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.width)) * proportion)));
            return .{ child_w, self.height };
        } else {
            const child_h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.height)) * proportion)));
            return .{ self.width, child_h };
        }
    }

    pub fn countLeaves(self: *const Layout) usize {
        return self.countLeavesNode(self.root);
    }

    fn countLeavesNode(self: *const Layout, node: *const Node) usize {
        switch (node.*) {
            .leaf => return 1,
            .split => |s| return self.countLeavesNode(s.a) + self.countLeavesNode(s.b),
        }
    }
};

// ── Tests ──

fn createTestPane(allocator: std.mem.Allocator, id: u32) window.Error!*Pane {
    const pane = try allocator.create(Pane);
    pane.* = try Pane.init(allocator, id, 80, 24);
    return pane;
}

fn destroyTestPane(allocator: std.mem.Allocator, pane: *Pane) void {
    pane.deinit();
    allocator.destroy(pane);
}

test "create layout with single pane" {
    const pane = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane, 80, 24);

    try testing.expectEqual(@as(usize, 1), layout.countLeaves());
    layout.deinit();
}

test "horizontal split creates two panes" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    _ = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);

    try testing.expectEqual(@as(usize, 2), layout.countLeaves());
}

test "vertical split creates two panes" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    _ = try layout.splitPane(testing.allocator, pane1, .vertical, 0.5);

    try testing.expectEqual(@as(usize, 2), layout.countLeaves());
}

test "split proportions are correct" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    _ = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.75);

    try testing.expectEqual(@as(usize, 2), layout.countLeaves());
}

test "close pane collapses parent split" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    const pane2 = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);

    try testing.expectEqual(@as(usize, 2), layout.countLeaves());

    layout.removePane(pane2);
    try testing.expectEqual(@as(usize, 1), layout.countLeaves());
}

test "nested splits" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    _ = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);
    _ = try layout.splitPane(testing.allocator, pane1, .vertical, 0.5);

    try testing.expectEqual(@as(usize, 3), layout.countLeaves());
    try testing.expect(layout.root.* == .split);
}

test "close pane in nested layout" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    _ = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);
    const pane3 = try layout.splitPane(testing.allocator, pane1, .vertical, 0.5);

    try testing.expectEqual(@as(usize, 3), layout.countLeaves());

    layout.removePane(pane3);
    try testing.expectEqual(@as(usize, 2), layout.countLeaves());
}

test "remove all leaves collapses to single" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    const pane2 = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);

    layout.removePane(pane2);
    try testing.expectEqual(@as(usize, 1), layout.countLeaves());

    layout.removePane(pane1);
    try testing.expectEqual(@as(usize, 1), layout.countLeaves());
}

test "multiple horizontal splits" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    var current = pane1;
    for (0..4) |_| {
        current = try layout.splitPane(testing.allocator, current, .horizontal, 0.5);
    }

    try testing.expectEqual(@as(usize, 5), layout.countLeaves());
}
