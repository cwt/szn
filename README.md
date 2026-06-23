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

szn makes a different bet: xterm-256color or newer, full stop. That lets us
hardcode modern behaviour — UTF-8 box-drawing, SGR mouse, kitty keys — and skip
the entire compatibility layer. Less code, fewer surprises, and nothing left
over from 1978.

## Goals

- **Modern terminals only** — xterm-256color as the baseline, with SGR mouse
  (1006), true-colour RGB, kitty extended keys, UTF-8, OSC 8 hyperlinks, and
  sixel image support out of the box.
- **Clean architecture** — Zig's comptime, error unions, tagged unions, arena
  allocators, and slices replace C macros, `goto`-based cleanup, and manual
  memory management.
- **Zero learning curve** — tmux config files, keybindings, and the familiar
  session → window → pane model are all preserved. If you know tmux, you
  already know szn.

## Status

Still in the planning phase. Check out [MIGRATION.md](MIGRATION.md) for the
full breakdown of what's coming and when.

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

## License

[MIT](LICENSE)
