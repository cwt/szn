# zmux — Functional Clone Progress

Track progress toward a fully functional tmux clone.
Based on code audit as of 2026-06-21.

## Current State: 490 tests passing, single-pane interactive session works.

---

## Migration Phase Audit

| Phase | Description | Status | Tests | Notes |
|-------|-------------|--------|-------|-------|
| 0 | Scaffolding + Test Harness | ✅ Done | — | build.zig, test.zig, err.zig, log.zig |
| 1 | Grid + Colour + Screen | ✅ Done | ~90 | Cell, Grid, Screen, Colour all complete |
| 2 | Key + Session + Window + Layout | ✅ Done | ~40 | Key parse/format, Session, Window, Pane, Layout tree |
| 3 | Options + Config | ✅ Done | ~25 | Options store, config parser (set, bind, source, if-shell) |
| 4 | TTY Output Engine | ✅ Done | ~35 | Term writer, cursor, SGR, clearing, scroll region, alt screen |
| 5 | TTY Input Parsing | ✅ Done | ~25 | InputReader: keys, mouse, UTF-8, focus, paste, kitty |
| 6 | Input Escape Parser | ✅ Done | ~80 | CSI, OSC, DCS, DECSET, SGR, scroll regions, alt screen |
| 7 | Format + Status | ✅ Done | ~30 | format.zig and status.zig complete |
| 8 | Mode + Key Bindings | ✅ Done | ~40 | copy mode and key bindings structure complete |
| 9 | Client-Server IPC | ⚠️ Partial | ~30 | Protocol, socket, message reader, and dispatcher complete; integration in main loop pending |
| 10 | Commands | ⚠️ Partial | ~65 | 21 of 33 MVP commands defined; 15 functional, 6 stubs |
| 11 | Full Integration | ✅ Done | ~30 | integration.zig integration test suite complete |

**Total: 490 / 490 tests passing. Phases 0–8 and 11 complete. Phases 9 and 10 in progress.**

---

## Feature Gaps (by priority)

### P0 — Usable Daily Driver

| Feature | Effort | Description |
|---------|--------|-------------|
| Prefix key interception | Small | Detect `C-b` in stdin handler, enter prefix mode |
| Key binding dispatch | Medium | Map prefix+key → command execution |
| Pane splitting (real) | Medium | Wire layout.zig into window.zig splitPane; resize panes |
| Pane rendering (multi) | Medium | Render multiple panes with borders |
| Detach / attach | Medium | Server keeps running; client reconnects |
| IPC command protocol | Medium | Wire protocol.zig to cmd.zig dispatch in server loop |

### P1 — Proper tmux Experience

| Feature | Effort | Description |
|---------|--------|-------------|
| Config file loading | Small | Read ~/.zmux.conf at startup, apply directives |
| Mouse support | Small | Parse SGR mouse events, dispatch to pane/click-to-focus |
| Paste buffers | Small | Kill ring for copy/paste |
| Remaining commands | Large | See command list below |

### P2 — Feature Parity

| Feature | Effort | Description |
|---------|--------|-------------|
| Command prompt (`:` mode) | Medium | Interactive command input |
| Window/session chooser | Large | Tree UI for navigation |
| Hooks and notifications | Medium | session-created, pane-focus-changed, etc. |
| Environment management | Small | set-environment, show-environment |
| Pane synchronization | Small | synchronize-panes option |
| Multiple clients | Medium | Per-client state, size negotiation |
| Control mode (-CC) | Medium | IDE integration protocol |

---

## Command Implementation Status

### Implemented / Functional (15)

| Command | Alias | Status |
|---------|-------|--------|
| new-session | new | ✅ Creates session |
| kill-session | — | ✅ Kills by name |
| rename-session | — | ✅ Renames session |
| new-window | neww | ✅ Creates window |
| kill-window | killw | ✅ Kills by index |
| rename-window | — | ✅ Renames active window |
| select-window | selectw | ✅ Switches active window |
| next-window | next | ✅ Cycles forward through windows |
| previous-window | prev | ✅ Cycles backward through windows |
| last-window | last | ✅ Switches to last active window |
| send-keys | send | ✅ Writes to pane |
| select-pane | selectp | ✅ Switches active pane |
| kill-pane | killp | ✅ Removes active pane |
| rotate-window | rotatew | ✅ Rotates pane positions |
| split-window | splitw | ⚠️ Creates pane but no layout resize (partial) |

### Stubs (6)

| Command | Alias | Status |
|---------|-------|--------|
| list-sessions | ls | ⚠️ Stub (no output) |
| list-windows | lsw | ⚠️ Stub (no output) |
| list-panes | lsp | ⚠️ Stub (no output) |
| list-commands | lscm | ⚠️ Stub (no output) |
| detach-client | detach | ⚠️ Stub (no action) |
| capture-pane | capturep | ⚠️ Stub (no action) |

### Missing from MVP (12)

| Command | Priority | Notes |
|---------|----------|-------|
| attach-session | P0 | Required for detach/attach |
| switch-client | P1 | Switch between sessions |
| resize-pane | P1 | Resize pane proportions |
| swap-window | P2 | Reorder windows |
| swap-pane | P2 | Swap pane positions |
| move-window | P2 | Move window to different index |
| join-pane | P2 | Move pane between windows |
| break-pane | P2 | Break pane to new window |
| paste-buffer | P1 | Paste from kill ring |
| bind-key | P1 | Runtime key binding |
| unbind-key | P1 | Remove key binding |
| set-option | P1 | Runtime option change |
| show-options | P1 | Display current options |
| source-file | P1 | Load config file at runtime |
| copy-mode | P1 | Enter copy mode |
| find-window | P2 | Search windows by content |
| list-keys | P2 | Show key bindings |
| show-messages | P2 | Show message log |

---

## Milestones

### M1: Interactive Multi-Pane (target: usable daily driver)

- [ ] Prefix key (`C-b`) detection in main loop
- [x] Key binding table + dispatch (implemented, integration pending)
- [ ] Real pane splitting with layout resize
- [ ] Multi-pane rendering with borders
- [x] select-pane, select-window commands
- [x] Basic IPC protocol and command dispatch (implemented, server/loop integration pending)

### M2: Configurable + Scriptable

- [x] Format string engine (`#{...}` expansion)
- [x] Configurable status bar
- [ ] Config file loading at startup
- [ ] set-option, bind-key, source-file commands
- [ ] Mouse click-to-focus

### M3: Copy Mode + Buffers

- [x] Copy mode with vi/emacs keybindings
- [x] Scrollback navigation
- [x] Text selection + yank
- [ ] Paste buffer management
- [ ] capture-pane command (currently a stub)

### M4: Feature Parity

- [ ] All 33 MVP commands
- [ ] Command prompt (`:` mode)
- [ ] Multiple client support
- [ ] Hooks and notifications
- [x] Integration test harness
