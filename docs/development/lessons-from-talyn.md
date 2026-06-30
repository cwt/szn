# Lessons from Talyn (Zig Project)

Lessons learned from [Talyn](https://github.com/cwt/talyn) that apply to szn.
Each lesson has been adapted from its original context to szn's arena-based,
terminal-multiplexer domain.

---

## 1. Struct Literal After `allocator.create`

**Source:** Talyn Zig-Specific §49  
**Risk:** High — memory corruption

`allocator.create(T)` returns **uninitialised memory**. Struct field defaults
(e.g. `field: bool = false`) are only applied by struct literals, not by
`create` + field-by-field assignment.

```zig
// WRONG — newly added fields are garbage in Release builds
const opt = try allocator.create(Options);
opt.map = map;
opt.arena = arena;

// RIGHT — compiler enforces completeness
const opt = try allocator.create(Options);
opt.* = Options{
    .map = map,
    .arena = arena,
    // any field omitted = compile error
};
```

**Applies to szn:** Arena allocations for sessions, windows, panes, layout
nodes. If a new field is added to any struct allocated via `create`, the
literal form catches it at compile time.

---

## 2. `errdefer` Immediately After Every Resource Acquisition

**Source:** Talyn Zig-Specific §77, §88  
**Risk:** High — resource leaks outside arena scope

Arenas handle bulk memory free, but external resources (file descriptors,
epoll/kqueue fds, socket fds, mmap'd regions) won't wait for arena reset.

```zig
const fd = try std.os.open(path, .{ .RDONLY }, 0);
errdefer std.os.close(fd);
// ... code that might fail ...
```

**Pattern:** After every acquisition:
1. Acquire resource R
2. `errdefer cleanup(R);` immediately
3. Continue with fallible code

**Applies to szn:** Socket FDs (client-server IPC), PTY FDs, log files,
event loop FDs (epoll/kqueue), any `mmap` call.

---

## 3. No Bare `else => {}` in Switch

**Source:** Talyn Defensive §85  
**Risk:** Medium — silent logic errors

```zig
// WRONG — silent bug when a new variant is added
switch (ev) {
    .key => |k| handleKey(k),
    .mouse => |m| handleMouse(m),
    else => {},
}

// RIGHT — loud on unexpected variants
switch (ev) {
    .key => |k| handleKey(k),
    .mouse => |m| handleMouse(m),
    else => std.log.warn("unhandled event: {}", .{ev}),
}
```

If you have an `else => {}` that is genuinely unreachable, annotate with
`else => unreachable` so the compiler catches a future variant addition.

**Applies to szn:** Event dispatch, escape parser state machine, command
dispatch, key binding tables, option type handling.

---

## 4. Silent Failure — Surface Invariant Violations

**Source:** Talyn Defensive §57  
**Risk:** Medium — hard-to-find bugs

```zig
// WRONG — hides bugs silently
if (someInvariantViolated()) return;

// RIGHT — makes failure visible
if (someInvariantViolated()) {
    std.log.err("invariant violated: ...", .{});
    return error.InvariantViolation;
}

// If truly impossible
if (someImpossibleCondition()) unreachable;
```

**Applies to szn:** Grid cell access bounds, layout tree invariants,
option validation, config parser error recovery.

---

## 5. Tail Calls Are Not TCO in Zig

**Source:** Talyn DS §53  
**Risk:** Medium — stack overflow on deep recursion

Zig does NOT perform tail-call optimisation in Debug or ReleaseSafe. A
function that calls itself at the tail is a full stack frame allocation.

```zig
// WRONG — will overflow stack at ~1000+ depth
fn walkTree(node: *Node) void {
    // ...
    return walkTree(node.left);
}

// RIGHT — explicit loop
fn walkTree(root: *Node) void {
    var node = root;
    while (true) {
        // ...
        node = node.left;
    }
}
```

**Applies to szn:** Layout tree traversal, grid line walking, session
window iteration (though most szn trees are shallow — <100 nodes).

---

## 6. `.?` Panics — Use `orelse` Instead

**Source:** Talyn Zig-Specific §55  
**Risk:** Medium — crash on unexpected null

```zig
// WRONG — panics if lookup fails
const pane = session.activePane.?;

// RIGHT — handle null explicitly
const pane = session.activePane orelse {
    std.log.warn("no active pane", .{});
    return error.NoActivePane;
};
```

`try` does nothing for optionals — it only propagates error unions:
```zig
// try does nothing here; null will cause a crash downstream
const x = try someOptionalReturningFunc();
```

**Applies to szn:** `active_window`/`active_pane` lookups, option value
retrieval, key binding lookups, `std.StringHashMap.get()` results.

---

## 7. Whitespace Variants in Parsers

**Source:** Talyn Defensive §90  
**Risk:** Low — edge case in config parsing

```zig
// WRONG — tabs in config files silently eat input
var it = std.mem.splitScalar(u8, line, ' ');

// RIGHT — handle all whitespace
var it = std.mem.splitAny(u8, line, " \t");
```

**Applies to szn:** Config parser (`cfg.zig`) — tmux configs may use tabs
between `set -g option value`. Add `\t`, `\r` handling.

---

## 8. Off-by-One at Capacity 0

**Source:** Talyn DS §100  
**Risk:** Low — edge case

When checking capacity, `n >= 0` is always true for unsigned types. A
capacity-0 check that evaluates `count >= capacity` where `capacity = 0`
will always evict, but then add the entry — the "capacity 0" container
will hold 1 item.

```zig
// Add early return for degenerate case
if (self.capacity == 0) return;
```

**Applies to szn:** Options max-history, scrollback limits, any
user-configurable numeric limit.
