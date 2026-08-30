---
type: api_spec
title: "szn Client-Server IPC Protocol"
description: "Wire format for the client/server packet protocol: 5-byte length-prefixed header, message types, framing, handshake, and socket addressing."
timestamp: 2026-08-30T16:20:00Z
---

# Client-Server IPC Protocol

szn's client and server talk over a UNIX-domain socket using a simple
length-prefixed packet protocol (defined in `src/server/protocol.zig`). This
replaces tmux's imsg.

> **Referencing convention:** this document names **symbols and files**, not
> line numbers. Line citations rot on every edit — an earlier revision carried
> 21 of them and all but two had drifted. Grep for the symbol name instead.

> Note: the structs are **not** `packed` in the Zig sense — `Header`/`Packet`
> are plain structs with byte-exact manual encoding, to guarantee layout
> stability. `MessageType` is `enum(u8)`.

## Packet header (5 bytes)

| Offset | Field | Type | Encoding |
|--------|-------|------|----------|
| 0..4 | `length` | `u32` | little-endian, **total** size incl. header |
| 4 | `msg_type` | `u8` | raw `MessageType` value |

`length` total = `5 + data.len`. `Header.encode` writes LE `u32` then the type
byte. `Packet.deserialize` requires `buf.len >= 5` and `buf.len >= len`, so it
parses the first packet in the buffer (extra trailing data is ignored);
streaming framing is done by the readers in §4.

`Packet.make` keeps the header and body consistent by truncating the body to
`maxInt(u32) - 5` rather than clamping only the declared length (`#389`).

## Direction convention

A single `MessageType` enum. `isRequest()` is `@intFromEnum(self) < 0x80`:
`< 0x80` = client→server, `>= 0x80` = server→client. `fromByte()` maps a wire
byte to a variant and returns `null` for anything unassigned, so unknown
message types are rejected rather than coerced.

## Message types

### Client → Server (requests)

| Value | Variant | Payload | Status |
|-------|---------|---------|--------|
| `0x01` | `identify_term` | opaque term string (live client sends raw `"xterm-256color"`) | used; payload ignored by server |
| `0x04` | `command` | raw command-line string (e.g. `"new-session test"`) | used |
| `0x05` | `resize` | 8 bytes: `u32` LE width, then `u32` LE height | used |
| `0x06` | `detach` | empty | used (both directions) |
| `0x08` | `stdin_data` | raw bytes from client stdin (max 4096/packet) | used |
| `0x09` | `cell_size` | 8 bytes: `u32` LE `cell_height_px`, then `u32` LE `cell_width_px` | used |
| `0x0A` | `redraw` | empty | used — reset this client's diff state |

The `0x02`/`0x03`/`0x07` slots (`identify_cwd`, `identify_done`, `shell`) were
retired and are no longer part of the enum; `fromByte()` returns `null` for
them.

### Server → Client (responses)

| Value | Variant | Payload | Status |
|-------|---------|---------|--------|
| `0x80` | `ready` | usually `"ok"`, or captured `response_buf` text | used |
| `0x81` | `output` | raw terminal escape bytes (rendered frame; also OSC-52 clipboard) | used |
| `0x82` | `exit` | 1 byte exit code (`u8`) | used |
| `0x83` | `err` | error message string | used |
| `0x84` | `request_cell_size` | empty | used |
| `0x85` | `client_log` | path for the client's log (empty = logging disabled) | used |

## Key message behaviour

- **`identify_term`** — the payload is a raw string (e.g. `"xterm-256color"`).
  The server handler ignores the payload and only registers the file
  descriptor as a display client.
- **`command`** — verbatim command line, space-separated; server parses via
  `cmd.parse` (`src/cmd/cmd.zig`).
- **`resize`** — 8-byte LE pair (width then height), each clamped to
  `2..4096`; sent at startup and on `SIGWINCH`.
- **`stdin_data`** — forwarded to the active pane's PTY input; sets
  `current_client_fd`.
- **`cell_size`** — measured terminal cell dimensions from the display
  client's `CSI 14 t` (XTWINOPS) query. Payload is `u32` LE `cell_height_px`
  then `u32` LE `cell_width_px`. The server stores these on `Server`
  (`cell_px_height`/`cell_px_width`) and applies them to every `Screen` via
  `applyCellSizeToAllScreens`; a terminal property, so the same value holds
  for all panes. Replaces the discarded startup query so sixel cell↔pixel
  conversion is correct even when launched via `alacritty -e szn`.
- **`request_cell_size`** — server→client nudge telling the display client to
  run `CSI 14 t`, parse the response, and reply with a `cell_size` message.
  Sent just before a render whenever a sixel was added and the size is
  stale/unknown (driven by `needs_cell_size_refresh`).
- **`redraw`** — the client dropped queued output while its downstream pty was
  applying backpressure (`#298`); resets that client's `last_cells` diff
  baseline so the next render is a full repaint.
- **`client_log`** — the server forwards the configured client log path, since
  the client never reads the server config. Empty payload means client logging
  is off.
- **`output`** — one rendered frame from `renderToDisplayClient`; also OSC-52
  clipboard forwarded to all clients.
- **`exit`** — produced by `CmdResult.stop` (e.g. `detach-client`), payload is
  a single exit-code byte; client does `std.process.exit(code)`.

## Framing (stream → packets)

Both streaming readers agree on the 5-byte LE-length header:

- **Server** — `MessageReader` (`src/server/message_reader.zig`): fixed buffer
  of size `protocol.MAX_CLIENT_PACKET_SIZE` (8 KiB); `tryParse()` reads
  `length`, rejects `< 5` or `> 8192`, waits for a complete packet, returns a
  `Packet` whose `data` points *into* the reader buffer; `consume()` shifts
  the unconsumed tail.
- **Client** — `Client.recvPacket` (`src/client/client.zig`): reads exactly
  the 5-byte header, validates the length, then reads the body. The
  interactive client also parses inline in `main.zig`.

Size limits are unified using:
- `protocol.MAX_PACKET_SIZE = 16 MiB` (maximum server-to-client output packet
  size; must fit a large sixel frame).
- `protocol.MAX_CLIENT_PACKET_SIZE = 8 KiB` (maximum client-to-server
  command/stdin packet size).

`validPacketLength()` (`#375`) validates a wire-declared length *before* the
reader waits for the body, so a corrupted or hostile length can never pin the
reader's buffer forever.

## Handshake / attach flow

1. Client connects via `connectToServer` (`src/client/connect.zig`).
2. Client sends `identify_term` then `resize` (w, h).
3. Client enters raw mode + alt screen, installs `SIGWINCH`.
4. Event loop: stdin → `stdin_data`; server → `output` written to stdout,
   `detach` ends the loop.
5. Server on `identify_term`: appends fd to `display_clients`, replies
   `ready("ok")`, marks active pane dirty.

There is **no per-session attach selection** in the wire protocol — the daemon
always serves its single active session. No initial-state dump either; the
server simply begins streaming `output` once a client is a display client.

> **Cell-size discovery is on-demand, not at startup.** A `CSI 14 t` query
> fired during `alacritty -e szn` startup returns wrong dimensions, so szn
> never queries at boot. Instead, when the first sixel is added the server
> sends `request_cell_size`; the client queries and replies `cell_size`
> (`0x09`), which the server applies to every screen. Until that reply lands,
> a sixel is **buffered** (`Screen.pending_sixel`) and the pane's PTY feed is
> paused so the shell prompt can't race the measurement.

## Socket path / addressing

`resolve()` in `src/socket_path.zig` tries, in order:
`$XDG_RUNTIME_DIR/szn.sock` → `$TMPDIR/szn.sock` →
`$HOME/.szn/szn.sock` (mkdir `0700` first) → `/tmp/szn-<uid>.sock`.

`src/server/socket.zig` creates the `AF_UNIX`/`SOCK_STREAM` listener
(`createListener`, `listen(128)`, cloexec), accepts, and shuts down. It probes
with `connect()` before unlinking a stale socket so a live server's endpoint
is never stolen, and forces `0700` on the socket path (`#378`).

> Because the default path is global, tests that bind it must not run
> concurrently — see the stale-socket note in
> [Build, Run, and Test](build-run.md#stale-socket-makes-3-tests-fail).
