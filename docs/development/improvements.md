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

## COMPLETED IN THIS SESSION (rev 38X)

### Status bar fully configurable (tmux-compatible)

**src/format.zig, src/status.zig, src/options.zig, src/server/server.zig, src/server/render.zig**

The status bar now uses the same option surface as tmux:

- **Options added:** status-left, status-right, status-left-length,
  status-right-length, status-justify, window-status-format,
  window-status-current-format.
- **Tmux coercions:** flag->choice, string->colour auto-parsed.
- **status off** hides the bar entirely (full terminal height).
- **status-interval** drives periodic timer flagging dirty for %H:%M updates.
- **Window list** uses window-status-format / window-status-current-format.
- **Builds the entire line** (left + window-list + right) in one pass
  with CSI-aware truncation and tmux-style justify (left/centre/right).

### 1. Format template compiled + cached (rev 38X)

**src/format.zig** — TemplateCache stores compiled ops (literal, brace, style, alias).
getOrCompile() reuses ops. expandInto/expandOpsInto write to caller buffer,
no intermediate owned-string returns.

### 2. No-dupe variable expansion (rev 38X)

appendVariable() writes directly to result ArrayList — no allocator.dupe.
The old expandVariable that returned owned slices is replaced.

### 3. splitArgs() slices, not dupes (rev 38X)

Arguments tracked as const u8 slices into original template string.
freeArgs only deinits the ArrayList — no per-argument frees.

### 4. Tmux format syntax added (rev 38X)

- Single-char aliases: #S, #I, #W, #P, #T, #H, #h, #F
- Style sequences: #[fg=red], #[bg=colour], #[bold], #[underscore], #[reverse], #[default]
- Strftime: %H:%M, %d-%b-%y, %% -> literal %
- Alias syntax alongside #{...} brace expansion

## PREVIOUS OPTIMIZATIONS (already done, noted for posterity)

### Fixed: copy-mode incremental search wired up + scans history (rev 378)

`src/mode_copy.zig`, `src/server/server.zig`

Copy-mode search is now reachable from the keyboard:
- vi mode: `/` → search forward, `?` → search backward, `n`/`N` repeat.
- emacs mode: `C-s` → search forward, `C-r` → search backward.

The query is collected through the existing command-prompt input path
(`command_buf` / `command_mode`), and on Enter dispatched to
`CopyMode.submitSearch`. `last_search` is retained on the server so `n`/`N`
can repeat without retyping.

 `searchForward`/`searchBackward` now walk the **entire** scrollback
 (history ring + visible grid) using a combined logical-line index, so
 matches in scrolled-back history are found. Matches in history are pinned
 to the top of the screen; visible matches keep their position. Search is
 **cyclic**: if no match is found from the cursor to the end (forward) or
 start (backward), it wraps around and continues from the opposite end up
 to the cursor, so `/foo` from the bottom line still finds `foo` at the top.

### Fixed: `searchLine()` O(n*m) → `std.mem.indexOf` over UTF-8 line bytes (rev 378)

`src/mode_copy.zig`

The old `searchLine` compared the needle cell-by-cell for every start
position. The new `searchLogicalLine` renders each logical line once into a
reused UTF-8 byte buffer (`lineBytes`) and uses `std.mem.indexOf(u8, ...)`
over the whole line, then adjusts the start column. Backward search does a
single right-to-left scan. This is the improvement previously logged as
item #3; it is now implemented and no longer a hotspot.

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
