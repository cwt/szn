# szn

A modern terminal multiplexer forked from [tmux](https://github.com/tmux/tmux), rewritten in [Zig](https://ziglang.org).

## Why

tmux is battle-tested but carries decades of terminal compatibility baggage.
szn keeps only what matters for modern terminals — no terminfo, no ACS,
no X10 mouse, no HP-UX support — and expresses the rest in idiomatic Zig.

## Goals

- **Modern terminal only**: xterm-256color as baseline. SGR mouse (1006), RGB colour,
  kitty extended keys, UTF-8, hyperlinks (OSC 8), sixel images.
- **Clean architecture**: Zig's comptime, error unions, tagged unions, arena allocators,
  and slice-based data structures replace C macros, goto cleanup, and manual memory.
- **Same UX**: tmux config files, keybindings, session/window/pane model — zero
  learning curve for tmux users.

## Status

Planning phase. See [MIGRATION.md](MIGRATION.md) for the full breakdown.

## License

Same as tmux — [ISC](COPYING).
