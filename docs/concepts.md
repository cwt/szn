---
type: architecture_guideline
title: "szn Concepts Glossary"
description: "Definitions of core szn concepts: session, window, pane, grid, cell, screen, layout, sixel, copy/choose mode, display client, options, and buffers."
timestamp: 2026-07-07T18:56:29Z
---

# Concepts Glossary

A reference for the domain vocabulary used throughout szn's code and docs.

## Structural concepts

- **Session** (`session.zig`) — top-level unit, owns an arena allocator and a
  list of windows. Has an `active_window`, `last_window`, size, and per-session
  `Options`. The server serves one active session at a time.
- **Window** (`window.zig:219`) — a tab within a session; owns a list of panes
  and a binary-split `Layout` tree for pane geometry.
- **Pane** (`window.zig:18`) — a rectangle showing one PTY/shell. Holds a
  `Screen`, an optional `pty` (the forked shell child), an optional
  `InputParser`, and a `dirty` flag. A `saved_grid` snapshots content for
  overlays (clock/choose mode).
- **Layout** (`layout.zig`) — binary split tree describing how a window's panes
  are tiled (used to compute `PaneBounds` for rendering).
- **Display client** (`server.zig`) — one attached client terminal. Has its own
  size and `last_cells` diff state; the session resizes to the **minimum** of
  all attached clients (`recalculateMinimumSize`).

## Terminal model

- **Grid** (`grid.zig:68`) — the scrollable content: a ring-buffer of
  `GridLine`s plus a `history` scrollback buffer (limit 2000). `GridLine` =
  `cells` + `dirty` + `wrapped` (soft-wrap continuation, used by reflow).
- **Cell** (`grid.zig:25`) — one screen position: `packed struct(u128)` with
  `char`, up to two combining codepoints, `attr`, `fg`, `bg`, and an
  `is_padding` flag for the trailing half of a wide character.
- **Attr** (`grid.zig:10`) — `packed struct(u16)` of boolean style flags
  (bold, dim, italic, underline, blink, reverse, strikethrough, overline,
  double/curly underline).
- **Colour** (`colour.zig:11`) — `packed struct(u32)`: `tag` (indexed/rgb/
  default/terminal) + `u24` value.
- **Screen** (`screen.zig:67`) — wraps a `Grid` plus an optional `alt_grid`
  (alternate screen), cursor + saved cursor, `Mode` (`packed struct(u32)`:
  line-wrap, alt-screen, cursor, paste, mouse-sgr, sync, …), `copy_mode`, and
  `sixel_images`.
- **SixelImage** (`screen.zig:13`) — a stored sixel graphic: the raw DCS bytes
  plus anchor `col`/`row` and parsed pixel dimensions (`px_width`/`px_height`
  from the raster attributes). Rendered verbatim at its absolute position.
  If a sixel arrives before the terminal's cell size is *measured*, it is
  buffered in `Screen.pending_sixel` and replayed once `cell_size_known`
  (driven by the `cell_size` IPC message) is true.

## Modes and interaction

- **Copy mode** (`mode_copy.zig`) — vi/emacs-style scroll/select over a pane's
  history; drives reverse-video selection rendering.
- **Choose mode** (`choose.zig`) — an interactive list overlay (e.g. buffer /
  session picker).
- **Clock mode** (`clock.zig`) — renders a clock overlay in a pane.
- **Key binding** (`key_binding.zig`) — `Action` enum, `KeyTable`, and
  `KeyDispatcher` with default bindings; `mapCommandToAction` links commands to
  actions.
- **Options** (`options.zig`) — `Options` type with comptime-defined
  `SESSION_OPTIONS` / `WINDOW_OPTIONS`; set via `set-option`.

## I/O and data

- **Buffer** (`buffer.zig`) — paste buffer list (`copy-mode`/`choose-buffer`).
- **Format** (`format.zig`) — `%{}` template expansion used for status-bar and
  message text.
- **Status** (`status.zig`) — status-bar model rendered on the reserved last
  row.
- **Input parser** (`input.zig`) — byte state machine turning PTY output into
  grid mutations, escapes, and sixel/OSC handling.
