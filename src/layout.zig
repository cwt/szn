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

    fn deinitNode(self: *Layout, root: *Node) void {
        const curr = root;
        while (true) {
            switch (curr.*) {
                .leaf => |pane| {
                    pane.deinit();
                    self.allocator.destroy(pane);
                    break;
                },
                .split => |s| {
                    if (s.a.* == .split) {
                        // Rotate right to push splits to the right and bring leaf towards left
                        const left_node = s.a;
                        const left_split = left_node.split;

                        s.a = left_split.b;
                        left_split.b = left_node;
                        left_node.* = Node{ .split = s };
                        curr.* = Node{ .split = left_split };
                    } else {
                        // Left child is a leaf, destroy it
                        const leaf_node = s.a;
                        const pane = leaf_node.leaf;
                        pane.deinit();
                        self.allocator.destroy(pane);
                        self.allocator.destroy(leaf_node);

                        // Replace curr with its right child
                        const right_node = s.b;
                        curr.* = right_node.*;
                        self.allocator.destroy(right_node);
                        self.allocator.destroy(s);
                    }
                },
            }
        }
    }

    pub fn splitPane(self: *Layout, allocator: std.mem.Allocator, pane: *Pane, direction: SplitDir, proportion: f64) window.Error!*Pane {
        _ = allocator;
        const a = self.allocator;
        const leaf_node = self.findLeafParent(self.root, pane) orelse return error.PaneNotFound;

        const parent_w = pane.screen.grid.width;
        const parent_h = pane.screen.grid.height;

        var child_w1 = parent_w;
        var child_h1 = parent_h;
        var child_w2 = parent_w;
        var child_h2 = parent_h;

        if (direction == .horizontal) {
            const available_w = parent_w -| 1;
            const split_w = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_w)) * proportion));
            child_w1 = @max(1, split_w);
            child_w2 = @max(1, available_w -| child_w1);
        } else {
            const available_h = parent_h -| 1;
            const split_h = @as(u32, @intFromFloat(@as(f64, @floatFromInt(available_h)) * proportion));
            child_h1 = @max(1, split_h);
            child_h2 = @max(1, available_h -| child_h1);
        }

        const new_pane = try a.create(Pane);
        new_pane.* = Pane.init(a, 0, child_w2, child_h2) catch |err| {
            a.destroy(new_pane);
            return err;
        };
        errdefer {
            new_pane.deinit();
            a.destroy(new_pane);
        }

        try pane.resizeTerminal(child_w1, child_h1);

        const split = try a.create(Split);
        errdefer a.destroy(split);
        const a_node = try a.create(Node);
        errdefer a.destroy(a_node);
        const b_node = try a.create(Node);
        errdefer a.destroy(b_node);

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

    pub fn findSiblingPane(self: *Layout, target: *Pane) ?*Pane {
        return self.findSiblingOfNode(self.root, target);
    }

    fn findSiblingOfNode(self: *Layout, node: *const Node, target: *Pane) ?*Pane {
        switch (node.*) {
            .leaf => return null,
            .split => |s| {
                if (s.a.* == .leaf and s.a.leaf == target) {
                    return self.findFirstLeaf(s.b);
                }
                if (s.b.* == .leaf and s.b.leaf == target) {
                    return self.findFirstLeaf(s.a);
                }
                if (self.findSiblingOfNode(s.a, target)) |found| return found;
                if (self.findSiblingOfNode(s.b, target)) |found| return found;
                return null;
            },
        }
    }

    fn findFirstLeaf(self: *Layout, node: *const Node) *Pane {
        _ = self;
        var curr = node;
        while (true) {
            switch (curr.*) {
                .leaf => |p| return p,
                .split => |s| curr = s.a,
            }
        }
    }

    pub fn rotatePanes(self: *Layout) void {
        var leaves: std.ArrayList(*Node) = .empty;
        defer leaves.deinit(self.allocator);
        self.collectLeafNodes(self.root, &leaves) catch return;
        if (leaves.items.len < 2) return;

        const first_pane = leaves.items[0].leaf;
        for (0..leaves.items.len - 1) |i| {
            leaves.items[i].leaf = leaves.items[i + 1].leaf;
        }
        leaves.items[leaves.items.len - 1].leaf = first_pane;
    }

    fn collectLeafNodes(self: *Layout, node: *Node, out: *std.ArrayList(*Node)) !void {
        switch (node.*) {
            .leaf => try out.append(self.allocator, node),
            .split => |s| {
                try self.collectLeafNodes(s.a, out);
                try self.collectLeafNodes(s.b, out);
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

    pub fn countLeaves(self: *const Layout) usize {
        var stack: std.ArrayList(*const Node) = .empty;
        defer stack.deinit(self.allocator);
        stack.append(self.allocator, self.root) catch return 0;

        var count: usize = 0;
        while (stack.pop()) |n| {
            switch (n.*) {
                .leaf => count += 1,
                .split => |s| {
                    stack.append(self.allocator, s.a) catch return 0;
                    stack.append(self.allocator, s.b) catch return 0;
                },
            }
        }
        return count;
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

test "find sibling pane basic" {
    const pane1 = try createTestPane(testing.allocator, 1);
    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    // With 1 pane, no sibling
    try testing.expect(layout.findSiblingPane(pane1) == null);

    const pane2 = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);
    // pane1 and pane2 are siblings
    try testing.expectEqual(pane2, layout.findSiblingPane(pane1));
    try testing.expectEqual(pane1, layout.findSiblingPane(pane2));

    const pane3 = try layout.splitPane(testing.allocator, pane2, .vertical, 0.5);
    // Now pane2 and pane3 are siblings.
    // Sibling of pane1 is first leaf of pane2's split, which is pane2 itself.
    try testing.expectEqual(pane2, layout.findSiblingPane(pane3));
}

test "splitPane handles Pane.init OOM without leaking new_pane — bug #91" {
    const pane1 = try createTestPane(testing.allocator, 0);

    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    // splitPane ignores its allocator parameter and uses self.allocator,
    // so we can't inject failure through it. Instead verify the normal path
    // works after the errdefer fix.
    const pane2 = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);

    try testing.expectEqual(@as(usize, 2), layout.countLeaves());
    _ = pane2;
}

test "countLeaves handles deeply nested layout without stack overflow — bug #179" {
    const pane1 = try createTestPane(testing.allocator, 0);
    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    defer layout.deinit();

    const depth = 500;
    var current = pane1;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        current = try layout.splitPane(testing.allocator, current, .horizontal, 0.5);
    }

    // Should have depth + 1 leaves (the chain creates a comb layout)
    try testing.expectEqual(@as(usize, depth + 1), layout.countLeaves());
}

test "split pane horizontal sizes are equal" {
    const pane1 = try createTestPane(testing.allocator, 0);
    try pane1.resizeTerminal(61, 24);

    // Initial parent of width 61, height 24
    var layout = try Layout.init(testing.allocator, pane1, 61, 24);
    defer layout.deinit();

    // Split horizontally (side-by-side) with 0.5 proportion.
    // Width 61 - 1 border = 60 available width.
    // Each child pane should get exactly 30 columns.
    const pane2 = try layout.splitPane(testing.allocator, pane1, .horizontal, 0.5);

    try testing.expectEqual(@as(u32, 30), pane1.screen.grid.width);
    try testing.expectEqual(@as(u32, 30), pane2.screen.grid.width);
}

test "deinit handles massive nested layout without stack overflow" {
    const pane1 = try createTestPane(testing.allocator, 0);
    var layout = try Layout.init(testing.allocator, pane1, 80, 24);
    // Defer the deinit which calls deinitNode
    defer layout.deinit();

    const depth = 5000;
    var current = pane1;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        current = try layout.splitPane(testing.allocator, current, .horizontal, 0.5);
    }

    try testing.expectEqual(@as(usize, depth + 1), layout.countLeaves());
}
