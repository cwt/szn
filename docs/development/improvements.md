---
type: improvements
title: "Performance & Optimization Opportunities — szn"
description: "Catalog of performance bottlenecks, memory churn, and optimization targets sorted by effort-to-impact."
timestamp: 2026-07-20T16:00:00Z
---

# Performance & Optimization Opportunities — szn

Sorted by effort-to-impact ratio. Findings from a full codebase audit
(2026-07-20), with completion status reconciled against the current code
at revision 377.

---

## MODERATE EFFORT, HIGH IMPACT — REMAINING

### 1. Format template re-parsed on every `expand()` call

**`src/format.zig:45–83`**

The status bar format template (e.g. `#S #[fg=colour245]#W #[default]#F`)
is parsed character-by-character every time `expand()` is called. For a
status bar refreshed every 100ms, the same template is parsed hundreds of
times.

**Fix:** Compile the template into a list of ops (literal segments /
variable references / conditionals) at first expansion. Cache the compiled
form. Only re-parse if the template string changes.

---

### 2. Each format sub-expression allocates via `dupe`

**`src/format.zig:190–195`**

```zig
pub fn expandVariable(allocator, name, ctx) ![]const u8 {
    if (ctx.get(name)) |value| {
        return try allocator.dupe(u8, value);
    }
    return try allocator.dupe(u8, "");
}
```

Every variable lookup returns a freshly `dupe`'d string. For a status line
like `#S - #W [#I] #{?#{pane_active},*,}`, that's 5+ allocations per
expansion.

**Fix:** Return slices into a reuse buffer instead of fresh allocations.
The caller already accumulates into a result ArrayList — intermediate
allocations are unnecessary.

---

### 3. `searchLine()` naive O(n*m) substring comparison

**`src/mode_copy.zig:601–638`**

For every starting position, compares `needle.len` cells byte-by-byte.
No skip table, no memchr equivalent. For a 200-column line searching for
a 5-char string: up to 200 × 5 = 1000 cell reads per line. For a 1000-line
scrollback: 1M cell reads per search.

**Fix:** Pre-convert line to UTF-8 bytes once, use `std.mem.indexOf(u8)`.
Or implement a simple two-byte lookahead skip.

---

## SIGNIFICANT REFACTOR

### 4. `splitArgs()` dupes each argument in format expressions

**`src/format.zig:450–459`**

Every comma-separated argument in `#{?cond,true,false}` is heap-allocated
with `allocator.dupe`, then freed with `freeArgs`. For deeply nested
conditionals, this multiplies allocation churn.

**Fix:** Track offsets into the original input string instead of
duplicating. Pass `[]const u8` slices of the original content.

---

## KNOWN BUG-LIKE LIMITATIONS — REMAINING (documented here, not functional bugs)

### Copy mode search only scans visible grid, not history

`src/mode_copy.zig:337–371`

`searchForward` and `searchBackward` only iterate `y < grid.height`
(visible grid lines). When copy mode has `scroll_offset > 0` (user has
scrolled back), search will not find content in history lines.

Additionally, search is not yet wired to the key handlers — the `searchForward`
and `searchBackward` functions exist but are only called from unit tests.
There are no `/` or `?` bindings in vi mode, and no `C-s`/`C-r` bindings
in emacs mode.

**Status:** Incomplete feature, not a regression.

---

## PREVIOUS OPTIMIZATIONS (already done, noted for posterity)

### Fixed: incremental merged grid — skip clear + non-dirty panes (rev 372)

`src/server/render.zig`

`renderAll` now takes a `full_rebuild` parameter. When only content changed
(not layout/structure), the merged-screen `@memset` is skipped and only
dirty panes (`pb.pane.dirty`) are copied into the merged screen. Non-dirty
panes retain their previous frame's content. Borrowed from the session's
`dirty` flag (set on layout/size changes, cleared once the frame flushes).

### Fixed: SGR escape sequence delta emission (rev 373, color-loss fix rev 377)

`src/server/render.zig`

Instead of emitting `\x1b[m` + full attribute rebuild on every style change,
only the changed components are emitted: fg-only, bg-only, or (rare) attr
reset + rebuild. A follow-up fix ensures that when an attribute-only change
emits `\x1b[m` (which resets fg/bg to default), fg and bg are re-emitted
unconditionally so colored text keeps its color across an attribute-only
style change.

### Fixed: `renderSixelImages()` early-return when no sixels present (rev 374)

`src/server/render.zig`

Skips the O(total_cells) pane scan entirely when no pane in the frame has
any sixel images (neither current sixel_images nor last-frame anchors).

### Fixed: `usleep(2000)` blocking the event loop during sixel cell-size wait (rev 375)

`src/server/server.zig`

Removed the 2 ms artificial stall. PTY data stays buffered in the kernel
and the event loop already polls with a 1 ms timeout, so other panes and
clients are no longer blocked during the cell-size measurement window.

### Fixed: `scrollUp()` history trim — O(n) memmove eliminated (rev 371)

`src/grid.zig`

History now uses a ring buffer via `history_start: usize` offset; the
oldest entry is deinitialized in-place and `history_start` advances, with
periodic compaction when the gap exceeds 256. All external indexers in
`render.zig`, `mode_copy.zig`, `screen.zig`, and `server.zig` updated to use
`items.len - history_start` for logical length and `history_start + idx`
for element access.

### Fixed: `reflowCursorInternal()` pre-allocates flat buffers (rev 376)

`src/grid.zig`

`flat_cells` is pre-allocated to `process_limit * self.width` and
`logical_spans` to `process_limit` in a single allocation each, avoiding
O(log n) realloc + copies during the flattening phase.

### Fixed: `deleteLine()` / `insertLine()` struct-copy aliasing

`src/grid.zig:263–274`

The exploration agent flagged that `@memset` after `getLineMut(height-1).* = temp`
might clear a shared buffer. Analysis confirms this is NOT a bug — the algorithm
correctly shuffles buffers without leaving aliased pointers:

- `temp` captures the line being moved
- The loop shifts lines by struct-value copy (temporary aliasing between
  adjacent lines during intermediate steps)
- The final `= temp` assignment replaces the target line with the captured
  buffer, breaking any alias chain
- The `@memset` only affects the buffer now owned solely by the target line

The `ArrayList(Cell)` pointer is moved, not shared. Verified by tracing
through all edge cases (y=0, y=height-2, height=1).

---

### Fixed: `rewrap()` intermediate slice allocation

`src/grid.zig`

`rewrap()` now writes directly into `out_lines: *std.ArrayList(GridLine)`,
eliminating the `toOwnedSlice` + `free` per logical line. Caller appends
are now `out_lines` operations — no intermediate ownership handoff.

---

### Fixed: `processInput()` `esc_buf` heap allocation per call

`src/server/server.zig`

`esc_buf` moved from a local variable in `processInput()` (created and freed
on every stdin_data message) to a `Server` struct field. Uses
`clearRetainingCapacity()` between calls, avoiding reallocation churn.

---

### Fixed: `osc_buf` freed on every escape sequence completion

`src/input.zig`

Both `toGround()` (line ~182) and `dispatchOsc()` (defer block) now call
`self.osc_buf.clearRetainingCapacity()` instead of `deinit` + `= .empty`.
The backing buffer is retained across OSC sequences, avoiding repeated
free + realloc for title/clipboard/hyperlink sequences.

6 OSC unit tests updated with `defer parser.deinit(testing.allocator)` to
prevent false-positive leak detection from retained buffer.

---

### Fixed: `rewrap()` Thai word-break lookup for non-Thai text

`src/grid.zig`

Before calling `thai.findWordBreaks(allocator, cells)`, `rewrap()` now
quick-scans cells for Thai codepoints (`U+0E00–U+0E7F`). If none found,
the call is skipped entirely. Avoids allocation + processing overhead for
the 99%+ of terminal content that is pure ASCII/Latin/Non-Thai.

---

### Fixed: `rewrap()` padding loop appending one-by-one

`src/grid.zig`

```zig
// Before: one-by-one appends with per-iteration realloc
while (line_cells.items.len < new_width) {
    try line_cells.append(allocator, Cell.empty());
}

// After: single ensureUnusedCapacity + @memset
try line_cells.resize(allocator, new_width);
@memset(line_cells.items[old_len..new_width], Cell.empty());
```

Replaced while-append with `resize` + `@memset` — single realloc instead of
O(n) reallocations.

---

### Arena allocator already threaded through hot paths

`src/session.zig` → `Window.init` → `Pane.init` → `Screen.init` → `Grid.init`

`Session.init` wraps the backing allocator in `std.heap.ArenaAllocator` and
passes `self.arena.allocator()` through the entire chain. Grid, Screen, and
InputParser already receive the arena allocator in production code. No
change needed — the infrastructure was already in place.

---

### Fixed: SGR sixel image lookup in cell-render inner loop

`src/server/render.zig`

Per-pane `pane_has_sixels` flag computed once per pane before the y/x
render loops. Guards the `findSixelImage` call — skipped entirely for
panes without any sixel images in the 64-slot registry.

---

### Fixed: `bounds` ArrayList allocated on every render frame

`src/server/server.zig`

Moved to `DisplayClient.bounds_buf` field with `clearRetainingCapacity()`
between frames. The backing buffer is retained across render cycles
instead of being freed and re-allocated per frame.

---

### Fixed: `yankSelection()` per-line ArrayList allocation

`src/mode_copy.zig`

Per-line `line_buf` ArrayList eliminated. Cell content is written directly
into the `result` buffer. Trailing spaces are trimmed by shrinking
`result.items.len` at line boundaries. Single growing buffer replaces
N+1 (result + per-line) ArrayList allocations per yank.
