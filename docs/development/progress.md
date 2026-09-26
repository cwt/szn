---
type: project_priority
title: "szn Functional Clone Progress"
description: "Progress tracker toward a fully functional tmux clone."
status: stable
sources:
  - src/
  - build.zig.zon
verified: human-reviewed
stale_after: 2026-12-31T00:00:00Z
tags: [progress, roadmap, parity, milestones]
timestamp: 2026-09-27T01:20:00Z
---

# szn — Functional Clone Progress

Track progress toward a fully functional tmux clone.
Based on code audit as of 2026-06-21.

## Current State: 1,032 tests passing, v0.10.0 release. Hot-path performance architecture overhaul (batch chunk parser `advanceBatch`, fast-path ASCII streaming in `writeStr`, O(1) pane validity tracking `isPaneValid`, batched SGR and render output, arena format string allocations). Configurable Unicode VS16 emoji presentation width option (`variation-selector-always-wide`). Hardened Sixel graphics subsystem (containment verification, scroll-region bound anchor shifting, surviving marker cell purging, transactional placement error rollback). Stable display client pointer lifetimes (`ArrayList(*DisplayClient)`), bounded OSC 52 clipboard and IPC frame limits, race-free PTY child reaping before SIGKILL, Kitty extended keyboard release filtering, raw terminal diagnostics, and a 61-bug stability sweep (#441–#501).

---

## Migration Phase Audit

| Phase | Description | Status | Tests | Notes |
|-------|-------------|--------|-------|-------|
| 0 | Scaffolding + Test Harness | ✅ Done | — | build.zig, test.zig, log.zig (`err.zig` was removed — see bug #36) |
| 1 | Grid + Colour + Screen | ✅ Done | ~90 | Cell, Grid, Screen, Colour all complete |
| 2 | Key + Session + Window + Layout | ✅ Done | ~40 | Key parse/format, Session, Window, Pane, Layout tree |
| 3 | Options + Config | ✅ Done | ~25 | Options store, config parser (set, bind, source, if-shell) |
| 4 | TTY Output Engine | ✅ Done | ~35 | Term writer, cursor, SGR, clearing, scroll region, alt screen |
| 5 | TTY Input Parsing | ✅ Done | ~25 | InputReader: keys, mouse, UTF-8, focus, paste, kitty |
| 6 | Input Escape Parser | ✅ Done | ~80 | CSI, OSC, DCS, DECSET, SGR, scroll regions, alt screen |
| 7 | Format + Status | ✅ Done | ~30 | format.zig and status.zig complete |
| 8 | Mode + Key Bindings | ✅ Done | ~40 | copy mode and key bindings structure complete |
| 9 | Client-Server IPC | ✅ Done | ~30 | IPC protocols, unix sockets, and live client-server communication complete |
| 10 | Commands | ✅ Done | ~74 | All 49 commands registered in `CMD_TABLE` (including set-window-option / setw, copy-mode, paste-buffer, find-window, show-messages, and list-keys) |
| 11 | Full Integration | ✅ Done | ~30 | integration.zig integration test suite complete |

**Total: 1,032 / 1,032 tests passing (verified 2026-09-27). All Phases 0–11 fully complete.**

> The per-phase **Tests** column above is a snapshot taken when each phase
> landed, not a partition of the current total — later phases and audit sweeps
> added tests to earlier modules, so those figures no longer sum to 944.

---

## Feature Gaps (by priority)

### P0 — Usable Daily Driver (All Completed)

* **Prefix key interception**: ✅ Done (integrated in `Server.handleStdin`).
* **Key binding dispatch**: ✅ Done (integrated via `KeyDispatcher` and `executeAction`).
* **Pane splitting (real)**: ✅ Done (wired `layout.zig` into `Window.splitPane`).
* **Pane rendering (multi)**: ✅ Done (supported by `Display.renderAll` rendering grid splits).
* **Detach / attach**: ✅ Done (integrated with IPC socket protocols).
* **IPC command protocol**: ✅ Done (wired in `Server.handleClient` to parse and run commands).

---

## Milestones

### M1: Interactive Multi-Pane (target: usable daily driver)

- [x] Prefix key (`C-b`) detection in main loop
- [x] Key binding table + dispatch
- [x] Real pane splitting with layout resize
- [x] Multi-pane rendering with borders
- [x] select-pane, select-window commands
- [x] Basic IPC protocol and command dispatch

### M2: Configurable & Scriptable

- [x] Option stores & inheritance (Session -> Window option stores)
- [x] Load config file at startup (`~/.szn.conf` or `~/.tmux.conf`)
- [x] Config commands (`bind-key`, `unbind-key`, `set-option`, `show-options`, `source-file`, `resize-pane`)
- [x] SGR mouse reporting (1006) and click-to-focus
- [x] Escape sequence input buffering
