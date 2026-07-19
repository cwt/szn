---
type: improvements
title: "Performance & Optimization Opportunities — szn"
description: "Catalog of performance bottlenecks, memory churn, and optimization targets sorted by effort-to-impact."
timestamp: 2026-07-20T10:00:00Z
---

# Performance & Optimization Opportunities — szn

Sorted by effort-to-impact ratio. All findings from a full codebase audit
(2026-07-20).

---

## LOW EFFORT, HIGH IMPACT (fix in minutes, save ms per frame)

### 1. Arena allocator not used in hot paths

AGENTS.md says "arena per session/pane lifecycle" but grid ops, input
parsing, and render all use the general-purpose allocator directly.

**Every PTY read path:**
- `grid.zig` — `scrollUp`/`scrollDown`/`setCell`/`clearRegion` all use
  `allocator.resize`/`append` on `ArrayList(Cell)`
- `input.zig` — `osc_buf.append`, `allocator.dupe` for parsed strings
- `server.zig` — `esc_buf` created and freed per `processInput` call
- `render.zig` — `bounds` ArrayList freed per frame

**Fix:** Thread `session.arena.allocator()` through `Grid`, `Screen`,
`InputParser`, `Term` (tty.zig). All hot-path alloc/free pairs become
arena bumps — zero-cost teardown on session exit.

**Files:** `src/grid.zig`, `src/input.zig`, `src/server/server.zig`,
`src/server/render.zig`, `src/window.zig`, `src/screen.zig`

---

### 2. `scrollUp()` history trim is O(n) memmove

**`src/grid.zig:213–227`**

When history exceeds `history_limit + 64`, the function shifts ALL remaining
items forward with `std.mem.copyForwards`. This is O(history_len) memmove on
every scroll once the threshold is hit.

```zig
// After trim, shift remaining history forward
for (remaining, 0..) |*r, j| {
    r.* = self.history.items[trim_count + j];
}
self.history.shrinkRetainingCapacity(self.history.items.len - trim_count);
```

For a 5000-line scrollback at 60fps with continuous output, that's ~300K
lines shifted per second.

**Fix:** Use a ring buffer for history (same as visible lines use
`start_index`). Track `history_start` offset and only compact when the gap
grows too large.

---

### 3. SGR sixel image lookup in cell-render inner loop

**`src/server/render.zig:208–242`**

For every single cell in every pane, the render loop calls
`pb.pane.screen.findSixelImage(image_id)` which does a linear scan of up
to 64 sixel slots. For cells without sixel attributes (the common case),
this is pure waste.

**Fix:** Pre-compute a boolean `has_sixels` per-pane at the start of the
render loop and skip the sixel lookup entirely for panes without images.

---

### 4. `bounds` ArrayList allocated on every render frame

**`src/server/render.zig:2189–2194`**

```zig
var bounds: std.ArrayList(render.PaneBounds) = .empty;
defer bounds.deinit(self.allocator);
self.collectPaneBounds(...)
```

Heap-allocated and freed per frame. For a typical 2–4 pane layout this is
small churn, but unnecessary.

**Fix:** Use fixed-size stack array with heap fallback for deeply nested
layouts, or cache as a field on `DisplayClient`.

---

### 5. `yankSelection()` per-line ArrayList allocation

**`src/mode_copy.zig:282–332`**

For every selected line, allocates a `line_buf` ArrayList, appends
characters one-by-one, then appends to a result buffer. For a 1000-line
selection, that's 1000 ArrayList allocations + tens of thousands of
individual `append` calls.

**Fix:** Pre-compute total selection length, allocate once, write trimmed
content directly to the result buffer.

---

## MODERATE EFFORT, HIGH IMPACT

### 6. Merged grid rebuilt from scratch every frame

**`src/server/render.zig:181–252`**

Every render frame:
1. `@memset` clears ALL merged screen cells (O(total_cells))
2. Copies ALL pane cells into merged screen (O(total_cells))
3. Draws borders over the full merged screen

This is a full recompute — NOT incremental. The per-client render diff
only helps with escape emission, not the merged grid construction.

For a 200×100 terminal (20K cells), every frame does 20K cell operations
even if NOTHING changed.

**Fix:** Use `dirty` flag on individual grid lines. Only copy dirty lines.
Or keep a per-pane dirty-rect and only recompute that region.

---

### 7. Full render on any pane dirty, not per-pane

**`src/server/server.zig:2147–2237`**

When any pane is dirty, a FULL render pass runs for every display client:
collecting bounds, rendering all panes, drawing all borders. Wasteful when
only one pane in a 6-pane layout changed.

**Fix:** Track dirty panes individually. Only copy/emit changed panes in
the merged screen. Border redraw still needs full pass, but pane content
can be selective.

---

### 8. SGR escape sequence rebuilt from scratch on every cell change

**`src/server/render.zig:469–537`**

When a cell's fg/bg/attr changes, the renderer:
1. Emits `\x1b[m` (full reset)
2. Iterates through ALL attribute fields emitting each SGR code
3. Emits fg colour
4. Emits bg colour

Adjacent cells with the same style emit redundant sequences.

**Fix:** Track last-emitted SGR state per render pass. Only emit delta.
If only bg changed, emit just the bg sequence instead of full reset+rebuild.

---

### 9. `renderSixelImages()` scans every cell of every pane

**`src/server/render.zig:718–771`**

For each pane, each row, each column — checks `cell.attr.sixel`.
O(total_cells) per frame even when no sixel is present.

**Fix:** Gate sixel-render section on whether any sixel image exists in
any pane. Skip entirely if none.

---

### 10. Format template re-parsed on every `expand()` call

**`src/format.zig:45–83`**

The status bar format template (e.g. `#S #[fg=colour245]#W #[default]#F`)
is parsed character-by-character every time `expand()` is called. For a
status bar refreshed every 100ms, the same template is parsed hundreds of
times.

**Fix:** Compile the template into a list of ops (literal segments /
variable references / conditionals) at first expansion. Cache the compiled
form. Only re-parse if the template string changes.

---

### 11. Each format sub-expression allocates via `dupe`

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

### 12. `searchLine()` naive O(n*m) substring comparison

**`src/mode_copy.zig:601–638`**

For every starting position, compares `needle.len` cells byte-by-byte.
No skip table, no memchr equivalent. For a 200-column line searching for
a 5-char string: up to 200 × 5 = 1000 cell reads per line. For a 1000-line
scrollback: 1M cell reads per search.

**Fix:** Pre-convert line to UTF-8 bytes once, use `std.mem.indexOf(u8)`.
Or implement a simple two-byte lookahead skip.

---

### 13. `usleep(2000)` blocks the event loop

**`src/server/server.zig:442`**

```zig
_ = c_usleep(2000);
```

When a sixel is pending (awaiting cell size measurement), the event loop
thread sleeps for 2ms per iteration — blocking ALL other processing (other
panes, clients). 2ms stall on every poll iteration when any pane has a
pending sixel.

**Fix:** Use a timer fd, or skip the PTY poll for that pane. The kernel
already buffers the data — no need to busy-wait.

---

## SIGNIFICANT REFACTOR

### 14. `reflowCursorInternal()` flattens every line, even untouched ones

**`src/grid.zig:697–764`**

The flattening phase creates `flat_cells` (ArrayList of Cell) and
`logical_spans` by iterating through ALL lines, trimming trailing empties,
checking cursor position, etc. For a 5000-line × 200-cell history = 1M
cells re-allocated during reflow.

**Fix:** Represent logical lines as slices into existing grid lines
instead of flattening to a new contiguous buffer. Or pre-allocate
`flat_cells` to the estimated total size.

---

### 15. `splitArgs()` dupes each argument in format expressions

**`src/format.zig:450–459`**

Every comma-separated argument in `#{?cond,true,false}` is heap-allocated
with `allocator.dupe`, then freed with `freeArgs`. For deeply nested
conditionals, this multiplies allocation churn.

**Fix:** Track offsets into the original input string instead of
duplicating. Pass `[]const u8` slices of the original content.

---

## KNOWN BUG-LIKE LIMITATIONS (documented here, not functional bugs)

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
