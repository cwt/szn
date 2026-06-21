# Agent Guidelines — szn

## Project Context

szn is a rewrite of tmux in Zig. The upstream C source lives in `tmux/` and
serves as the *reference implementation* for behaviour. All new code goes into
the repository root as Zig source files.

## Zig Coding Standards

### Version
Target Zig 0.16.0 (latest stable). Use `std.zig` style.

### Naming
- Types: `PascalCase` — `Session`, `Window`, `Pane`
- Functions: `camelCase` — `sessionCreate`, `paneResize`
- Variables: `lower_snake_case` — `active_window`, `last_pane`
- Allocator parameters: always called `allocator`, always first arg after `self`
- Constants: `UPPER_SNAKE_CASE` — `MAX_PANES`, `DEFAULT_SHELL`
- Files: `snake_case.zig` — `session.zig`, `tty_output.zig`

### Memory
- Always use arena allocators per session/pane lifecycle. Never `gpa.alloc`.
- Never call `allocator.destroy` — arena reset handles everything.
- Use `defer` instead of `errdefer` only when you're certain the path won't fail.
- Prefer `std.ArrayList` and slices over linked lists.

### Error Handling
- Define specific error sets per subsystem. No generic `!void` everywhere.
- Use `try` / `catch` — never ignore errors.
- Log unexpected errors with `std.log.warn` or `std.log.err`.

### Comptime
- Generate command tables, key binding tables, and option definitions at comptime.
- Use `inline for` for dispatch loops instead of function pointer tables.
- Comptime is for *generation*, not for logic.

### Terminal Handling
- Hardcode escape sequences. No terminfo.
- Emit UTF-8 box-drawing for borders. No ACS/SCS.
- Only SGR mouse (1006). No X10, no UTF-8 mouse (1005), no button-mode.
- Only kitty extended keys protocol for keyboard.

### Code Organization
- One type per file, matching the type name (e.g. `Session` → `session.zig`).
- Subsystems in directories: `tty/`, `server/`, `client/`, `cmd/`, `grid/`, `input/`.
- `main.zig` at the root.

## Design Principles

1. **Fewer features, done well.** Don't port every tmux command. Start with the
   20% that covers 80% of usage.
2. **Arena allocation over reference counting.** Panes and sessions own their
   memory. When a session goes, everything goes.
3. **Protocols over inheritance.** Client-server IPC uses a simple packet
   protocol (not imsg). Define it as packed structs.
4. **No global state.** Pass context explicitly. Use build-time dependency
   injection for testing.
5. **Don't abstract the terminal.** Hardcode modern behaviour. If a feature
   isn't universal on xterm-256color+ terminals, it doesn't ship.

## Reference Implementation

The `tmux/` directory contains the original C source. Use it to verify behaviour:

```bash
# Compare escape sequence handling
grep -rn "ESC\[" tmux/input.c

# Check option definitions
grep "\.name" tmux/options-table.c
```

Never copy C patterns into Zig. Translate intent, not syntax.
