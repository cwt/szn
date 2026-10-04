# Agent Guidelines — szn

## Project Context

szn is a rewrite of tmux in Zig. The upstream C source lives in `tmux/` and
serves as the *reference implementation* for behaviour. All new code goes into
the repository root as Zig source files.

## Zig Coding Standards

### Version
Target **Zig 0.16.0 and Zig 0.17.0** — the source must compile on both. Use
`std.zig` style. Zig 0.17 removed several std APIs, so prefer the subset that
exists in both releases, and put anything genuinely version-specific in
`src/compat.zig` (see *Cross-version compatibility* below).

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
- Subsystems in directories: `src/tty/`, `src/server/`, `src/client/`, `src/cmd/`.
- Core modules at `src/` root: `grid.zig`, `input.zig`, `screen.zig`, `session.zig`, `window.zig`, etc.
- `src/main.zig` entry point.
- `src/compat.zig` — cross-toolchain shims only (see below).

### Cross-version compatibility
szn builds on Zig 0.16.0 **and** 0.17.0 from one source tree. Two rules:

1. **Prefer APIs present in both releases.** Do not adopt a 0.17-only
   replacement for something 0.16 also needs.
2. **Confine version branches.** Zig-version gates live only in `build.zig`
   (comptime `@hasField`); runtime-visible shims live only in `src/compat.zig`.
   Never scatter *version* checks through the rest of the source. (The
   `@hasField(c.sockaddr.un, "len")` checks in `client/connect.zig`,
   `server/socket.zig` and `server/server.zig` are pre-existing **OS-ABI**
   gates, not version gates — leave them where they are.)

Portable spellings already in use:

| Removed / changed in 0.17 | Use instead |
|---|---|
| `Allocator.dupeZ` | `compat.dupeZ` |
| `std.fmt.bufPrintZ` | `std.fmt.bufPrintSentinel(..., 0)` |
| `std.meta.fields(T)[i].name` | `std.meta.fieldNames(T)` |
| `std.ascii.indexOfIgnoreCase` | `compat.indexOfIgnoreCase` |
| `[_]T{v} ** N` array repetition | `std.mem.zeroes` / comptime `@memset` |
| `.Debug` optimize tag | `compat.is_debug_build` |

`zig build test` must pass on both toolchains (1042 tests). The `.Debug` /
`OptimizeMode` spellings are deprecated in 0.17 and slated for removal after
0.18.0 — expect to revisit the `build.zig` gates at that point.

## Design Principles

1. **Fewer features, done well.** Don't port every tmux command. Start with the
   20% that covers 80% of usage.
2. **Arena allocation over reference counting.** Panes and sessions own their
   memory. When a session goes, everything goes.
3. **Protocols over inheritance.** Client-server IPC uses a simple packet
   protocol (not imsg). Define it using plain structs with manual serialization
   to guarantee byte-exact layout.
4. **Minimize global state.** Pass context explicitly. Use build-time dependency
   injection for testing. There are three documented exceptions, all
   deliberate:
   * **Async-signal handler flags** — `sigchldFlag` (`src/server/server.zig`),
     `sigwinchFlag` and `sighupFlag` (`src/main.zig`). A POSIX signal handler
     may only touch `volatile sig_atomic_t` objects, so these *cannot* be
     threaded through context.
   * **The lazily-loaded `libthai` handle** — `libthai_instance` and
     `libthai_state` (`src/thai.zig`), initialized once behind an atomic
     state machine (bug #504).
   * **Logger state** — `log_fd`, `log_fd_failed`, `log_enabled`,
     `runtime_log_level` (`src/log.zig`). The fd is atomic so the guard and the
     guarded value share a discipline (bug #510); folding the rest into a
     `Logger` passed by pointer is the intended follow-up.

   `char_width`'s override tables are also module globals, but they are now
   *honestly* server-scoped rather than pretending to be per-session: see
   `options.isServerScoped` and bug #506. Treat "no global state" as a
   default to defend, not an invariant to assume — check `rg -n '^var ' src/`
   before concluding a subsystem is context-free.
5. **Don't abstract the terminal.** Hardcode modern behaviour. If a feature
   isn't universal on xterm-256color+ terminals, it doesn't ship.
6. **Single-session attachment.** The IPC protocol and display client connection design are deliberately simple. A connected client always attaches to the global active session (the first session in the list), and there is no protocol support for specifying a target session to attach to. This matches the single active session architecture.

## Documentation

- `docs/text_reflow.md` — text reflow design and algorithms
- `docs/development/` — migration plan, bug tracker, dev lessons
- `docs/development/progress.md` — implementation status tracker
- `README.md` — project overview and usage
