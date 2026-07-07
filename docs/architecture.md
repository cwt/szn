---
type: architecture_guideline
title: "szn Architecture Overview"
description: "How szn is structured: process model, server event loop, session/window/pane data model, rendering, input parsing, screen/grid, and command subsystem."
timestamp: 2026-07-07T18:56:29Z
---

# Architecture Overview

szn is a from-scratch rewrite of tmux in Zig 0.16.0. It keeps tmux's
client/server shape but replaces imsg with a tiny length-prefixed packet
protocol and uses arena allocation per session/pane instead of reference
counting.

## Process model

Entry point is `src/main.zig`. A single `szn` binary is both client and
server; it decides which role to take at startup.

- `detectNested()` blocks nested szn (env `SZN` set) — `main.zig:46-48`.
- `new-session`/`new` with no socket present: the process `fork()`s. The
  **child** becomes the server daemon (`runServerDaemon`), the **parent**
  becomes the interactive client that waits for the socket and connects —
  `main.zig:124-172`.
- Plain `szn` with no args: `spawnDaemonAndAttach()` does the same fork —
  `main.zig:247-263`.
- Attaching to an already-running server (`attach`): no fork, just connect —
  `main.zig:232-243`.

> Key distinction from classic tmux: the **original process is the client**
> and the server is the forked child. The server does not spawn the client's
> attaching process.

## Server event loop

`src/server/loop.zig` is a `poll()`-based loop. `Loop` owns an
`fds: ArrayList(FdEntry)` plus reusable `pollfds`/`event_buf`
(`loop.zig:23-27`). `pollOnce` rebuilds the `pollfd[]` and calls
`std.posix.poll` (`loop.zig:62-93`). `FdEntry.udata` (`*anyopaque`) tags
which pane a PTY fd belongs to.

`Server.run()` (`server.zig:277-337`) per iteration:

- `reapZombies()` drains exited children on `SIGCHLD`.
- `tickAutoscroll()` for copy-mode mouse scroll.
- Dispatches poll events: PTY events first (`handlePtyEvent`,
  `server.zig:352-428`), then `stdin_fd`, the listener, and each client fd.

Watched fds: listener socket, each client fd, and each pane PTY master fd
(registered via `watchPanePty`, `server.zig:1797-1803`). When the last
session is gone, `loop.running = false` (`server.zig:463-465`).

## Data model

| Type | File | Notes |
|------|------|-------|
| `Session` | `session.zig:9` | Arena allocator, `windows: ArrayList(*Window)`, `active_window`, per-session `Options`. |
| `Window` | `window.zig:219` | `panes: ArrayList(*Pane)`, a binary-split `Layout` tree, options. |
| `Pane` | `window.zig:18` | `screen: Screen`, optional `pty`, optional `parser`, `dirty`, back-pointer to window. |

A pane's PTY is created in `Pane.spawn()` (`window.zig:63-86`) via
`Pty.open()` + `pty.spawn(...)`, which `fork()`s the **shell child**
(`pty.zig:137-164`) — not the client. The pane id is passed to the child via
the `SZN`/`SZN_PANE` env vars. The PTY master fd is registered with the loop.

## Rendering

`src/server/render.zig` holds `Display`, the server-side renderer that emits
escape sequences to a client fd (or captures into a buffer for one `.output`
packet).

- `renderAll()` (`render.zig:117-241`) builds a merged grid (last row reserved
  for the status bar), copies each pane's grid (including scrollback, offset
  by copy-mode scroll), draws UTF-8 box borders, and positions the cursor.
- `renderContent()` (`render.zig:332-515`) keeps `last_cells` per display
  client and skips unchanged cells (incremental diff).
- `renderSixelImages()` (`render.zig:603-618`) forwards each pane's raw sixel
  DCS bytes verbatim.

`src/tty/tty.zig` provides `Term`, a lower-level emitter with cached
`cx/cy/fg/bg/attrs` to minimize redundant escapes; used in tests and as the
conceptual building block.

## Input parsing

`InputParser` in `src/input.zig` is a byte-at-a-time state machine
(`State` enum at `input.zig:35-54`: ground, ESC, CSI, OSC, and a rich DCS
set including sixel). Attached per pane (`window.zig:88-100`) and fed by
`Pane.feedPty`.

It handles cursor moves, erase, insert/delete line/char, scroll,
`DECSET`/`DECRST`, SGR, terminal queries (DA1/DA2, DSR, DECRQM,
`XTSMGRAPHICS` sixel negotiation), sixel DCS (accumulated then
`Screen.addSixelImage`), OSC title/clipboard, and kitty keyboard (`CSI u`).

## Screen & grid

- `Cell` (`grid.zig:25`): `packed struct(u128)` — `char: u21`, `comb1`/`comb2`
  combining codepoints (`u13`), `attr: Attr`, `fg`/`bg: Colour`, `is_padding`.
- `Attr` (`grid.zig:10`): `packed struct(u16)` of boolean style flags.
- `Colour` (`colour.zig:11`): `packed struct(u32)` — `tag: enum(u8)` + `u24`.
- `Grid` (`grid.zig:68`): ring-buffer `lines` (+ `start_index`) plus
  `history` (scrollback, `history_limit = 2000`). `GridLine` = `cells` +
  `dirty` + `wrapped` (for reflow).
- `Screen` (`screen.zig:67`): wraps a `Grid` + optional `alt_grid`, cursor,
  saved cursor, `Mode` (`packed struct(u32)`), `copy_mode`, `sixel_images`,
  kitty-kbd state.
- `SixelImage` (`screen.zig:13`): stores the raw DCS bytes + anchor position.

## Command subsystem

Commands are described by `CmdEntry` (`cmd.zig:15`) and assembled into a
**comptime** table in `cmdTable()` (`cmd.zig:1433-1486`) from the
`commands.*` instances. `parse`/`lookup` tokenize and validate args;
`dispatchCommand` (`dispatch.zig:26`) calls `exec(server)` and returns a
`DispatchResult` (`.ready`/`.err`/`.exit`/`.wait`). Handlers operate directly
on `*Server`.

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
