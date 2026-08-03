---
type: log
title: "szn Docs Update Log"
description: "Chronological log of modifications to the szn OKF documentation bundle."
timestamp: 2026-08-03T00:00:00Z
---

# Documentation Bundle Log

This file tracks all modifications, extensions, and updates to the `szn` documentation bundle in chronological order.

| Timestamp | Document | Action | Description |
| :--- | :--- | :--- | :--- |
| 2026-08-03T07:30:00Z | [PROGRESS.md](development/PROGRESS.md) | Updated | Bumped test count to 862; documented correction of the #300–#310 performance-fix regressions. |
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
