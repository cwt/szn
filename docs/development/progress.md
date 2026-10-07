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
timestamp: 2026-09-27T09:45:00Z
---

# szn — Functional Clone Progress

Track progress toward a fully functional tmux clone.
Based on code audit as of 2026-06-21.

## Current State: 1,064 tests, v0.10.0 release. Hot-path performance architecture overhaul (batch chunk parser `advanceBatch`, fast-path ASCII streaming in `writeStr`, O(1) pane validity tracking `isPaneValid`, batched SGR and render output, arena format string allocations). Configurable Unicode VS16 emoji presentation width option (`variation-selector-always-wide`). Hardened Sixel graphics subsystem (containment verification, scroll-region bound anchor shifting, surviving marker cell purging, transactional placement error rollback). Stable display client pointer lifetimes (`ArrayList(*DisplayClient)`), bounded OSC 52 clipboard and IPC frame limits, race-free PTY child reaping before SIGKILL, Kitty extended keyboard release filtering, raw terminal diagnostics, a 70-bug stability sweep (#441–#510), and the #511–#531 audit sweep.

Thai & Lao text rendering & reflow correctness sweep (#502–#505, SARA AM diff-cache cluster repair): compound-vowel cluster integrity (`เ-าะ` patterns no longer split at reflow boundaries), atomic state transitions for runtime `libthai` loading in `src/thai.zig`, and two-way SARA AM diff repair (`Display.renderContent` pre-pass covering Thai `U+0E33` and Lao `U+0EB3` with deduplicated `resolveCell` and isolated `thai.isSaraAm`).

**Dual-toolchain support (2026-10-05):** szn now compiles on **both Zig 0.16.0
and 0.17.0** from one source tree. Zig 0.17 removed or renamed a number of std
APIs; each was replaced with a spelling that exists in *both* releases
(`bufPrintSentinel`, `meta.fieldNames`, `mem.zeroes`, `allocSentinel`,
`ascii.eqlIgnoreCase`, `= .empty`), and the two cases with no shared form
(`Allocator.dupeZ`, `std.ascii.indexOfIgnoreCase`) plus the optimize-tag check
were routed through a new `src/compat.zig`. The only comptime version branches
are two `@hasField` gates in `build.zig` (`Build.build_root`, `.Debug` tag).
`zig build test` passes **1064/1064 on 0.16.0 and on 0.17.0** (1063 passing, 1 skipped).

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

**Total: 1,063 / 1,064 tests passing (1 skipped; verified 2026-10-07, Zig 0.16.0, `-Doptimize=ReleaseFast`). All Phases 0–11 fully complete.**

> The per-phase **Tests** column above is a snapshot taken when each phase
> landed, not a partition of the current total — later phases and audit sweeps
> added tests to earlier modules, so those figures do not sum to the current
> total.

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
