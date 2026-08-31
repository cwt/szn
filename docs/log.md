---
type: log
title: "szn Docs Update Log"
description: "Chronological log of modifications to the szn OKF documentation bundle."
timestamp: 2026-08-31T00:00:00Z
---

# Documentation Bundle Log

This file tracks all modifications, extensions, and updates to the `szn` documentation bundle in chronological order.

| Timestamp | Document | Action | Description |
| 2026-08-31T07:05:00Z | [441.md](development/bugs/441.md) | Created | Filed and resolved bug #441 for status cache invalidation lag, auto-rename and OSC title triggers, and pane switch invalidation. |
| 2026-08-31T06:45:00Z | [v0.9.1.md](releases/v0.9.1.md) | Created | Created release notes for v0.9.1 hotfix (global window status format routing, status cache invalidation on active window change, single-quoted format strings, and per-window format resolution). |
| 2026-08-31T06:45:00Z | [index.md](releases/index.md), [README.md](releases/README.md) | Updated | Added v0.9.1 to releases index and README. |
| 2026-08-31T06:45:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count to 969; documented v0.9.1 hotfix release and 49 commands. |
| 2026-08-31T06:45:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.9.1. |
| 2026-08-31T06:35:00Z | [440.md](development/bugs/440.md) | Created | Filed and resolved bug #440 for global window status format option routing and status cache freeze. |
| 2026-08-31T00:00:00Z | [v0.9.0.md](releases/v0.9.0.md) | Created | Created release notes for v0.9.0 (configurable scrollback history, zero-allocation ring buffer, runtime log control, command line quoting, and 44-bug stability sweep). |
| 2026-08-31T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.9.0 to releases index. |
| 2026-08-31T00:00:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count to 959; documented v0.9.0 release. |
| 2026-08-31T00:00:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.9.0. |
| 2026-08-30T16:20:00Z | [architecture.md](architecture.md) | Updated | Rewrote to cite symbols instead of line numbers; ~25 line citations had all drifted (e.g. `Server.run` was documented at server.zig:277, actually 605). Added a referencing-convention note. |
| 2026-08-30T16:20:00Z | [ipc-protocol.md](ipc-protocol.md) | Updated | Corrected `MAX_PACKET_SIZE` from 1 MiB to the actual 16 MiB; added the missing `redraw` (0x0A) and `client_log` (0x85) message types; retired the deleted 0x02/0x03/0x07 slots; documented `validPacketLength` (#375) and `Packet.make` truncation (#389); replaced 21 stale line citations with symbol names. |
| 2026-08-30T16:20:00Z | [concepts.md](concepts.md) | Updated | Removed 8 stale line citations in favour of file+symbol references. |
| 2026-08-30T16:20:00Z | [build-run.md](build-run.md) | Updated | Corrected the test count from ~730 to 944; fixed three stale `build.zig` citations; documented the stale-socket caveat that makes 3 tests fail on re-runs; corrected `log-file` to `server-log-file`. |
| 2026-08-30T16:20:00Z | [BUGS.md](development/bugs/index.md) | Updated | Regenerated both summary tables from frontmatter: severity rows previously summed to 422 while claiming 426 (actual 425; HIGH 103→105, LOW 100→102); status Fixed/Resolved 405→404, False Positive 18→19. Normalised row #247's status label and corrected the stale "all OPEN" note for #395–#427. |
| 2026-08-30T16:20:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Test count 927→944 (verified); command count 33+→48; removed `err.zig` from the Phase 0 file list; noted that per-phase test figures are historical snapshots rather than a partition of 944. |
| 2026-08-30T16:20:00Z | [README.md](../README.md) | Updated | Test count 927→944, command count 47→48, plus a caveat about the stale `$TMPDIR/szn.sock` breaking 3 tests on re-runs. |
| 2026-08-30T16:20:00Z | [MIGRATION.md](development/MIGRATION.md) | Updated | Flagged the Phase 0 file list as historical and noted that `src/err.zig` was removed (bug #36). |
| 2026-08-30T16:20:00Z | [index.md](releases/index.md), [TEXT_REFLOW.md](TEXT_REFLOW.md), [bug 343](development/bugs/343.md) | Updated | Refreshed frontmatter timestamps that lagged their last modification. |
| 2026-08-30T00:00:00Z | [bugs 395-426](development/bugs/) | Created | Filed 32 new bug entries (#395-#426) from the 2026-08-30 deep-audit sweep: 3 CRITICAL (Pty.spawn double-free, border-cache cross-allocator free, format empty-pattern server abort), 6 HIGH, 14 MEDIUM, 9 LOW. |
| 2026-08-30T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added #395-#426 rows, bumped severity/status totals (425 entries). |
| 2026-08-24T00:00:00Z | [v0.8.2.md](releases/v0.8.2.md) | Created | Created release notes for v0.8.2 (stability, memory hardening, terminal emulation fidelity, and UX polish). |
| 2026-08-24T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.2 to releases index. |
| 2026-08-24T00:00:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count to 927; documented v0.8.2 release. |
| 2026-08-24T00:00:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.8.2. |
| 2026-08-09T00:00:00Z | [v0.8.1.md](releases/v0.8.1.md) | Created | Created release notes for v0.8.1. |
| 2026-08-09T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.1 to releases index. |
| 2026-08-09T00:00:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.8.1. |
| 2026-08-03T07:30:00Z | bugs #300/#303/#304/#305/#307/#309/#310 | Updated | Documented corrected fixes: #309 status-line double-free crash, #303 behind_count disconnect leak, #304/#307 generation counter now bumped by cmdSetOption, #300 auto-rename 1 s rate limit, #305 valid-flag caveat. |
| 2026-08-03T07:30:00Z | [bugs/index.md](development/bugs/index.md) | Updated | Marked #300–#310 statuses (7 fixed, #306/#308 false positive), removed duplicate #310 row, kept counts (293 fixed / 14 FP / 1 intentional / 0 open). |
| 2026-08-03T00:00:00Z | [BUGS.md](development/bugs/index.md) | Split | Split 299 bug entries into individual files in `docs/development/bugs/001.md`–`299.md` with `index.md` and `README.md` symlink. |
| 2026-08-03T00:00:00Z | [index.md](development/index.md) | Updated | Changed Bugs link from `BUGS.md` to `bugs/index.md`; bumped timestamp. |
| 2026-08-03T00:00:00Z | [index.md](development/bugs/index.md) | Created | Bug tracker index with summary tables and links to all 299 bug files. |
| 2026-08-03T00:00:00Z | [v0.8.0.md](releases/v0.8.0.md) | Created | Created release notes for v0.8.0. |
| 2026-08-03T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.0 to releases index; bumped timestamp. |
| 2026-08-03T00:00:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated current state description for v0.8.0; bumped timestamp. |
| 2026-08-03T00:00:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.8.0. |
| 2026-07-30T22:14:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entry #277 for render cursor clamping bug. |
| 2026-07-30T00:00:00Z | [index.md](index.md) | Updated | Added log.md link and bumped timestamp. |
| 2026-07-30T00:00:00Z | [index.md](development/index.md) | Updated | Added improvements.md link and bumped timestamp. |
| 2026-07-30T00:00:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count from 770 to 802 passing tests. |
| 2026-07-30T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Bumped timestamp to reflect latest entries (#210-#276). |
| 2026-07-25T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries #249-#276 from post-v0.7.0 code audit. |
| 2026-07-24T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries #226-#248 from v0.7.0 QA + deep static code review audit. |
| 2026-07-22T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries #216-#225 from comprehensive codebase audit. |
| 2026-07-21T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries #212-#215 from status-bar / pane-border rework audit. |
| 2026-07-21T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries #210-#211 from emoji-width and DECAWM fixes. |
| 2026-07-20T06:00:00Z | [v0.7.0.md](releases/v0.7.0.md) | Created | Created release notes for v0.7.0. |
| 2026-07-20T06:00:00Z | [index.md](releases/index.md) | Updated | Added v0.7.0 to releases index and bumped timestamp. |
| 2026-07-20T16:00:00Z | [improvements.md](development/improvements.md) | Created | Created performance and optimization opportunities catalog. |
| 2026-07-20T03:40:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entry 209 for SGR delta color bleeding bug, corrected summary totals, and updated timestamp. |
| 2026-07-20T03:40:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count to 770 passing tests. |
| 2026-07-20T03:40:00Z | [log.md](log.md) | Updated | Documented SGR delta color bleeding fix and doc updates. |
| 2026-07-20T03:33:00Z | [log.md](log.md) | Updated | Documented v0.6.0 release notes creation and index updates. |
| 2026-07-20T03:33:00Z | [v0.6.0.md](releases/v0.6.0.md) | Created | Created release notes for v0.6.0. |
| 2026-07-20T03:33:00Z | [index.md](releases/index.md) | Updated | Added v0.6.0 to releases index and bumped timestamp. |
| 2026-07-20T03:33:00Z | [build.zig.zon](../build.zig.zon) | Updated | Bumped version to 0.6.0. |
| 2026-07-20T03:25:00Z | [log.md](log.md) | Created | Initialize documentation modification log. |
| 2026-07-20T03:25:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries 207 and 208 for non-blocking socket buffer truncation and skipped render frame bugs, and updated summary count. |
| 2026-07-20T03:25:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Updated test count to 769 passing tests. |
| 2026-07-20T03:25:00Z | [index.md](index.md) | Updated | Bumped index timestamp. |
| 2026-07-20T03:25:00Z | [index.md](development/index.md) | Updated | Bumped development index timestamp. |
