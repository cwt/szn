---
type: architecture_guideline
title: "szn Architecture Overview"
description: "How szn is structured: process model, server event loop, session/window/pane data model, rendering, input parsing, screen/grid, and command subsystem."
timestamp: 2026-08-30T16:20:00Z
---

# Architecture Overview

szn is a from-scratch rewrite of tmux in Zig 0.16.0. It keeps tmux's
client/server shape but replaces imsg with a tiny length-prefixed packet
protocol and uses arena allocation per session/pane instead of reference
counting.

> **Referencing convention:** this document names **symbols and files**, not
> line numbers. Line citations drift every time a file is edited — an earlier
> revision of this page carried ~25 of them and nearly all had rotted. To find
> a symbol, grep for its name.

## Process model

Entry point is `src/main.zig`. A single `szn` binary is both client and
server; it decides which role to take at startup.

- `detectNested()` blocks nested szn (env `SZN` set).
- `new-session`/`new` with no socket present: the process `fork()`s. The
  **child** becomes the server daemon (`runServerDaemon`), the **parent**
  becomes the interactive client that waits for the socket and connects.
- Plain `szn` with no args: `spawnDaemonAndAttach()` does the same fork.
- Attaching to an already-running server (`attach`): no fork, just connect.

> Key distinction from classic tmux: the **original process is the client**
> and the server is the forked child. The server does not spawn the client's
> attaching process.

## Server event loop

`src/server/loop.zig` is a `poll()`-based loop. `Loop` owns an
`fds: ArrayList(FdEntry)` plus reusable `pollfds`/`event_buf`. `pollOnce`
rebuilds the `pollfd[]` and calls `std.posix.poll`. `FdEntry.udata`
(`*anyopaque`) tags which pane a PTY fd belongs to.

`Server.run()` per iteration:

- `reapZombies()` drains exited children on `SIGCHLD`.
- `tickAutoscroll()` for copy-mode mouse scroll.
- Dispatches poll events: PTY events first (`handlePtyEvent`), then
  `stdin_fd`, the listener, and each client fd.

Watched fds: listener socket, each client fd, and each pane PTY master fd
(registered via `watchPanePty`). When the last session is gone the loop stops
(`loop.running = false`).

## Data model

| Type | File | Notes |
|------|------|-------|
| `Session` | `session.zig` | Arena allocator, `windows: ArrayList(*Window)`, `active_window`, per-session `Options`. |
| `Window` | `window.zig` | `panes: ArrayList(*Pane)`, a binary-split `Layout` tree, options. |
| `Pane` | `window.zig` | `screen: Screen`, optional `pty`, optional `parser`, `dirty`, back-pointer to window. |

A pane's PTY is created in `Pane.spawn()` via `Pty.open()` + `Pty.spawn(...)`,
which `fork()`s the **shell child** — not the client. The pane id is passed to
the child via the `SZN`/`SZN_PANE` env vars. The PTY master fd is registered
with the loop.

## Rendering

`src/server/render.zig` holds `Display`, the server-side renderer that emits
escape sequences to a client fd (or captures into a buffer for one `.output`
packet).

- `renderAll()` builds a merged grid (last row reserved for the status bar),
  copies each pane's grid (including scrollback, offset by copy-mode scroll),
  draws UTF-8 box borders, and positions the cursor.
- `renderContent()` keeps `last_cells` per display client and skips unchanged
  cells (incremental diff).
- `renderSixelImages()` forwards each pane's raw sixel DCS bytes verbatim, but
  only for images that are *fully contained* in the pane (others are erased).
  Cell↔pixel conversion uses the measured cell size; when a sixel is added
  before that is known, `Screen.addSixelImage` buffers it (`pending_sixel`) and
  the server pauses the pane's PTY feed until the `cell_size` reply arrives
  (`#204`).

`src/tty/tty.zig` provides `Term`, a lower-level emitter with cached
`cx/cy/fg/bg/attrs` to minimize redundant escapes; used in tests and as the
conceptual building block.

## Input parsing

`InputParser` in `src/input.zig` is a byte-at-a-time state machine (see its
`State` enum: ground, ESC, CSI, OSC, and a rich DCS set including sixel).
Attached per pane and fed by `Pane.feedPty`.

It handles cursor moves, erase, insert/delete line/char, scroll,
`DECSET`/`DECRST`, SGR, terminal queries (DA1/DA2, DSR, DECRQM,
`XTSMGRAPHICS` sixel negotiation), sixel DCS (accumulated then
`Screen.addSixelImage`, which buffers the image in `pending_sixel` until a
measured cell size is known — see `cell_size_needs_refresh`), OSC
title/clipboard, and kitty keyboard (`CSI u`).

## Screen & grid

- `Cell` (`grid.zig`): `packed struct(u128)` — `char: u21`, `comb1`/`comb2`
  combining codepoints (`u13`), `attr: Attr`, `fg`/`bg: Colour`, `is_padding`.
- `Attr` (`grid.zig`): `packed struct(u16)` of boolean style flags.
- `Colour` (`colour.zig`): `packed struct(u32)` — `tag: enum(u8)` + `u24`.
- `Grid` (`grid.zig`): ring-buffer `lines` (+ `start_index`) plus `history`
  (scrollback, `history_limit = 2000`). `GridLine` = `cells` + `dirty` +
  `wrapped` (for reflow).
- `Screen` (`screen.zig`): wraps a `Grid` + optional `alt_grid`, cursor, saved
  cursor, `Mode` (`packed struct(u32)`), `copy_mode`, `sixel_images`,
  kitty-kbd state.
- `SixelImage` (`screen.zig`): stores the raw DCS bytes + anchor position.

## Command subsystem

Commands are described by `CmdEntry` (`src/cmd/cmd.zig`) and assembled into a
**comptime** table (`CMD_TABLE`, exposed through `cmdTable()`) from the
`commands.*` instances — 48 entries as of 2026-08-30. `parse`/`lookup`
tokenize and validate args; `dispatchCommand` (`src/server/dispatch.zig`)
calls `exec(server)` and returns a `DispatchResult`
(`.ready`/`.err`/`.exit`/`.wait`). Handlers operate directly on `*Server`.

## Directory layout

- `src/` root — core modules: `main`, `session`, `window`, `screen`, `grid`,
  `input`, `colour`, `char_width`, `key`, `key_binding`, `options`, `cfg`,
  `layout`, `choose`, `mode_copy`, `clock`, `buffer`, `format`, `status`,
  `thai`, `socket_path`, `log`, `integration`.
- `src/server/` — `server`, `loop`, `protocol`, `socket`, `pty`,
  `message_reader`, `dispatch`, `render`.
- `src/client/` — `client`, `connect`, `raw` (termios raw mode).
- `src/tty/` — `tty`, `tty_key` (byte→`Event` incl. SGR mouse), `fd_writer`.

## Design principles (from `AGENTS.md`)

- Arena allocation per session/pane lifecycle; never `allocator.destroy`.
- No global state — context passed explicitly through `Server`/`Screen`/`Pane`.
- Protocols over inheritance; IPC is a simple packet protocol, not imsg.
- Comptime command/key-binding/option tables; hardcode modern terminal
  behaviour (no terminfo, SGR mouse 1006, kitty keyboard).
