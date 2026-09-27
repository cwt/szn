---
type: log
title: "szn Docs Update Log"
description: "Chronological log of modifications to the szn OKF documentation bundle."
status: stable
sources:
  - docs/
verified: human-reviewed
tags: [log, changelog, okf]
timestamp: 2026-09-27T11:06:00Z
---

# Documentation Bundle Log

This file tracks all modifications, extensions, and updates to the `szn` documentation bundle in chronological order.

| Timestamp | Document | Action | Description |
| 2026-09-27T11:06:00Z | [506-510](development/bugs/) | Resolved | All five findings from the whole-project review fixed, with 6 new regression tests (1,035 → 1,041). #506: `codepoint-widths`/`variation-selector-always-wide` declared server-scoped via `options.isServerScoped` and redirected to the server store, so a bare `set-option` no longer writes a per-session copy of a process-wide value. #507: the "no global state" claim in AGENTS.md and architecture.md qualified with its three exception groups. #510: `log_fd` made atomic, and `disable` now clears the gate before closing the descriptor. #509: `.workbuddy-ai/` (and `.claude/`) declared in .gitignore. #508: README and progress.md test counts corrected to 1,041. |
| 2026-09-27T10:46:00Z | [bugs/506-510](development/bugs/) | Created | Filed 5 findings from the 2026-09-27 whole-project review, all open: `codepoint-widths` session-scoped but process-global (HIGH), the "No global state" claim contradicted by 11 module globals, stale README test count, `.workbuddy-ai/` missing from .gitignore, and a non-atomic log fd behind an atomic gate. |
| 2026-09-27T10:46:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added #506–#510 rows, updated severity and status tables, coverage note now reads #1–#300, #303–#510 / 508 entries with 5 open. |
| 2026-09-27T10:12:00Z | 66 docs | Updated | Rewrote 226 links that escaped the `docs/` bundle to absolute `https://github.com/cwt/szn/blob/main/...` URLs (217 source files, 66 carrying `#L` line anchors, plus `build.zig.zon` and the repo `README.md`). docs/ is published as a standalone GitHub Pages site, so `../../../src/grid.zig` resolved against the Pages origin and 404'd. |
| 2026-09-27T10:12:00Z | bundle-wide | Updated | Documented the split convention: intra-bundle concept links stay relative (OKF 2.5, and they resolve correctly under Pages), while links to repository assets outside the bundle are absolute. Links escaping docs/ now 227 -> 0. |
| 2026-09-27T10:12:00Z | [index.md](index.md) | Fixed | Corrected the OKF specification link to the canonical `GoogleCloudPlatform/open-knowledge-format` repo; the previously recorded `github.com/google/okf` returned 404. |
| 2026-09-27T10:12:00Z | [log.md](log.md) | Fixed | Repaired a broken `../text_reflow.md` link that resolved to the repository root instead of `docs/text_reflow.md`. |
| 2026-09-27T09:58:00Z | [bugs/*.md](development/bugs/) | Updated | Backfilled `stale_after` on 451 bug entries and normalized 4 outliers to the directory majority `2026-12-31T00:00:00Z`; all 503 bug entries now carry the freshness signal. |
| 2026-09-27T09:58:00Z | [bugs/*.md](development/bugs/), [releases/v*.md](releases/) | Updated | Backfilled `tags` on 503 bug entries (`[bugs, tracker]`) and 16 release notes (`[releases, changelog]`). |
| 2026-09-27T09:58:00Z | [bugs/502-505](development/bugs/), [text_reflow.md](text_reflow.md) | Updated | Corrected 5 `timestamp` values that recorded local +07:00 time under a `Z` suffix, making them future-dated; rewritten to the true UTC instant of the commit that authored them. 10 log rows corrected the same way. |
| 2026-09-27T09:58:00Z | 52 docs | Updated | Normalized `verified` quoting — the value was quoted in 52 files and unquoted in 483; unquoted wins so frontmatter parsers see one form. |
| 2026-09-27T09:58:00Z | [improvements.md](development/improvements.md) | Updated | `type: improvements` was a one-off archetype; mapped to the standard `project_priority` that progress.md already uses for the same document shape (a catalog sorted by effort-to-impact). |
| 2026-09-27T09:58:00Z | [szn-audit-2026-08-31.md](development/szn-audit-2026-08-31.md) | Updated | Added missing `stale_after` to the audit report. |
| 2026-09-27T09:58:00Z | [index.md](index.md) | Updated | Recorded the bundle's metadata conventions, including the two deliberate exemptions (reserved `index.md`/`log.md` filenames, and immutable release notes carry no `stale_after`). |
| 2026-09-27T09:52:00Z | [bugs/*.md](development/bugs/) | Updated | Normalized `status:` frontmatter across all 503 bug docs to the closed slug vocabulary `resolved` / `false_positive` / `open` (OKF v0.2 machine-parseable lifecycle value). Resolution prose was already carried in each body, so no detail was lost. |
| 2026-09-27T09:52:00Z | [bugs/306-310, 349, 391, 454-477](development/bugs/) | Updated | Repaired 29 body `**Status:**` lines still reading "Open" while their frontmatter and this index recorded the bug as closed — the #306–#310 and #454–#477 batches were reconciled in the index but not in the individual files. |
| 2026-09-27T09:52:00Z | [bugs/347, 359, 362, 427, 441-444](development/bugs/) | Updated | Replaced 24 absolute `file:///` links with repo-relative paths (OKF rule 2.5); they leaked the authoring machine's filesystem layout and resolved nowhere else. Prose mentions of the scheme in `releases/v0.8.0.md` left intact as historical record. |
| 2026-09-27T09:52:00Z | [BUGS.md](development/bugs/index.md) | Updated | Aligned both summary tables and the All Bugs status column to the new slug vocabulary; documented the closed value set. |
| 2026-09-27T09:45:00Z | [progress.md](development/progress.md) | Updated | Refreshed `timestamp`; corrected test count to 1,035 total (1,034 passing, 1 skipped); added the #502–#505 Thai reflow sweep and extended the stability sweep range to #441–#505. |
| 2026-09-27T09:15:49Z | [505.md](development/bugs/505.md) | Resolved | Corrected text_reflow.md sources, documented two-tier libthai architecture and fallback backtracking, and added Sara Am width-1 rationale (bug #505). |
| 2026-09-27T09:15:49Z | [BUGS.md](development/bugs/index.md) | Updated | Marked #505 Fixed, bumped Fixed/Resolved total (481 entries, 0 open). |
| 2026-09-27T09:13:24Z | [504.md](development/bugs/504.md) | Resolved | Synchronized LibThai loading and deinitialization with atomic state transitions and documented server-thread lifecycle (bug #504). |
| 2026-09-27T09:13:24Z | [BUGS.md](development/bugs/index.md) | Updated | Marked #504 Fixed, bumped Fixed/Resolved total (480 entries). |
| 2026-09-27T09:10:28Z | [503.md](development/bugs/503.md) | Resolved | Simplified cellHasMaiHanAkat to strictly test combiningCodepoint on table indices, eliminating dead raw-codepoint check (bug #503). |
| 2026-09-27T09:10:28Z | [BUGS.md](development/bugs/index.md) | Updated | Marked #503 Fixed, bumped Fixed/Resolved total (479 entries). |
| 2026-09-27T09:08:20Z | [502.md](development/bugs/502.md) | Resolved | Fixed Thai cluster segmentation in findThaiClusterEnd to consume consecutive following vowels in compound syllables like เ-าะ (bug #502). |
| 2026-09-27T09:08:20Z | [BUGS.md](development/bugs/index.md) | Updated | Marked #502 Fixed, bumped Fixed/Resolved total (478 entries). |
| 2026-09-27T09:02:13Z | [bugs 502-505](development/bugs/) | Created | Filed 4 bug entries (#502–#505) from Thai reflow and text architecture review: 1 MEDIUM (#502: เ-าะ compound vowel cluster split), 3 LOW (#503: cellHasMaiHanAkat dead raw-codepoint check, #504: libthai unsynchronized globals, #505: text_reflow.md stale references and omitted libthai docs). |
| 2026-09-27T09:02:13Z | [BUGS.md](development/bugs/index.md) | Updated | Added #502–#505 rows, bumped severity totals and open count (503 entries). |
| 2026-09-27T01:20:00Z | [v0.10.0.md](releases/v0.10.0.md) | Created | Created release notes for v0.10.0 (hot-path performance architecture, VS16 emoji promotion, hardened sixel graphics engine, and 61-bug stability sweep). |
| 2026-09-27T01:20:00Z | [index.md](releases/index.md), [README.md](https://github.com/cwt/szn/blob/main/README.md) | Updated | Added v0.10.0 to releases index, documented variation-selector-always-wide option, and updated test count to 1,032. |
| 2026-09-27T01:20:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 1,032; documented v0.10.0 release milestone. |
| 2026-09-27T01:20:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.10.0. |
| 2026-09-04T09:18:00Z | [index.md](index.md), [text_reflow.md](text_reflow.md), [migration.md](development/migration.md), [progress.md](development/progress.md), [szn-audit-2026-08-31.md](development/szn-audit-2026-08-31.md) | Updated | Upgraded bundle to OKF v0.2: renamed all-capitals documents to lowercase, adopted v0.2 trust signals (status, sources, verified, stale_after), added frontmatter and index linkage to audit report. |
| 2026-08-31T07:15:00Z | [442.md](development/bugs/442.md) | Created | Filed and resolved bug #442 for automatic window renaming latency via zero-overhead PGID change detection. |
| 2026-08-31T07:05:00Z | [441.md](development/bugs/441.md) | Created | Filed and resolved bug #441 for status cache invalidation lag, auto-rename and OSC title triggers, and pane switch invalidation. |
| 2026-08-31T06:45:00Z | [v0.9.1.md](releases/v0.9.1.md) | Created | Created release notes for v0.9.1 hotfix (global window status format routing, status cache invalidation on active window change, single-quoted format strings, and per-window format resolution). |
| 2026-08-31T06:45:00Z | [index.md](releases/index.md), [README.md](releases/README.md) | Updated | Added v0.9.1 to releases index and README. |
| 2026-08-31T06:45:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 970; documented v0.9.1 hotfix release and 49 commands. |
| 2026-08-31T06:45:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.9.1. |
| 2026-08-31T06:35:00Z | [440.md](development/bugs/440.md) | Created | Filed and resolved bug #440 for global window status format option routing and status cache freeze. |
| 2026-08-31T00:00:00Z | [v0.9.0.md](releases/v0.9.0.md) | Created | Created release notes for v0.9.0 (configurable scrollback history, zero-allocation ring buffer, runtime log control, command line quoting, and 44-bug stability sweep). |
| 2026-08-31T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.9.0 to releases index. |
| 2026-08-31T00:00:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 959; documented v0.9.0 release. |
| 2026-08-31T00:00:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.9.0. |
| 2026-08-30T16:20:00Z | [architecture.md](architecture.md) | Updated | Rewrote to cite symbols instead of line numbers; ~25 line citations had all drifted (e.g. `Server.run` was documented at server.zig:277, actually 605). Added a referencing-convention note. |
| 2026-08-30T16:20:00Z | [ipc-protocol.md](ipc-protocol.md) | Updated | Corrected `MAX_PACKET_SIZE` from 1 MiB to the actual 16 MiB; added the missing `redraw` (0x0A) and `client_log` (0x85) message types; retired the deleted 0x02/0x03/0x07 slots; documented `validPacketLength` (#375) and `Packet.make` truncation (#389); replaced 21 stale line citations with symbol names. |
| 2026-08-30T16:20:00Z | [concepts.md](concepts.md) | Updated | Removed 8 stale line citations in favour of file+symbol references. |
| 2026-08-30T16:20:00Z | [build-run.md](build-run.md) | Updated | Corrected the test count from ~730 to 944; fixed three stale `build.zig` citations; documented the stale-socket caveat that makes 3 tests fail on re-runs; corrected `log-file` to `server-log-file`. |
| 2026-08-30T16:20:00Z | [BUGS.md](development/bugs/index.md) | Updated | Regenerated both summary tables from frontmatter: severity rows previously summed to 422 while claiming 426 (actual 425; HIGH 103→105, LOW 100→102); status Fixed/Resolved 405→404, False Positive 18→19. Normalised row #247's status label and corrected the stale "all OPEN" note for #395–#427. |
| 2026-08-30T16:20:00Z | [progress.md](development/progress.md) | Updated | Test count 927→944 (verified); command count 33+→48; removed `err.zig` from the Phase 0 file list; noted that per-phase test figures are historical snapshots rather than a partition of 944. |
| 2026-08-30T16:20:00Z | [README.md](https://github.com/cwt/szn/blob/main/README.md) | Updated | Test count 927→944, command count 47→48, plus a caveat about the stale `$TMPDIR/szn.sock` breaking 3 tests on re-runs. |
| 2026-08-30T16:20:00Z | [migration.md](development/migration.md) | Updated | Flagged the Phase 0 file list as historical and noted that `src/err.zig` was removed (bug #36). |
| 2026-08-30T16:20:00Z | [index.md](releases/index.md), [text_reflow.md](text_reflow.md), [bug 343](development/bugs/343.md) | Updated | Refreshed frontmatter timestamps that lagged their last modification. |
| 2026-08-30T00:00:00Z | [bugs 395-426](development/bugs/) | Created | Filed 32 new bug entries (#395-#426) from the 2026-08-30 deep-audit sweep: 3 CRITICAL (Pty.spawn double-free, border-cache cross-allocator free, format empty-pattern server abort), 6 HIGH, 14 MEDIUM, 9 LOW. |
| 2026-08-30T00:00:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added #395-#426 rows, bumped severity/status totals (425 entries). |
| 2026-08-24T00:00:00Z | [v0.8.2.md](releases/v0.8.2.md) | Created | Created release notes for v0.8.2 (stability, memory hardening, terminal emulation fidelity, and UX polish). |
| 2026-08-24T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.2 to releases index. |
| 2026-08-24T00:00:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 927; documented v0.8.2 release. |
| 2026-08-24T00:00:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.8.2. |
| 2026-08-09T00:00:00Z | [v0.8.1.md](releases/v0.8.1.md) | Created | Created release notes for v0.8.1. |
| 2026-08-09T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.1 to releases index. |
| 2026-08-09T00:00:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.8.1. |
| 2026-08-03T07:30:00Z | bugs #300/#303/#304/#305/#307/#309/#310 | Updated | Documented corrected fixes: #309 status-line double-free crash, #303 behind_count disconnect leak, #304/#307 generation counter now bumped by cmdSetOption, #300 auto-rename 1 s rate limit, #305 valid-flag caveat. |
| 2026-08-03T07:30:00Z | [bugs/index.md](development/bugs/index.md) | Updated | Marked #300–#310 statuses (7 fixed, #306/#308 false positive), removed duplicate #310 row, kept counts (293 fixed / 14 FP / 1 intentional / 0 open). |
| 2026-08-03T00:00:00Z | [BUGS.md](development/bugs/index.md) | Split | Split 299 bug entries into individual files in `docs/development/bugs/001.md`–`299.md` with `index.md` and `README.md` symlink. |
| 2026-08-03T00:00:00Z | [index.md](development/index.md) | Updated | Changed Bugs link from `BUGS.md` to `bugs/index.md`; bumped timestamp. |
| 2026-08-03T00:00:00Z | [index.md](development/bugs/index.md) | Created | Bug tracker index with summary tables and links to all 299 bug files. |
| 2026-08-03T00:00:00Z | [v0.8.0.md](releases/v0.8.0.md) | Created | Created release notes for v0.8.0. |
| 2026-08-03T00:00:00Z | [index.md](releases/index.md) | Updated | Added v0.8.0 to releases index; bumped timestamp. |
| 2026-08-03T00:00:00Z | [progress.md](development/progress.md) | Updated | Updated current state description for v0.8.0; bumped timestamp. |
| 2026-08-03T00:00:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.8.0. |
| 2026-07-30T22:14:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entry #277 for render cursor clamping bug. |
| 2026-07-30T00:00:00Z | [index.md](index.md) | Updated | Added log.md link and bumped timestamp. |
| 2026-07-30T00:00:00Z | [index.md](development/index.md) | Updated | Added improvements.md link and bumped timestamp. |
| 2026-07-30T00:00:00Z | [progress.md](development/progress.md) | Updated | Updated test count from 770 to 802 passing tests. |
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
| 2026-07-20T03:40:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 770 passing tests. |
| 2026-07-20T03:40:00Z | [log.md](log.md) | Updated | Documented SGR delta color bleeding fix and doc updates. |
| 2026-07-20T03:33:00Z | [log.md](log.md) | Updated | Documented v0.6.0 release notes creation and index updates. |
| 2026-07-20T03:33:00Z | [v0.6.0.md](releases/v0.6.0.md) | Created | Created release notes for v0.6.0. |
| 2026-07-20T03:33:00Z | [index.md](releases/index.md) | Updated | Added v0.6.0 to releases index and bumped timestamp. |
| 2026-07-20T03:33:00Z | [build.zig.zon](https://github.com/cwt/szn/blob/main/build.zig.zon) | Updated | Bumped version to 0.6.0. |
| 2026-07-20T03:25:00Z | [log.md](log.md) | Created | Initialize documentation modification log. |
| 2026-07-20T03:25:00Z | [BUGS.md](development/bugs/index.md) | Updated | Added entries 207 and 208 for non-blocking socket buffer truncation and skipped render frame bugs, and updated summary count. |
| 2026-07-20T03:25:00Z | [progress.md](development/progress.md) | Updated | Updated test count to 769 passing tests. |
| 2026-07-20T03:25:00Z | [index.md](index.md) | Updated | Bumped index timestamp. |
| 2026-07-20T03:25:00Z | [index.md](development/index.md) | Updated | Bumped development index timestamp. |
