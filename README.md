# szn

A modern terminal multiplexer inspired by [tmux](https://github.com/tmux/tmux),
rewritten from scratch in [Zig](https://ziglang.org).

## Why the name?

The name traces a fun lineage through multiplexer history:

**GNU Screen** → **scn** (shortened) → **szn** — where the `c` became `z` to
nod at Zig, just like tmux was born from C roots and szn is its Zig successor.

## Why szn?

tmux is great — but open its source and you'll find it's also quietly keeping
the lights on for terminals that haven't been relevant since the 1990s. It
queries a terminfo database at startup (a compatibility layer invented when
hundreds of incompatible terminal *hardware* models existed), falls back to
VT100 ACS line-drawing for terminals that can't speak UTF-8, juggles four
different mouse protocols on every launch, and ships dedicated shims for HP-UX,
AIX, and Solaris going all the way back to version 2.0. There's even a
workaround in there for a PuTTY 0.63 scroll-wheel bug.

None of that is a criticism — it's what made tmux run everywhere. But if you're
only targeting modern terminals, you're carrying all that weight for nothing.

szn makes a different bet: your display terminal speaks xterm-256color or
newer, full stop. That lets us hardcode modern behaviour — UTF-8 box-drawing,
SGR mouse, kitty keys — and skip the entire compatibility layer. Inside panes,
programs see `TERM=tmux-256color` (just like tmux), with szn translating between
the two. Less code, fewer surprises, and nothing left over from 1978.

## Goals

- **Modern terminals only** — xterm-256color as the display baseline. Inside
  panes, programs run under `TERM=tmux-256color`. SGR mouse (1006), true-colour
  RGB, kitty extended keys, UTF-8, OSC 8 hyperlinks, and sixel image support
  are available out of the box.
- **Pragmatic mouse forwarding** — szn speaks SGR mouse (1006) natively, but
  also forwards legacy `\x1b[M` 3-byte format when a program only enables basic
  mouse mode (1000/1002). This keeps SGR as the default while tolerating
  programs whose terminfo lacks the `XM` capability. Use
  `set -g default-terminal xterm-256color` in your config if you need the old
  behaviour.
- **Clean architecture** — Zig's comptime, error unions, tagged unions, arena
  allocators, and slices replace C macros, `goto`-based cleanup, and manual
  memory management.
- **Zero learning curve** — tmux config files, keybindings, and the familiar
  session → window → pane model are all preserved. If you know tmux, you
  already know szn.

## Status

All core development phases (Phases 0 to 11) are fully implemented and complete. We have a robust, functional Zig terminal multiplexer featuring:
- High-performance grid engine with arena-allocated session/pane lifecycles.
- Client-server IPC over Unix sockets.
- 33+ MVP commands matching standard tmux behavior (including pane resizing, layout splits, and copying/pasting).
- Standard VT100 wrap-pending and Background Color Erase (BCE) support for accurate rendering.
- Full multi-pane layouts, interactive copy mode, status bars, and config parsing (`.szn.conf`).
- **Advanced Text Reflow** — automatically rewraps text on pane resizing, respecting CJK characters, combining marks, and Thai cluster integrity (including an $O(1)$ syllable backtracking algorithm). See [TEXT_REFLOW.md](TEXT_REFLOW.md) for full design details.
- **649 unit and integration tests passing.**

### Performance

szn is designed to be lean:

- **Startup:** ~7.5ms from launch to prompt (competitive with tmux's ~8.1ms).
- **Memory:** ~2 MB RSS idle — roughly half of tmux's ~4 MB.
- **Binary size:** 604 KB stripped (x86-64 Linux), 488 KB on macOS.

A hyperfine-based benchmark suite is included at [`bench.sh`](bench.sh) for tracking these metrics.

Check out [PROGRESS.md](PROGRESS.md) for the full migration and feature breakdown.

## Building & Installation

To build and run tests:

```bash
zig build
zig build test
```

To install the output binary to a specific path (for example, `~/.local/bin`):

```bash
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

## Usage

To start a new session (this automatically spawns the background server daemon if not already running and attaches to it):

```bash
szn
```

To attach to an existing running session:

```bash
szn attach
```

To list all available subcommands and get help:

```bash
szn help
szn help <command>
```

For example, to split the active window vertically or horizontally:

```bash
szn split-window -v
szn split-window -h
```

## Debug Logging

**Debug logging is disabled by default for user privacy.** szn does not write
any log output unless explicitly configured.

To enable it, add one of these lines to your `~/.szn.conf`:

```
set -g log-file default
set -g log-file /path/to/custom/log
```

`default` writes to `$XDG_STATE_HOME/szn/szn.log` (usually
`~/.local/state/szn/szn.log`).

## License

[MIT](LICENSE)
