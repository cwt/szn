---
type: api_spec
title: "szn Client-Server IPC Protocol"
description: "Wire format for the client/server packet protocol: 5-byte length-prefixed header, message types, framing, handshake, and socket addressing."
timestamp: 2026-07-07T18:56:29Z
---

# Client-Server IPC Protocol

szn's client and server talk over a UNIX-domain socket using a simple
length-prefixed packet protocol (defined in `src/server/protocol.zig`). This
replaces tmux's imsg.

> Note: the structs are **not** `packed` in the Zig sense — `Header`/`Packet`
> are plain structs with byte-exact manual encoding (`protocol.zig:50,60`).
> AGENTS.md describes them as "packed structs" aspirationally.

## Packet header (5 bytes)

| Offset | Field | Type | Encoding |
|--------|-------|------|----------|
| 0..4 | `length` | `u32` | little-endian, **total** size incl. header |
| 4 | `msg_type` | `u8` | raw `MessageType` value |

`length` total = `5 + data.len` (`protocol.zig:96`). `Header.encode` writes
LE `u32` then the type byte (`protocol.zig:54-57`). `Packet.deserialize`
requires `buf.len >= 5` and `len == buf.len` exactly (`protocol.zig:82-93`) —
so it parses **one packet per buffer**; streaming framing is done by the
readers in §3, not by `deserialize`.

## Direction convention

A single `MessageType` enum (`protocol.zig:10-48`). `isRequest()` is
`@intFromEnum(self) < 0x80` (`protocol.zig:26-28`): `< 0x80` = client→server,
`>= 0x80` = server→client.

## Message types

### Client → Server (requests)

| Value | Variant | Payload | Status |
|-------|---------|---------|--------|
| `0x01` | `identify_term` | opaque term string (live client sends raw `"xterm-256color"`) | used; payload ignored by server |
| `0x02` | `identify_cwd` | undefined | reserved / unused |
| `0x03` | `identify_done` | undefined | reserved / unused |
| `0x04` | `command` | raw command-line string (e.g. `"new-session test"`) | used |
| `0x05` | `resize` | 8 bytes: `u32` LE width + `u32` LE height | used |
| `0x06` | `detach` | empty | used (both directions) |
| `0x07` | `shell` | undefined | reserved / unused |
| `0x08` | `stdin_data` | raw bytes from client stdin (max 4096/packet) | used |

### Server → Client (responses)

| Value | Variant | Payload | Status |
|-------|---------|---------|--------|
| `0x80` | `ready` | usually `"ok"`, or captured `response_buf` text | used |
| `0x81` | `output` | raw terminal escape bytes (rendered frame; also OSC-52 clipboard) | used |
| `0x82` | `exit` | 1 byte exit code (`u8`) | used |
| `0x83` | `err` | error message string | used |
| `0x84` | `notify` | undefined | reserved / unused |

## Key message behaviour

- **`identify_term`** — the structured `IdentifyTerm` encoder
  (`protocol.zig:107-126`, `client.zig:39-46`) is effectively dead: the live
  client sends a raw string (`main.zig:364`) and the server handler ignores
  the payload, only registering the fd as a display client (`server.zig:1838`).
- **`command`** — verbatim command line, space-separated; server parses via
  `cmd.parse` (`dispatch.zig:33`).
- **`resize`** — 8-byte LE pair, clamped to min 2×2 (`server.zig:1876`);
  sent at startup and on `SIGWINCH` (`main.zig:369-375, 416-421`).
- **`stdin_data`** — forwarded to the active pane's PTY input
  (`server.zig:1864`); sets `current_client_fd`.
- **`output`** — one rendered frame from `renderToDisplayClient`
  (`server.zig:2060-2090`); also OSC-52 clipboard forwarded to all clients.
- **`exit`** — produced by `CmdResult.stop` (e.g. `detach-client`), payload is
  a single zero byte (`dispatch.zig:84`); client does `std.process.exit(code)`.

## Framing (stream → packets)

Both streaming readers agree on the 5-byte LE-length header:

- **Server** — `MessageReader` (`message_reader.zig:15-59`): fixed 8192-byte
  buffer; `tryParse()` reads `length`, rejects `< 5` or `> 8192`, waits for a
  complete packet, returns `Packet` whose `data` points *into* the reader
  buffer; `consume()` shifts the unconsumed tail.
- **Client** — `Client.recvPacket` (`client.zig:60-95`): reads exactly the
  5-byte header, validates `len <= 1 MiB`, then reads the body. The interactive
  client also parses inline in `main.zig:448-496`.

Size-limit inconsistencies worth noting: client send cap 4096
(`client.zig:53`), client recv cap 1 MiB (`client.zig:71`), server reader cap
8192 (`message_reader.zig:16`). Only `Client.MAX_PACKET_SIZE = 1 MiB` is
named.

## Handshake / attach flow

1. Client connects via `connectToServer` (`connect.zig:18-37`).
2. Client sends `identify_term` then `resize` (w, h) — `main.zig:364-375`.
3. Client enters raw mode + alt screen, installs `SIGWINCH`.
4. Event loop: stdin → `stdin_data`; server → `output` written to stdout,
   `detach` ends the loop (`main.zig:401-498`).
5. Server on `identify_term`: appends fd to `display_clients`, replies
   `ready("ok")`, marks active pane dirty (`server.zig:1838-1848`).

There is **no per-session attach selection** in the wire protocol — the daemon
always serves its single active session. No initial-state dump either; the
server simply begins streaming `output` once a client is a display client.

## Socket path / addressing

`resolve()` in `src/socket_path.zig:17-51` tries, in order:
`$XDG_RUNTIME_DIR/szn.sock` → `$TMPDIR/szn.sock` →
`$HOME/.szn/szn.sock` (mkdir `0700` first) → `/tmp/szn-<uid>.sock`.

`src/server/socket.zig` creates the `AF_UNIX`/`SOCK_STREAM` listener
(`createListener`, `listen(128)`, cloexec), accepts, and shuts down.
