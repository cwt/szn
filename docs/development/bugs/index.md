---
type: index
title: "Bug Tracker — szn"
description: "Individual bug entries for szn, one file per bug."
status: stable
sources:
  - docs/development/bugs/
verified: human-reviewed
tags: [bugs, tracker, index, issues]
timestamp: 2026-10-04T17:46:00Z
---

# Bugs — szn

Sorted by number. See individual bug files for details.

> **Note:** Bugs **#301** and **#302** were never filed (MIA). The #300–#310 performance sweep skipped straight from #300 to #303. Bugs **#349–#394** were filed by the 2026-08-23 deep-audit sweep (full-codebase review; 46 bugs, all since resolved). Bugs **#395–#427** were filed by the 2026-08-30 deep-audit sweep (memory safety, IPC integrity, sixel accounting, config/command surface, dead code, perf, alt-screen mouse wheel; 33 bugs, all since resolved). Bugs **#428–#439** were filed by the 2026-08-31 re-validation sweep (12 confirmed findings from the audit report, re-checked line-by-line against live source; all since resolved). Bugs **#448–#450** were filed by the 2026-09-02 stale-pointer bug-class extrapolation audit. Bugs **#451–#453** were filed by the 2026-09-03 scrollback truncation and pane resize audit (all since resolved). Bugs **#454–#477** were filed by the 2026-09-13 deep-audit sweep (memory safety, DCS sixel ownership, history compaction double-free, buffer-list leaks, layout float/bounds traps, copy-mode coordinate clamps, IPC frame caps, and perf/dead-code clusters; 24 bugs, all since resolved). Bugs **#478–#483** were filed by the 2026-09-22 hot-path performance review (6 performance findings, all fixed 2026-09-22: parser byte-by-byte dispatch, isPaneValid/tree-walk regression, per-cell SGR formatting, full-grid diff, per-frame heap copy, per-space writes). Bugs **#484–#501** were filed by the 2026-09-26 external code review (Muse deep review: full read of main.zig plus 5 parallel reviewer passes over the remaining source; 18 findings, all fixed 2026-09-27). Bugs **#502–#505** were filed by the 2026-09-27 Thai reflow and text architecture review (4 findings: เ-าะ compound vowel cluster split, dead raw-codepoint check in cellHasMaiHanAkat, libthai unsynchronized globals, and text_reflow.md stale references/libthai documentation omission). Bugs **#506–#510** were filed by the 2026-09-27 whole-project review (5 findings, all open): `codepoint-widths` registered as a session option but implemented as a process-global table, so one session's override mutates every session; the "No global state" claim in AGENTS.md and architecture.md contradicted by eleven mutable module globals; a stale test count in README.md; `.workbuddy-ai/` absent from .gitignore; and a non-atomic log fd guarded by an atomic flag rather than a lock. All five were fixed the same day: `codepoint-widths` and `variation-selector-always-wide` are now declared server-scoped via `options.isServerScoped` and redirected to the server store, so a bare `set-option` no longer writes a per-session copy of a process-wide value; the "no global state" claim in AGENTS.md and architecture.md is now qualified with its three exception groups; the log descriptor is an atomic and `disable` clears the gate before closing it; `.workbuddy-ai/` is declared in .gitignore; and the README test count is 1,041. Bugs **#511–#529** were filed by the 2026-10-05 dual-toolchain deep audit (5 parallel subsystem passes plus line-by-line re-verification by the auditor; 19 findings — **11 confirmed by reading live source, 8 recorded as unverified leads**). The sweep covers `resize-pane` never updating the layout tree, `capture-pane` emitting NUL bytes, an IRM sixel refcount under-count that **reverses the 2026-08-31 audit's H2 false-positive verdict**, a `pushOwned` double-free regression introduced by the #456 fix, NBSP classified as zero-width, numeric choice options being unsettable, non-round-trippable `list-keys` output, inert option-table entries, drifted SGR attribute tables, a duplication cluster, and a latent DECOM / NEL / CBT / origin-overflow cluster. The tracker covers #1–#300, #303–#529 — **527 entries** in total, 18 open.

Both summary tables below are generated from the `severity` and `status` fields in each bug's frontmatter. Regenerate them rather than editing by hand. `status` uses the closed slug vocabulary `resolved` / `false_positive` / `open` documented under [Summary by Status](#summary-by-status).

## Summary by Severity

| Severity | Count |
|---|---:|
| MEDIUM | 193 |
| LOW | 134 |
| HIGH | 120 |
| CRITICAL | 53 |
| LOW (code quality) | 6 |
| LOW (architecture) | 4 |
| MEDIUM (performance) | 4 |
| LOW (correctness) | 3 |
| LOW (safety) | 3 |
| MEDIUM-HIGH | 3 |
| LOW (cosmetic) | 1 |
| LOW (performance) | 1 |
| LOW (performance) → **MEDIUM** (correctness regression in original fix) | 1 |
| MEDIUM (dead code / refcount drift) | 1 |
| **Total** | **527** |

## Summary by Status

| Status | Count |
|---|---:|
| `resolved` | 487 |
| `false_positive` | 22 |
| `open` | 18 |
| **Total** | **527** |

The `status` frontmatter field is a closed vocabulary of three slugs —
`resolved`, `false_positive`, `open` — so both summary tables and the status
column of the table below are mechanically derivable from the per-bug
frontmatter. The resolution narrative for each bug lives in its body
(`**Status:**` line), not in the frontmatter field.

The `verified` field is a separate vocabulary — `human-reviewed`,
`machine-confirmed`, and, since the 2026-10-05 sweep, `unverified` for findings
recorded from static analysis that have not been reproduced at runtime. It is
not tabulated here; an `open` bug whose body carries a
*Verification status* note is a lead, not a confirmed defect.

## All Bugs

| # | Title | Severity | Status |
|---|---|---|---|
| [1](001.md) | Use-after-free in Session.rename() | CRITICAL | resolved |
| [2](002.md) | Invalid-free of string literal in dispatch | CRITICAL | resolved |
| [3](003.md) | Stack overflow when >64 fds registered | CRITICAL | resolved |
| [4](004.md) | Pane memory leak on Window.deinit | CRITICAL | false_positive |
| [5](005.md) | cmdKillPane leaks killed pane | CRITICAL | false_positive |
| [6](006.md) | cmdJoinPane leaks dummy pane | CRITICAL | false_positive |
| [7](007.md) | Child process inherits all parent fds after fork | CRITICAL | resolved |
| [8](008.md) | reverseIndex emits wrong escape sequence | CRITICAL | resolved |
| [9](009.md) | Memory leak in Grid.scrollDown() | HIGH | resolved |
| [10](010.md) | Colour.fmt() reads uninitialized memory | HIGH | resolved |
| [11](011.md) | Memory leak in Options.set() | HIGH | resolved |
| [12](012.md) | Dangling pointer in Context.set() | HIGH | resolved |
| [13](013.md) | Copy mode broken for scrolled content | HIGH | resolved |
| [14](014.md) | Emacs alt-key bindings are dead code | HIGH | false_positive |
| [15](015.md) | Key value parsing in config is a stub | MEDIUM | resolved |
| [16](016.md) | Unsafe union access on OptionValue | MEDIUM | resolved |
| [17](017.md) | Child uses parent allocator after fork | CRITICAL | resolved |
| [18](018.md) | OSC ST terminator (ESC \) broken | HIGH | resolved |
| [19](019.md) | No bounds check on CSI input buffer | MEDIUM | resolved |
| [20](020.md) | EAGAIN treated as EOF in interactive client | HIGH | resolved |
| [21](021.md) | CSI dispatch warn floods logs | LOW | resolved |
| [22](022.md) | cmdRenameWindow use-after-free | CRITICAL | resolved |
| [23](023.md) | No SIGCHLD handler — zombie window | MEDIUM | resolved |
| [24](024.md) | processReadStdin leaks the input buffer on each call | MEDIUM | resolved |
| [25](025.md) | handleMouseFocus can use freed Pane pointer | HIGH | resolved |
| [26](026.md) | paneList doesn't filter by session | MEDIUM | resolved |
| [27](027.md) | FdWriter.writeByte ignores zero-write | MEDIUM | resolved |
| [28](028.md) | No bounds check in client.sendIdentify | HIGH | resolved |
| [29](029.md) | Log file opened/closed on every log call | LOW | resolved |
| [30](030.md) | Unimplemented config directives | MEDIUM | resolved |
| [31](031.md) | Directional pane selection is actually circular | MEDIUM | resolved |
| [32](032.md) | .last_window doesn't track actual last window | MEDIUM | resolved |
| [33](033.md) | Kitty keyboard protocol incomplete | MEDIUM | resolved |
| [34](034.md) | split-window direction flag only works as first arg | MEDIUM | resolved |
| [35](035.md) | Hardcoded log path `/tmp/szn.log` | LOW | resolved |
| [36](036.md) | Error set is a single catch-all | LOW | resolved |
| [37](037.md) | Arena allocation not used | MEDIUM | resolved |
| [38](038.md) | Duplicate fd registration allowed in event loop | MEDIUM | resolved |
| [39](039.md) | cmdPrevWindow has duplicate dead code | LOW | resolved |
| [40](040.md) | attrFields/attrCodes parallel arrays fragile | LOW | resolved |
| [41](041.md) | Tab stop hardcoded to 8 | LOW | resolved |
| [42](042.md) | History limit hardcoded to 2000 | LOW | resolved |
| [43](043.md) | cmdCopyMode overwrites previous copy mode without deinit | LOW | false_positive |
| [44](044.md) | resize-pane can't set size below 1 | LOW | resolved |
| [45](045.md) | sockaddr_un path size hardcoded to 104 | LOW | resolved |
| [46](046.md) | message_reader silently truncates on buffer full | LOW | resolved |
| [47](047.md) | mapCommandToAction can match substrings | MEDIUM | resolved |
| [48](048.md) | `mapCommandToAction` rejects commands with arguments — most config bind-key directives fail silently | CRITICAL | resolved |
| [49](049.md) | Line-wrapping fires `grid.scrollUp()` instead of `scrollUpInRegion()` — breaks DECSTBM scroll regions | CRITICAL | resolved |
| [50](050.md) | Double-underline and curly-underline both render as plain underline (SGR 4) | HIGH | resolved |
| [51](051.md) | `key.format` — `alt` and `meta` modifiers collide on `M-` prefix | HIGH | resolved |
| [52](052.md) | `feedPty` + `handlePtyEvent` race: PTY deinited in two different code paths | HIGH | resolved |
| [53](053.md) | Mouse escape sequence bytes leak to child PTY when pane doesn't want mouse events | HIGH | resolved |
| [54](054.md) | `split-window -h` (exactly, no trailing args) maps to vertical split | MEDIUM | false_positive |
| [55](055.md) | Log file fd shared between parent and child after fork — garbled logs | MEDIUM | resolved |
| [56](056.md) | `destroyPane` iterates `self.sessions` while `killSession` `swapRemove`s from it | MEDIUM | resolved |
| [57](057.md) | `handlePtyEvent` casts `udata` pointer without validation — potential stale pointer | MEDIUM | resolved |
| [58](058.md) | `processInput` — unbounded `esc_buf` growth on malformed or never-completing CSI | LOW | resolved |
| [59](059.md) | `key.format` — no bounds check on output buffer before writing | LOW | resolved |
| [60](060.md) | `renderStatusBar` — overflows rendering buffer when many windows with long names | LOW | resolved |
| [61](061.md) | `cfg.zig` — `stripInlineComment` doesn't handle escaped quotes in value strings | LOW | resolved |
| [62](062.md) | `resolveLogPath` calls `mkdir` with `0o777` and silently ignores failure | LOW | resolved |
| [63](063.md) | SGR mouse wheel release events misreported — wheel info lost on release | LOW | resolved |
| [64](064.md) | Cursor position lost/reset on alternate screen exit (e.g. exiting Vim) | MEDIUM | resolved |
| [65](065.md) | Use-after-free / double-free via `errdefer` in `Grid.scrollUp()` | CRITICAL | resolved |
| [66](066.md) | `setAttributes` fails to turn off removed attributes | CRITICAL | resolved |
| [67](067.md) | `writeCell` writes character with wrong colors after attribute reset emits `\x1b[m` | CRITICAL | resolved |
| [68](068.md) | Potential double-close of PTY fds from conflicting deinit paths | CRITICAL | resolved |
| [69](069.md) | Stack buffer overflow in `Client.sendPacket` | HIGH | resolved |
| [70](070.md) | No upper cap on packet length in `Client.recvPacket` — DoS via 4 GB allocation | HIGH | resolved |
| [71](071.md) | `drawLine` "clear trailing spaces" is a dead no-op | HIGH | resolved |
| [72](072.md) | Division by zero in `Grid.resize(0)` | HIGH | resolved |
| [73](073.md) | Division by zero in `Grid.scrollDown` when `height == 0` | HIGH | resolved |
| [74](074.md) | Allocation error silently swallowed in `advanceDcsIntermediate` (sixel DCS) | HIGH | resolved |
| [75](075.md) | `cmdBreakPane` overrides new window's pane without deinit — arena waste | HIGH | resolved |
| [76](076.md) | `cmdJoinPane` creates dummy pane via `splitPane` that is discarded — arena waste | HIGH | resolved |
| [77](077.md) | Memory leak in `windowTitleCallback` — old name never freed | HIGH | resolved |
| [78](078.md) | Memory leak in `renderToDisplayClient` — auto window rename leaks old name | HIGH | resolved |
| [79](079.md) | Modified function key parsing broken — `~` CSI sequences with modifiers dropped | HIGH | resolved |
| [80](080.md) | `@intCast` before bounds check in `Client.sendIdentify` — panic in safe builds | MEDIUM | resolved |
| [81](081.md) | `errdefer` reads uninitialized `fd` if `socket()` fails | MEDIUM | resolved |
| [82](082.md) | `std.posix.errno(rc)` may lose error specificity for C wrappers | MEDIUM | resolved |
| [83](083.md) | `@intCast(self.cy)` can panic when cursor position is -1 in `drawLine` | MEDIUM | resolved |
| [84](084.md) | CSI/SGR mouse/UTF-8 input buffer overflow silently discards data | MEDIUM | resolved |
| [85](085.md) | DSR response silently dropped on `bufPrint` failure | MEDIUM | resolved |
| [86](086.md) | XTSMGRAPHICS response silently fails on `bufPrint` overflow or `writeInput` error | MEDIUM | resolved |
| [87](087.md) | `.?` on `active_window`/`active_pane` without guard in `cmdNewSession` | MEDIUM | resolved |
| [88](088.md) | `defer free` on `parsed_val.string` relies on undocumented dup-in-set contract | MEDIUM | resolved |
| [89](089.md) | `logFn` writes garbage bytes from uninitialized buffer on `bufPrint` failure | MEDIUM | resolved |
| [90](090.md) | `keysEqual` ignores Meta modifier — impossible to bind Meta-modified keys | MEDIUM | resolved |
| [91](091.md) | `errdefer` registered after `Pane.init` in `Layout.splitPane` — leak on init failure | MEDIUM | resolved |
| [92](092.md) | History lines not resized when terminal width changes | MEDIUM | resolved |
| [93](093.md) | Partial `write()` on Unix socket not retried | LOW | resolved |
| [94](094.md) | Integer overflow in `resize_right` action | LOW | resolved |
| [95](095.md) | Daemon fork doesn't close stdin/stdout/stderr | LOW | resolved |
| [96](096.md) | Log directory created with `0o777` (world-writable) | LOW | resolved |
| [97](097.md) | `socket_path.zig` silently ignores `mkdir` failure | LOW | resolved |
| [98](098.md) | `logFn` retries `open()` on every call forever if it fails once | LOW | resolved |
| [99](099.md) | CSI parameter integer overflow — `param_val * 10 + digit` wraps on u32 | LOW | resolved |
| [100](100.md) | `client/raw.zig` — VMIN/VTIME indices are macOS values, completely wrong on Linux | CRITICAL | resolved |
| [101](101.md) | `server/server.zig` — Use-after-free during batch PTY event processing | CRITICAL | resolved |
| [102](102.md) | `main.zig` — `errno` retrieval is always `.SUCCESS`, client disconnects on transient errors | CRITICAL | resolved |
| [103](103.md) | `log.zig` + `socket_path.zig` — Wrong errno retrieval for C library calls | CRITICAL | resolved |
| [104](104.md) | `char_width.zig` — Hangul Jamo 0x1100–0x115F reported as width 0 instead of 2 | HIGH | resolved |
| [105](105.md) | `key.zig` — Alt modifier lost when parsing ESC+char sequences | HIGH | resolved |
| [106](106.md) | `server/dispatch.zig` — Partial writes not retried on socket I/O | HIGH | resolved |
| [107](107.md) | `server/protocol.zig` — `IdentifyTerm.decode` missing `len <= 64` validation | HIGH | resolved |
| [108](108.md) | `server/server.zig` — Unchecked writes to display client | HIGH | resolved |
| [109](109.md) | `tty/fd_writer.zig` — Missing EINTR handling in writeAll and writeByte | HIGH | resolved |
| [110](110.md) | `client/client.zig` — Heap-allocated body in recvPacket has no guaranteed free | HIGH | resolved |
| [111](111.md) | `mode_copy.zig` — `yankSelection` computes wrong bounds for reverse selections | HIGH | resolved |
| [112](112.md) | `main.zig` — `@enumFromInt` without validation for MessageType | HIGH | resolved |
| [113](113.md) | `window.zig` + `session.zig` — Pane double-deinit between Session.deinit and Window.deinit | HIGH | resolved |
| [114](114.md) | `input.zig` — UTF-8 state not cleared on parser reset or state transitions | MEDIUM | resolved |
| [115](115.md) | `key.zig` — `@intCast` may panic on out-of-range kitty codepoint | MEDIUM | resolved |
| [116](116.md) | `options.zig` — `choice` values are not cloned or freed | MEDIUM | resolved |
| [117](117.md) | `cfg.zig` — Quoted string parser doesn't verify closing quote | MEDIUM | resolved |
| [118](118.md) | `cfg.zig` — `parseSetEnv` doesn't recognize `-g` followed by tab | MEDIUM | resolved |
| [119](119.md) | `cfg.zig` — `parseIfShell` doesn't handle escaped quotes | MEDIUM | resolved |
| [120](120.md) | `log.zig` — Data race on `log_fd` and `log_fd_failed` globals | MEDIUM | resolved |
| [121](121.md) | `socket_path.zig` — Fixed 128-byte buffer for HOME path with no fallback | MEDIUM | resolved |
| [122](122.md) | `mode_copy.zig` — Selection coordinates are screen-space, not grid-space | MEDIUM | resolved |
| [123](123.md) | `server/pty.zig` — Memory leak on partial `dupeZ` failure in `spawn` | MEDIUM | resolved |
| [124](124.md) | `server/pty.zig` — `writeInput` doesn't verify all bytes were written | MEDIUM | resolved |
| [125](125.md) | `server/pty.zig` — `reap` uses WNOHANG but unconditionally sets pid to -1 | MEDIUM | resolved |
| [126](126.md) | `server/render.zig` — `self.sy - 1` underflows when `sy == 0` | MEDIUM | resolved |
| [127](127.md) | `server/server.zig` — `findPaneAtNode` doesn't subtract border width | MEDIUM | resolved |
| [128](128.md) | `tty/tty.zig` — `cursorDown`/`cursorForward`/`drawLine` panic on zero dimensions | MEDIUM | resolved |
| [129](129.md) | `tty/tty.zig` — `setCursorStyle` blink/steady mapping is inverted | MEDIUM | resolved |
| [130](130.md) | `tty/tty.zig` — `writeCell` early return on combining char encode failure leaves `cx` stale | MEDIUM | resolved |
| [131](131.md) | `input.zig` — SOS/PM/APC string doesn't handle ESC \ (ST) terminator correctly | MEDIUM | resolved |
| [132](132.md) | `server/loop.zig` — `addFd` silently ignores duplicate fd without updating events/udata | MEDIUM | resolved |
| [133](133.md) | `server/server.zig` — `killSession` uses `swapRemove` — silently changes active session | MEDIUM | resolved |
| [134](134.md) | `server/server.zig` — `deinit` doesn't remove client fds from the event loop | MEDIUM | false_positive |
| [135](135.md) | `main.zig` — Command buffer over-allocated by 1 byte | LOW | resolved |
| [136](136.md) | `main.zig` — Unchecked `c.write` return for resize packet | LOW | resolved |
| [137](137.md) | `session.zig` — Window IDs are not unique after kills | LOW | resolved |
| [138](138.md) | `input.zig` — CSI private marker can appear after parameter digits | LOW | resolved |
| [139](139.md) | `key_binding.zig` — Force unwrap in `mapCommandToAction` may panic | LOW | resolved |
| [140](140.md) | `key_binding.zig` — `val >= 0` is always true for `u8` | LOW | resolved |
| [141](141.md) | `format.zig` — `splitArgs` always appends trailing segment even when empty | LOW | resolved |
| [142](142.md) | `format.zig` — `expandTruncate` integer overflow on large digit sequences | LOW | resolved |
| [143](143.md) | `colour.zig` — `parse` accepts trailing garbage after colour index | LOW | false_positive |
| [144](144.md) | `char_width.zig` — Dead code: C1 control check unreachable | LOW | resolved |
| [145](145.md) | `char_width.zig` — Dead code in `isCombining` | LOW | false_positive |
| [146](146.md) | `cfg.zig` — `set -u` silently dropped | LOW | resolved |
| [147](147.md) | `cfg.zig` — Combined flags like `-gw` misparsed | LOW | resolved |
| [148](148.md) | `client/raw.zig` — BRKINT left enabled in raw mode | LOW | resolved |
| [149](149.md) | `client/client.zig` — `recvPacket` doesn't validate msg_type | LOW | resolved |
| [150](150.md) | `tty/tty_key.zig` — Invalid UTF-8 lead bytes 0xC0–0xC1 accepted into multi-byte state | LOW | resolved |
| [151](151.md) | `tty/tty_key.zig` — Wheel left/right mouse buttons misidentified | LOW | resolved |
| [152](152.md) | `tty/tty.zig` — `writeCell` always advances `cx` by 1, ignoring wide character width | LOW | resolved |
| [153](153.md) | `cmd/cmd.zig` — `src_pane` declared `undefined` in `cmdJoinPane` | LOW | resolved |
| [154](154.md) | `server/server.zig` — `paneCwd` allocates memory with opaque ownership | LOW | resolved |
| [155](155.md) | `server/dispatch.zig` — `@intCast` from `usize` to `isize` can panic | LOW | resolved |
| [156](156.md) | `server/protocol.zig` — `Packet.make` integer overflow on large data | LOW | resolved |
| [157](157.md) | `server/socket.zig` — `bind` passes oversized `addrlen` | LOW | resolved |
| [158](158.md) | `status.zig` — Left and right sections can silently overlap | LOW | resolved |
| [159](159.md) | `server/render.zig` — Status bar column tracking doesn't account for escape sequences | LOW | resolved |
| [160](160.md) | `server/server.zig` — `loadConfigFile` — `@intCast(size)` from `c_long` to `usize` can panic | LOW | resolved |
| [161](161.md) | `integration.zig` — `setupServer` discards exec result | LOW | resolved |
| [162](162.md) | `mode_copy.zig` — `@intCast` of `history.items.len` (usize) to u32 | LOW | resolved |
| [163](163.md) | `server/socket.zig` — Wrong errno retrieval in `mapErr` (same as #103) | MEDIUM | resolved |
| [164](164.md) | `server/render.zig` — SGR buffer overflow with all 11 attributes + RGB fg/bg | CRITICAL | resolved |
| [165](165.md) | `server/render.zig` — `writeBytes` doesn't retry partial writes | HIGH | resolved |
| [166](166.md) | `main.zig` — Output write to stdout ignores errors and partial writes | HIGH | resolved |
| [167](167.md) | `server/render.zig` — `utf8Encode` `catch unreachable` for combining codepoints | MEDIUM | resolved |
| [168](168.md) | `server/pty.zig` — `execvp` assumes argv_z[0] is non-null | MEDIUM | resolved |
| [169](169.md) | Use-after-free in `windowTitleCallback` — `title_ctx` points to stack Window after heap copy | CRITICAL | resolved |
| [170](170.md) | Non-sixel DCS (tmux passthrough) body leaks into screen grid as literal text | MEDIUM | resolved |
| [171](171.md) | `catch unreachable` on CUP bufPrint — 32-byte buffer can overflow for very large terminals | CRITICAL | resolved |
| [172](172.md) | `catch unreachable` on window index formatting — 16-byte buffer can overflow | CRITICAL | resolved |
| [173](173.md) | `c.kill` SIGWINCH return silently discarded — child may miss resize | MEDIUM | resolved |
| [174](174.md) | Double force-unwrap on `session.active_window.?.active_pane.?` in server daemon | MEDIUM | resolved |
| [175](175.md) | Detach packet write return silently discarded — client may not receive detach | MEDIUM | resolved |
| [176](176.md) | Use-after-free / crash on OOM inside `server.zig` live clock ticking | CRITICAL | resolved |
| [177](177.md) | Memory leak on partial allocation failure inside `ChooseMode.enter()` | HIGH | resolved |
| [178](178.md) | `destroyPane` doesn't remove pty fd from event loop — fd leak / stale events | MEDIUM | resolved |
| [179](179.md) | Recursive `resizeNode` / `countLeavesNode` may overflow stack on deeply nested layouts | MEDIUM | resolved |
| [180](180.md) | `handleMouseFocus` `@intCast` from `usize` to `u32` can panic with oversized session name | LOW | resolved |
| [181](181.md) | Use-after-free in `Session.newWindow` — `title_ctx` points to stack Window after heap copy | CRITICAL | resolved |
| [182](182.md) | Sixel parser permanently stuck after 16 MiB buffer cap — DoS from missing `.dcs_discard` transition | HIGH | resolved |
| [183](183.md) | Escape key cannot cancel choose mode — InputReader never emits `.special.escape` for bare `0x1B` | MEDIUM | resolved |
| [184](184.md) | HUP re-registration window — data may arrive on pty fd while no poll handler is registered | LOW | resolved |
| [185](185.md) | `renderStatusBar` doesn't truncate long window names — writes past terminal width | MEDIUM | resolved |
| [186](186.md) | `IdentifyTerm` struct is dead on the wire — live client sends a raw string | MEDIUM | resolved |
| [187](187.md) | Reserved message types declared but never constructed or handled | LOW | resolved |
| [188](188.md) | No per-session attach selection in the wire protocol | MEDIUM | resolved |
| [189](189.md) | Protocol structs are not `packed` despite AGENTS.md claiming so | LOW | resolved |
| [190](190.md) | Inconsistent packet size limits across the three parsers | MEDIUM | resolved |
| [191](191.md) | Silent `else` branches drop unknown / ignored messages | LOW | resolved |
| [192](192.md) | `Packet.deserialize` requires exact buffer length — unsafe for streams | LOW | resolved |
| [193](193.md) | Sixel image width unknown — cursor advance uses an approximation | MEDIUM | resolved |
| [194](194.md) | Multi-pane sixel dropped — `rendered_ids` shared across panes | HIGH | resolved |
| [195](195.md) | Sixel overlay is never actually erased — `ECH` is ineffective, causing ghosting/smearing on scroll | HIGH | resolved |
| [196](196.md) | `force_clear` wipes the entire multiplexer display and is only propagated from the active pane | MEDIUM | resolved |
| [197](197.md) | Partially-scrolled images are hidden entirely, contradicting the design doc | MEDIUM | resolved |
| [198](198.md) | Copy-mode / scrollback sixel is silently lost after the 64-image ring wraps | MEDIUM | resolved |
| [199](199.md) | Pixel↔cell conversion hardcoded to 20px/row and 10px/col | MEDIUM | resolved |
| [200](200.md) | Redundant per-cell `dx`/`dy` storage in the 128-bit `Cell` | LOW | resolved |
| [201](201.md) | `eraseDisplay` `force_clear` triggered by any image in the registry, not the erased region | LOW | resolved |
| [202](202.md) | Sixel bleeds over the split border and gets stuck when scrolled above the pane | HIGH | resolved |
| [203](203.md) | `img2sixel` on an image larger than the pane wastes work and destroys scrollback | MEDIUM | resolved |
| [204](204.md) | First sixel ever displayed always gets extra lines (cell size measured too late) | MEDIUM | resolved |
| [205](205.md) | Closed PTY fds not removed from event loop on session/window kill — infinite 100% CPU busy-loop | CRITICAL | resolved |
| [206](206.md) | Stale Unicode width table — agent CLI symbols (✓ ★ ♥ arrows) misclassified width 1, cursor drifts | HIGH | resolved |
| [207](207.md) | Non-blocking display socket buffer truncation on EAGAIN — server event-loop spin (freeze + 100% CPU) | HIGH | resolved |
| [208](208.md) | renderToDisplayClient skips frame generation on successful display backlog flush | HIGH | resolved |
| [209](209.md) | SGR delta emission ignores default color resets — color bleeding on fastfetch / neofetch | MEDIUM | resolved |
| [210](210.md) | Host terminal auto-wrap (DECAWM) causes screen scrolling on bottom-right cell writes — scattered text and color remnants | HIGH | resolved |
| [211](211.md) | Overly broad emoji-presentation symbol width ranges in char_width.zig classify standard width-1 characters (✓, ✔, ★, ♥) as width-2, causing cursor drift and character remnants | HIGH | resolved |
| [212](212.md) | Pane-border loop clobbers the topmost pane's first content line | MEDIUM | resolved |
| [213](213.md) | Default `pane-border-format "#I"` renders blank | MEDIUM | resolved |
| [214](214.md) | `status.buildLine` left/right templates resolve to the LAST window, not the active one | MEDIUM | resolved |
| [215](215.md) | Pane-border format written byte-by-byte — corrupts UTF-8 / invalid codepoints | LOW | resolved |
| [216](216.md) | `Grid.scrollDown` pops newest history entry instead of oldest — corrupts history after compaction | CRITICAL | false_positive |
| [217](217.md) | `reflowCursorInternal` destroys old grid lines before new lines are committed — unrecoverable on OOM | CRITICAL | resolved |
| [218](218.md) | Sixel registry eviction (step 4) can evict still-referenced images — dangling cell references | CRITICAL | resolved |
| [219](219.md) | `shiftSixelAnchors` shifts images belonging to the wrong screen — alt/main anchor drift | CRITICAL | resolved |
| [220](220.md) | Pane swap (`swap_pane_up`/`swap_pane_down`) does not resize panes to their new positions | HIGH | resolved |
| [221](221.md) | Use-after-free in `runServerDaemon`: `default_pane` captured across async `server.run` calls | HIGH | resolved |
| [222](222.md) | New panes in existing sessions miss cell pixel size initialization — sixels use stale defaults | HIGH | resolved |
| [223](223.md) | `Screen.resize` uses main cursor position to compute alt grid cursor — alt cursor drifts | MEDIUM | resolved |
| [224](224.md) | `queryCellSize` blocks interactive client event loop for 200 ms on startup | MEDIUM | resolved |
| [225](225.md) | `isImageReferenced` performs O(total_cells × num_slots) scanning — linear search per sixel placement | LOW (performance) | resolved |
| [226](226.md) | Dangling pointer in status bar prompt rendering | CRITICAL | resolved |
| [227](227.md) | Socket write loop pegs CPU on 0-byte writes | CRITICAL | resolved |
| [228](228.md) | `Packet.deserialize` and `Packet.serialize` buffer panic hazards | CRITICAL | resolved |
| [229](229.md) | Terminal scrolling logic destroys scrollback history & fails on empty history | CRITICAL | resolved |
| [230](230.md) | `reflowCursorInternal` double-frees history, leaks memory, and corrupts ring buffer index | CRITICAL | resolved |
| [231](231.md) | Integer underflow panic in `Grid.clone()` | CRITICAL | resolved |
| [232](232.md) | Window/layout tree desync on last pane removal & window rotation | CRITICAL | resolved |
| [233](233.md) | Layout bound invariant violation on small pane splits and resizes | HIGH | resolved |
| [234](234.md) | Copy mode incremental search fails across soft-wrapped line boundaries | HIGH | resolved |
| [235](235.md) | Ghost character artifacts and dropped UTF-8 combining marks on soft wraps | HIGH | resolved |
| [236](236.md) | `SIGWINCH` signal handler missing `SA_RESTART` flag | HIGH | resolved |
| [237](237.md) | Memory leak of `DispatchResult` in prompt input processing | HIGH | resolved |
| [238](238.md) | Memory leaks in configuration directive parsing | HIGH | resolved |
| [239](239.md) | Memory leak on `Pane.init` failure during pane creation | HIGH | resolved |
| [240](240.md) | O(W×H) matrix scanning for Sixel images during rendering | MEDIUM (performance) | resolved |
| [241](241.md) | O(N) pixel-level border active checks inside render loop | MEDIUM (performance) | resolved |
| [242](242.md) | Heap allocation in `getCwd` PTY path resolution | MEDIUM (performance) | resolved |
| [243](243.md) | Duplicated layout tree traversal logic in server | LOW (code quality) | resolved |
| [244](244.md) | Duplicated pane swapping logic between up/down actions | LOW (code quality) | resolved |
| [245](245.md) | Non-compliance with AGENTS.md arena allocator lifecycle rule | LOW (architecture) | resolved |
| [246](246.md) | Non-compliance with AGENTS.md comptime command table dispatch rule | LOW (architecture) | resolved |
| [247](247.md) | Non-compliance with AGENTS.md mouse protocol scope rule | LOW (architecture) | false_positive |
| [248](248.md) | pane-border-format defaults to window index (#I) instead of pane index (#P) | LOW (cosmetic) | resolved |
| [249](249.md) | History restoration order inversion in `Grid.scrollDown` | CRITICAL | resolved |
| [250](250.md) | Inverted dimension assignment in `swapPaneRelative` | HIGH | resolved |
| [251](251.md) | Out-of-bounds `cursor_x` in soft-wrapped copy mode search | HIGH | resolved |
| [252](252.md) | Unimplemented Sixel matrix scanning optimization in `renderSixelImages` | MEDIUM (performance) | resolved |
| [253](253.md) | Sixel refcount residual leak on slot eviction in `placeSixelImage` | MEDIUM | resolved |
| [254](254.md) | Parent pane dimensions un-restored on split allocation failure | MEDIUM | resolved |
| [255](255.md) | Dead active-window variable loop in `status.buildLine` | LOW (code quality) | resolved |
| [256](256.md) | Dead session list re-validation loop in `runServerDaemon` | LOW (code quality) | resolved |
| [257](257.md) | Duplicated slot eviction loop in `placeSixelImage` | LOW (code quality) | resolved |
| [258](258.md) | `Packet.make` integer overflow risk on `5 + data.len` | LOW (safety) | resolved |
| [259](259.md) | Escaped backslash handling hazard in `unescapeQuoted` | LOW (correctness) | resolved |
| [260](260.md) | Denial of Service (CPU Exhaustion) via uncapped `CSI b` (`REP`) sequence | HIGH | resolved |
| [261](261.md) | Unbounded Memory Growth (OOM Vector) in OSC Control String Buffer | HIGH | resolved |
| [262](262.md) | Protocol Message Corruption on Partial Write in `sendRequestCellSize` | HIGH | resolved |
| [263](263.md) | Attempting to Free Static Slice in `findWordBreaks` | HIGH | resolved |
| [264](264.md) | Grid Reflow Trims CJK Padding Cells (`is_padding == true`) | MEDIUM | resolved |
| [265](265.md) | Cursor Column Clamped to Text Length During Reflow | MEDIUM | resolved |
| [266](266.md) | Memory Leak in `cmdDisplayMessage` on Error | MEDIUM | resolved |
| [267](267.md) | Memory Leak in `Pty.spawn` when `fork()` Fails | MEDIUM | resolved |
| [268](268.md) | Unfreed Window Memory in `Session.killWindow` | MEDIUM | false_positive |
| [269](269.md) | Potential Buffer Memory Leak in `addSixelImage` | MEDIUM | resolved |
| [270](270.md) | Array Write Without Bounds Check in `InputReader.feedCsi` | MEDIUM | resolved |
| [271](271.md) | Direct History Length Subtraction Bypasses Safety Bounds Check | MEDIUM | resolved |
| [272](272.md) | Out-of-Bounds Read in `findWordBreaks` (`libthai` Wrapper) | LOW | false_positive |
| [273](273.md) | Dead Range Check in `isCombining` Omits Hangul Jamo Marks | LOW | resolved |
| [274](274.md) | Unchecked `@intCast` in `combiningIndex` | LOW | resolved |
| [275](275.md) | Format Loop Bug in `appendWithStrftime` | LOW | resolved |
| [276](276.md) | O(M²) Re-evaluations in Copy Mode Search | LOW (performance) → MEDIUM (correctness regression in original fix) | resolved |
| [277](277.md) | `renderAll` cursor position unclamped to pane and terminal bounds — CUP writes outside pane area | MEDIUM | resolved |
| [278](278.md) | `insertLines` double-decrements sixel refcount of the discarded bottom line | CRITICAL | resolved |
| [279](279.md) | `deleteLines` decrements the refcount of the *preserved* bottom line | CRITICAL | resolved |
| [280](280.md) | `renderToDisplayClient` frees string literals via `pane_border_owned` | HIGH | resolved |
| [281](281.md) | `searchBackward` cyclic wrap (pass 2) skips the head of a wrapped logical line | HIGH | resolved |
| [282](282.md) | `processInput` use-after-free when a prompt command kills the session | HIGH | resolved |
| [283](283.md) | Dangling `mouse_autoscroll_pane` / `mouse_press_pane` after pane destruction | HIGH | resolved |
| [284](284.md) | `cmdRotateWindow` rotates the pane list but not the layout tree | HIGH | resolved |
| [285](285.md) | `setMessage` UAF / double-free on allocation failure | MEDIUM | resolved |
| [286](286.md) | `cmdMoveWindow` orphans the window when `insert` fails (OOM) | MEDIUM | resolved |
| [287](287.md) | `cmdBreakPane` / `cmdJoinPane` orphan the pane on failure after extraction | MEDIUM | resolved |
| [288](288.md) | `formatHelp` leaks `buf` on error | MEDIUM | resolved |
| [289](289.md) | `cmdResizePane` signed overflow on accumulated adjustments | MEDIUM | resolved |
| [290](290.md) | `handleMouseFocus` status-bar hit-testing doesn't match the rendered status line | MEDIUM | resolved |
| [291](291.md) | `decrementAltGridRef` is dead code — alt-screen sixel refcounts never decremented | MEDIUM (dead code / refcount drift) | resolved |
| [292](292.md) | `insertChars` / `deleteChars` refcount bookkeeping only covers the tail cells | MEDIUM | resolved |
| [293](293.md) | Raw history-length subtraction at remaining call sites bypasses `historyLen()` guard | LOW | resolved |
| [294](294.md) | `esc_buf` cleared at the top of `processInput` drops split escape sequences | LOW | resolved |
| [295](295.md) | `handleAccept` error paths leak fd / MessageReader | LOW | resolved |
| [296](296.md) | `newSession` leaks session internals if `sessions.append` fails | LOW | resolved |
| [297](297.md) | `out_buf` / `command_buf` unbounded growth with a non-reading client | LOW | resolved |
| [298](298.md) | Client freezes on a full stdout — blocking `writeAll` stalls input forwarding (mosh backpressure) | HIGH | resolved |
| [299](299.md) | `awaiting_cell_size` stdin forwarding overruns a 40-byte buffer — client crash / input corruption (regression from #298) | HIGH | resolved |
| [300](300.md) | getForegroundProcessName called every render for automatic_rename windows | MEDIUM | resolved |
| [303](303.md) | anyDisplayClientBehind() called 3+ times per render loop | LOW | resolved |
| [304](304.md) | pane_border format strings allocated per-pane per-client every render | MEDIUM | resolved |
| [305](305.md) | isPaneValid is O(N*M*P) called on every PTY event | LOW | resolved |
| [306](306.md) | collectPaneBounds allocates ArrayList on every call | LOW | false_positive |
| [307](307.md) | pane_border_format re-expanded every render even when unchanged | LOW | resolved |
| [308](308.md) | merged screen init/deinit path has unnecessary allocation checks | LOW | false_positive |
| [309](309.md) | status line built from scratch every render | LOW | resolved |
| [310](310.md) | tickAutoscroll traverses full session tree on every loop iteration | LOW | resolved |
| [311](311.md) | Multiline prompt cursor jumping and text scrambling during line editing | HIGH | resolved |
| [312](312.md) | Use-after-free in Server.processInput when action destroys active pane or session | CRITICAL | resolved |
| [313](313.md) | Window title callback calls allocator.free on Session arena | HIGH | resolved |
| [314](314.md) | Memory leak when expanding pane border format strings during rendering | HIGH | resolved |
| [315](315.md) | cmdMoveWindow orphans window and leaks memory on insert OOM rollback failure | HIGH | resolved |
| [316](316.md) | Sixel image refcounts leaked on vertical screen shrink in Screen.resize | HIGH | resolved |
| [317](317.md) | Sixel image refcounts leaked on grid history limit eviction | HIGH | resolved |
| [318](318.md) | Layout split failure leaves pane internal dimensions un-restored | HIGH | resolved |
| [319](319.md) | Desynchronization between Window.panes array rotation and Layout tree DFS rotation | HIGH | resolved |
| [320](320.md) | State desync on cmdJoinPane layout node lookup failure | HIGH | resolved |
| [321](321.md) | Uncapped loop in CSI 'Z' handler causes CPU exhaustion DoS | HIGH | resolved |
| [322](322.md) | Synchronous blocking write in server response dispatch halts main loop | HIGH | resolved |
| [323](323.md) | Dummy pane allocation wasted in cmdBreakPane | MEDIUM | resolved |
| [324](324.md) | cmdRenameWindow leaks window name memory into session arena | MEDIUM | resolved |
| [325](325.md) | Option set -u directive silently ignored in configuration parser | MEDIUM | resolved |
| [326](326.md) | Substring flag matching and combined flag failure in mapCommandToAction | MEDIUM | resolved |
| [327](327.md) | Copy mode single-line backward selection yank failure | MEDIUM | resolved |
| [328](328.md) | Format string truncation specifier slices UTF-8 codepoints | MEDIUM | resolved |
| [329](329.md) | Missing OSC discard transition on buffer overflow causes input injection | MEDIUM | resolved |
| [330](330.md) | Input parser drops interrupting Escape (0x1B) control bytes | MEDIUM | resolved |
| [331](331.md) | SIGWINCH configured with SA_RESTART delays client resize redraws | MEDIUM | resolved |
| [332](332.md) | Recursive layout tree traversals risk stack overflow on deep split hierarchies | MEDIUM | resolved |
| [333](333.md) | O(L^2) re-evaluation loop during Thai line rewrapping | MEDIUM | resolved |
| [334](334.md) | Dropped keystroke on interrupted UTF-8 continuation sequence | LOW | resolved |
| [335](335.md) | Command table execution uses function pointer dispatch violating AGENTS.md | LOW | resolved |
| [336](336.md) | Duplicated key binding flag parsing loop in cfg.zig | LOW | resolved |
| [337](337.md) | Duplicated target window index resolution in cmd.zig | LOW | resolved |
| [338](338.md) | Redundant status line string duplication per render frame | LOW | resolved |
| [339](339.md) | `catch {}` silent error suppression — 91 instances (Zig 0.16 rule #6) | HIGH | resolved |
| [340](340.md) | `std.StringHashMap` / `std.AutoHashMap` managed — false positive, still exists | HIGH | false_positive |
| [341](341.md) | `initCapacity` not deprecated but code modernized to `.empty` + `ensureTotalCapacity` | HIGH | resolved |
| [342](342.md) | `std.ArrayList.toOwnedSlice()` removed — false positive, still exists | HIGH | false_positive |
| [343](343.md) | `std.c.getenv()` in main.zig → `init.environ_map` (partial fix) | MEDIUM | resolved |
| [344](344.md) | `main()` returns `void` instead of `!void` (Zig 0.16 rule #1) | LOW | resolved |
| [345](345.md) | `std.process.Args.Iterator` is pre-0.16; should use `toSlice(arena)` | MEDIUM | resolved |
| [346](346.md) | Missing `io` param — false positive, raw POSIX syscall codebase | MEDIUM | false_positive |
| [347](347.md) | `reflowCursorInternal` trims trailing empty screen lines during copy-mode entry, shifting visible grid down and corrupting prompt | HIGH | resolved |
| [348](348.md) | `#[default]` in `window-status-current-format` resets terminal background and drops status bar background color | MEDIUM | resolved |
| [349](349.md) | Ctrl+J decoded as Enter — coding agents send instead of newline (user-reported) | CRITICAL | resolved |
| [350](350.md) | No escape-time timer: lone ESC delivered as Alt+next-key | HIGH | resolved |
| [351](351.md) | Modified tilde keys (`\x1b[3;5~`) silently dropped by client-side pre-parse | HIGH | resolved |
| [352](352.md) | Kitty functional-key codepoints mapped to wrong keys (57344-57347 are Escape/Enter/Tab/BS, not arrows) | MEDIUM | resolved |
| [353](353.md) | Root key table (`bind-key -n`) never consulted; prefix machine duplicated 3× with drift | HIGH | resolved |
| [354](354.md) | Remote panic: SGR indexed-colour `@intCast(u32→u8)` ×6 sites | CRITICAL | resolved |
| [355](355.md) | Remote panic: modifyOtherKeys extkeys `@intCast(u32→u8)` | CRITICAL | resolved |
| [356](356.md) | Remote panic: sixel raster attribute parse overflows u32 | CRITICAL | resolved |
| [357](357.md) | `cmdLoadBuffer` invalid free of static pointer with stale capacity | CRITICAL | resolved |
| [358](358.md) | Auto window rename: invalid free of name_buf-owned string + aliased double-free | CRITICAL | resolved |
| [359](359.md) | Clock mode clones full grid+history every second; arena never reclaimed | HIGH | resolved |
| [360](360.md) | Scrollback eviction never reclaims memory (arena no-op frees) | HIGH | resolved |
| [361](361.md) | saved_grid churn leaks one grid clone per mode toggle | HIGH | resolved |
| [362](362.md) | Stale poll events after killSession in same batch dereference freed pane memory | HIGH | resolved |
| [363](363.md) | OSC52 payloads unbounded size + paste-buffer list unbounded count | HIGH | resolved |
| [364](364.md) | remain-on-exit closes pty master without removeFd → POLLNVAL busy-loop | HIGH | resolved |
| [365](365.md) | kill-window leaks pty poll registrations | MEDIUM | resolved |
| [366](366.md) | Layout destroys pane, then caller writes `pane.valid` and deinits again | MEDIUM | resolved |
| [367](367.md) | merged_screen dangling-non-null when Screen.init fails after deinit | MEDIUM | resolved |
| [368](368.md) | LF/IND inside scroll region bypasses region scrolling, corrupting scrollback | HIGH | resolved |
| [369](369.md) | Region-cleared lines keep stale `wrapped` flag, corrupting later rewrap | HIGH | resolved |
| [370](370.md) | CUF/CUB/back-tab wrap across edges incorrectly, breaking third-party TUIs | HIGH | false_positive |
| [371](371.md) | Reflow result ignores history_limit → unbounded scrollback on narrow resizes | HIGH | resolved |
| [372](372.md) | Resize leaves scroll region and saved cursor out of bounds | MEDIUM | resolved |
| [373](373.md) | Benign EAGAIN on non-blocking display sockets disconnects clients | MEDIUM | resolved |
| [374](374.md) | Detach reply blocking-style write on non-blocking fd: truncated/dropped | MEDIUM | resolved |
| [375](375.md) | Client trusts packet length with no upper bound → unbounded buffering stall | MEDIUM | resolved |
| [376](376.md) | Command responses silently dropped when display client marked behind → hang | MEDIUM | resolved |
| [377](377.md) | Stray ESC inside OSC swallows next byte, corrupting following sequence | MEDIUM | resolved |
| [378](378.md) | Listener socket: unconditional unlink steals endpoint; /tmp fallback lacks chmod | MEDIUM | resolved |
| [379](379.md) | Single click in copy-mode yanks empty selection and exits copy-mode | MEDIUM | resolved |
| [380](380.md) | Six call sites bypass the historyLen() guard (regression surface of #293) | MEDIUM | resolved |
| [381](381.md) | Copy-mode g/G asymmetric: g only reaches top of current viewport | MEDIUM | resolved |
| [382](382.md) | load-buffer lacks MAX_PASTE_SIZE cap while paste-buffer enforces one | MEDIUM | resolved |
| [383](383.md) | Bright colour names encode index+90 as palette index — renders cube colours | MEDIUM | resolved |
| [384](384.md) | mode-keys option ignored: emacs copy-mode unreachable, default disagrees with behaviour | MEDIUM | resolved |
| [385](385.md) | Small unbounded arena accumulators: Pane.cwd was write-only (deleted), Session.rename uses inline buffer | LOW | resolved |
| [386](386.md) | Grid/screen hygiene cluster: :720 guarded + contracts documented (shiftDown/cursor/dirty-flags deferred with notes) | LOW | resolved |
| [387](387.md) | Sixel overlay tracking: render cap raised to 32; SU shifts anchors by n; SD shifts too | LOW | resolved |
| [388](388.md) | Parser fidelity cluster: 8-bit C1 misroutes, ESC ESC \ in sixel, CSI param cap 16, XTSMGRAPHICS over-claim | LOW | resolved |
| [389](389.md) | IPC/tty hygiene cluster: client socket not cloexec, packetType enumFromInt panic, Packet.make desync, setRaw parity | LOW | resolved |
| [390](390.md) | Non-global `set prefix` changes display but not dispatcher behaviour | MEDIUM | resolved |
| [391](391.md) | Command robustness cluster: break-pane err-after-relocate, split proportion validation, resize veto, save-buffer EINTR, bind-key feedback | LOW | resolved |
| [392](392.md) | Dead code inventory: getCellAt, search_active, adjustSelectionForAutoScroll removed; inline-for/#335 and identify_term kept deliberately | LOW | resolved |
| [393](393.md) | Performance cluster: O(n·m) backward search, per-match rescan, linear lookups vs comptime tables, per-frame allocator churn | LOW | resolved |
| [394](394.md) | char_width/thai/clock robustness cluster: partial table application, negative-index cast, pre-epoch panic (globals rule deferred) | LOW | resolved |
| [395](395.md) | Pty.spawn: #267's errdefer and defer both free szn_env_z/szn_pane_z/cwd_z — double-free on fork() failure | CRITICAL | resolved |
| [396](396.md) | border_format_cached expanded with the session arena but freed with the server GPA on cache invalidation | CRITICAL | resolved |
| [397](397.md) | Format substitute with an empty pattern aborts the server (replaceOwned panics on a zero-length needle; config/prompt DoS) | CRITICAL | resolved |
| [398](398.md) | Window.init/addPane double-destroy the Pane when Pane.init fails (#239 incomplete fix) | HIGH | resolved |
| [399](399.md) | addSixelImage errdefer frees dcs_bytes after placeSixelImage stored it in the slot (#269 ownership inversion) | HIGH | resolved |
| [400](400.md) | Stale PTY poll event removeFd(ev.fd) unregisters a recycled fd's NEW owner (frozen pane; POLLNVAL guard missing) | HIGH | resolved |
| [401](401.md) | Render errors permanently lose updates: last_cells committed pre-emit, dirty cleared despite the error | HIGH | resolved |
| [402](402.md) | Display out-queue atomicity: split header/body enqueue, frame build clears queued replies, detach packet freed pre-flush | HIGH | resolved |
| [403](403.md) | sendResponse busy-spins forever on EAGAIN from an O_NONBLOCK display fd — one stalled client freezes the server (#322 regression) | HIGH | resolved |
| [404](404.md) | isPaneValid regression: #362 fix reintroduced the O(N·M·P) walk #305 removed, run per PTY event with extra scans | MEDIUM | resolved |
| [405](405.md) | Resize reflow clones grid+history+scratch per width change from the session arena — nothing reclaimed (#360/#361 class) | MEDIUM | resolved |
| [406](406.md) | Sixel accounting cluster: ref_inc counts unplaced markers, overwrite without decrement, lost eviction hooks, stale eraseDisplay geometry, id-masking refcheck | MEDIUM | resolved |
| [407](407.md) | Zero-window sessions permanently bricked (no recovery command); bare kill-session kills all sessions vs its description | MEDIUM | resolved |
| [408](408.md) | Prompt-path kill-session never stops the server with zero sessions (IPC path does) | MEDIUM | resolved |
| [409](409.md) | Keystrokes dropped: search-mode break discards packet remainder; client sd_buf too small → serialize sends nothing (#299 follow-up) | MEDIUM | resolved |
| [410](410.md) | BufferList.delete swapRemove breaks the newest-at-0/oldest-at-last contract of get/evict; generateName empty-name wrap | MEDIUM | resolved |
| [411](411.md) | reapZombies leaves stale Pty.pid → deinit SIGKILLs a recycled pid; Pty.deinit double-close (master not nulled) | MEDIUM | resolved |
| [412](412.md) | Peer resize: unbounded u32 dims, partial-failure geometry desync, status row subtracted when status off | MEDIUM | resolved |
| [413](413.md) | cmdJoinPane error path strands panes after ownership moved (violates the #287 invariant) | MEDIUM | resolved |
| [414](414.md) | TemplateCache (ptr,len) identity aliases reused arena blocks → stale compiled ops, silently wrong expansions | MEDIUM | resolved |
| [415](415.md) | Config scope/flag surface parsed but discarded (set -s/-w, bind -r, set-environment, if-shell); combined short options misparse | MEDIUM | resolved |
| [416](416.md) | Copy-mode selection end anchor not scroll-compensated while start is — selection slides off content on wheel scroll | MEDIUM | resolved |
| [417](417.md) | Bare split-window default direction differs by dispatch path (bind-key vertical vs CLI horizontal) | MEDIUM | resolved |
| [418](418.md) | Detached clients keep a live control channel (fd stays in client_fds after .detach) | LOW | resolved |
| [419](419.md) | Region scroll paths leave stale wrapped=true on the blanked line (#369 follow-up: swap-chain sites) | LOW | resolved |
| [420](420.md) | forceReflow feeds the main cursor into the alt-grid reflow and discards the clamped result | LOW | resolved |
| [421](421.md) | Grid.copyVisibleFrom indexes both rings physically — clock-mode background output desyncs the overlay | LOW | resolved |
| [422](422.md) | DECSET 1003 aliased onto the 1000 flag; mode.mouse_utf8 dead field | LOW | resolved |
| [423](423.md) | Resource-bound cluster: config source recursion, no client cap, 16 MiB parser vs 8 MiB screen sixel cap | LOW | resolved |
| [424](424.md) | Dead code inventory round 2: stale Term/FdWriter, never-entered parser states, write-only fields, serializer suite, server.zig.orig | LOW | resolved |
| [425](425.md) | Performance cluster 2: defeated status cache, per-frame recompiles, per-keystroke scrollback rebuild, runtime binding scans vs comptime mandate | LOW | resolved |
| [426](426.md) | Robustness residuals cluster: 2 unguarded history subtractions, OOM errdefer ordering, socket/TMP, misc input/parse hardening | LOW | resolved |
| [427](427.md) | Mouse wheel in Alternate Screen forces copy-mode on empty/stale scrollback instead of forwarding arrow keys | MEDIUM | resolved |
| [428](428.md) | Use-after-free of MessageReader in handleClient packet loop | HIGH | resolved |
| [429](429.md) | DCS '$ q' (DECRQSS) misrouted to the sixel parser | HIGH | resolved |
| [430](430.md) | kitty 'u' protocol returns .char, never matches .special/.arrow/.function bindings | MEDIUM-HIGH | resolved |
| [431](431.md) | Render output bypasses appendClientOut, defeating display flow control | MEDIUM-HIGH | resolved |
| [432](432.md) | Status-bar visibleLen counts codepoints, not cells; wide-char window names mis-hit | MEDIUM | resolved |
| [433](433.md) | Pane-border-format cache invalidated only on option change, not resize/split | MEDIUM-HIGH | resolved |
| [434](434.md) | Region scroll paths skip shiftSixelAnchors, desyncing sixel anchors | MEDIUM | resolved |
| [435](435.md) | Screen.resize leaves sixel anchor_row stale for images below new height | MEDIUM | resolved |
| [436](436.md) | Command parser has no quote/escape handling; quoted multi-word args mis-tokenize | MEDIUM | resolved |
| [437](437.md) | load-buffer fails on EINTR instead of retrying read() | MEDIUM | resolved |
| [438](438.md) | new-session leaves a half-created session attached on setupPane failure | MEDIUM | resolved |
| [439](439.md) | Pty.allocator is 'undefined' until spawn(); deinit non-idempotent | LOW | resolved |
| [440](440.md) | Global window status options rejected by scope routing and status cache freeze on active window switch | HIGH | resolved |
| [441](441.md) | Status cache invalidation lag and missing state change triggers causing delayed status bar updates | HIGH | resolved |
| [442](442.md) | Automatic window renaming latency from fixed 1000ms polling rate-limit | LOW | resolved |
| [443](443.md) | Raw history index arithmetic in render.zig and mode_copy.zig accesses out of bounds or displays stale lines when history ring wraps | HIGH | resolved |
| [444](444.md) | History ring defensive guards index empty list out of bounds and getHistoryLineMut is dead code with broken guard | LOW | resolved |
| [445](445.md) | variation-selector-always-wide promotes the pair even when VS16 was silently dropped (both comb slots full); render lookahead drifts on width-1+padding without VS16 | MEDIUM | resolved |
| [446](446.md) | VS16 promotion erase sites skip the sixel refcount decrement (bug #225 convention) | LOW | resolved |
| [447](447.md) | Term.drawLine trailing clearToEOL lands on the second host cell of a line-ending VS16 emoji | LOW | resolved |
| [448](448.md) | handleClient .command case writes the response to fd before re-validating that the client still exists (guard runs one dispatch too late) | MEDIUM | resolved |
| [449](449.md) | killSession / killAllSessions destroy panes without clearing pane.valid; isPaneValid can alias an arena-reused address | LOW | resolved |
| [450](450.md) | display_clients is an ArrayList of values; every \|*dc\| loop holds a pointer into the backing buffer that a registerDisplayClient append would invalidate | LOW | resolved |
| [451](451.md) | DECSTBM full-screen scroll region trap in Screen.setScrollRegion discards scrolled-off lines instead of pushing to history | HIGH | resolved |
| [452](452.md) | Grid.resize drops bottom rows via pop() on height reduction instead of scrolling top rows into history | MEDIUM | resolved |
| [453](453.md) | reflowCursorInternal trims trailing screen rows on width change, stealing history lines into visible screen | MEDIUM | false_positive |
| [454](454.md) | Screen.flushPendingSixel leaks pending sixel data when cell size unknown | MEDIUM | resolved |
| [455](455.md) | Grid.setHistoryLimit double-frees history lines on compaction OOM | HIGH | resolved |
| [456](456.md) | BufferList.pushOwned leaks name and data on insert OOM | MEDIUM | resolved |
| [457](457.md) | Dead errdefer in set-buffer path leaks generated name on OOM | MEDIUM | resolved |
| [458](458.md) | Cmd.parse leaks current token when arg_list.append fails | LOW | resolved |
| [459](459.md) | Grid.initWithLimit leaks lines buffer when resize fails | LOW | resolved |
| [460](460.md) | Dead errdefers in paneClipboardCallback (void function) | LOW | resolved |
| [461](461.md) | cmdJoinPane placeholder pane never deinited (arena bloat) | MEDIUM | resolved |
| [462](462.md) | Grid.insertChars/clearArea width-1 underflows when width is 0 | MEDIUM | resolved |
| [463](463.md) | Screen TAB handling underflows on zero width and can divide by zero | MEDIUM | resolved |
| [464](464.md) | Sixel placement ceil-div wraps and bypasses the oversize drop | MEDIUM | resolved |
| [465](465.md) | SGR 38;2/48;2 wraps out-of-range RGB with mod 256 instead of ignoring | LOW | false_positive |
| [466](466.md) | modifyOtherKeys extkeys truncates wire value despite no-truncate comment | MEDIUM | false_positive |
| [467](467.md) | Unvalidated layout proportion reaches @intFromFloat and can panic | HIGH | resolved |
| [468](468.md) | Layout bounds math exceeds parent on tiny panes | MEDIUM | resolved |
| [469](469.md) | Copy-mode placeCursorAtLogical leaves cursor_y unclamped with unchecked casts | MEDIUM | resolved |
| [470](470.md) | Copy-mode getCellAtY_i64 can overflow on extreme offsets | LOW | resolved |
| [471](471.md) | Loop.pollOnce returns address of stack temporary for empty poll | LOW | resolved |
| [472](472.md) | Dispatch write loops slice with @intCast(n) without clamping to remaining | LOW | resolved |
| [473](473.md) | Screen sixel geometry casts u32 height to i32 and can panic | LOW | resolved |
| [474](474.md) | SGR mouse parser accepts trailing fields and unclamped coordinates | MEDIUM | resolved |
| [475](475.md) | Uncapped server-to-client frame can exceed the client packet cap | MEDIUM | resolved |
| [476](476.md) | Performance cluster 3: per-frame O(cells) taxes, quadratic reflow, per-frame allocs | MEDIUM | resolved |
| [477](477.md) | Duplication and dead-code cluster 3: mirrored handlers, triplicated split math, write-only dirty flags | LOW | resolved |
| [478](478.md) | feedPty feeds the input parser byte-by-byte: 4096 state-machine dispatches per PTY read | MEDIUM | resolved |
| [479](479.md) | isPaneValid regression: O(N·M·P) tree walk per PTY event, plus full-tree scans in pumpPaneInput and tickSixelWait every loop tick | MEDIUM | resolved |
| [480](480.md) | Render diff loop formats SGR escape sequences per changed cell with std.fmt.bufPrint | LOW | resolved |
| [481](481.md) | renderContent does a full O(rows×cols) diff of last_cells every frame even when few lines changed | MEDIUM | resolved |
| [482](482.md) | display-client render frames copy the whole frame into dc.out_buf instead of writing render_buf directly to the socket | LOW | resolved |
| [483](483.md) | space cells emit one byte() write each; consecutive blank runs should batch | LOW | resolved |
| [484](484.md) | expandTruncateInto slice-out-of-bounds panic on malformed UTF-8 in status format values | CRITICAL | resolved |
| [485](485.md) | eraseChars: cx + n overflows u32 on untrusted CSI param, panicking the server | CRITICAL | resolved |
| [486](486.md) | Pty.deinit SIGKILLs the child PID unconditionally: PID-reuse race can kill an unrelated process | HIGH | resolved |
| [487](487.md) | runServerDaemon closes fd 0 twice: open("/dev/null") returns fd 0, leaving the daemon with stdin closed | HIGH | resolved |
| [488](488.md) | connectProbeUnix treats all errors as stale socket: fd exhaustion unlinks a live server's socket (split-brain) | HIGH | resolved |
| [489](489.md) | kitty CSI u parser drops the event-type field: key releases become phantom presses | MEDIUM | resolved |
| [490](490.md) | OSC 52 forward path allocates and queues before the MAX_PASTE_SIZE check (memory amplification) | MEDIUM | resolved |
| [491](491.md) | VS16 promotion undercounts the sixel refcount: slot can be reused while a live marker references it | MEDIUM | resolved |
| [492](492.md) | scrollUpInRegion/scrollDownInRegion shift sixel anchors outside the scroll region | MEDIUM | resolved |
| [493](493.md) | eraseDisplay 0/1 removes straddling sixel images but leaves stale marker cells with dead ids | MEDIUM | resolved |
| [494](494.md) | Grid.scrollUp spare-slot branch overwrites a live line when the ring is physically full | MEDIUM | resolved |
| [495](495.md) | renderContent drops the last content row when the status bar is disabled | MEDIUM | resolved |
| [496](496.md) | cell_size wire message stores unvalidated u32s server-wide | MEDIUM | resolved |
| [497](497.md) | test helper setRaw hardcodes macOS termios cc indices (VMIN/VTIME), wrong slots on Linux | LOW | resolved |
| [498](498.md) | client silently exits 0 when setRaw fails (raw.setRaw() catch return) | LOW | resolved |
| [499](499.md) | InputParser.deinit takes an arbitrary allocator but every allocation uses screen.allocator | LOW | resolved |
| [500](500.md) | tty.Term.setAttributes emits a bare SGR reset on sixel-bit-only change without nulling fg/bg (latent) | LOW | resolved |
| [501](501.md) | placeSixelImage errdefer drops the slot without freeing image bytes (latent ownership trap) | LOW | resolved |
| [502](502.md) | findThaiClusterEnd splits เ-าะ compound vowel syllables (leaves ะ as orphaned cluster) | MEDIUM | resolved |
| [503](503.md) | cellHasMaiHanAkat raw-codepoint check compares table index to raw codepoint | LOW | resolved |
| [504](504.md) | libthai loader and break context lack thread-safety synchronization (latent) | LOW | resolved |
| [505](505.md) | text_reflow.md references non-existent src/reflow.zig and omits libthai integration | LOW | resolved |
| [506](506.md) | `codepoint-widths` is process-global but registered as a session option; one session's override mutates all sessions and a second session's assignment erases the first's | HIGH | resolved |
| [507](507.md) | AGENTS.md and architecture.md assert "No global state" while eleven mutable module globals exist | LOW (architecture) | resolved |
| [508](508.md) | README.md claims 1,032 tests passing; the suite is 1,035 (1,034 passing, 1 skipped) | LOW (correctness) | resolved |
| [509](509.md) | `.workbuddy-ai/` agent memory files are untracked but absent from .gitignore | LOW (safety) | resolved |
| [510](510.md) | log.zig gates a non-atomic `log_fd` global with an atomic flag rather than a lock (fd-reuse hazard, latent) | LOW (safety) | resolved |
| [511](511.md) | resize-pane mutates only the pane grid, never the layout tree, so the resize is clipped and reverted | HIGH | open |
| [512](512.md) | capture-pane emits NUL bytes for every blank and wide-char padding cell | HIGH | open |
| [513](513.md) | IRM (insert mode) shift decrements sixel refcounts for moved markers without re-incrementing them | MEDIUM | open |
| [514](514.md) | char_width classifies U+00A0 (NO-BREAK SPACE) as zero-width, silently dropping it | MEDIUM | open |
| [515](515.md) | BufferList.pushOwned's #456 errdefer double-frees against the caller's own errdefers | MEDIUM | open |
| [516](516.md) | numeric-valued choice options cannot be set: `set -g status 2` fails, clock-mode-style is unusable | MEDIUM | open |
| [517](517.md) | list-keys prints enum tag names, so its output is not a valid config and cannot be re-sourced | MEDIUM | open |
| [518](518.md) | thirteen option-table entries are inert: accepted, stored, and listed by show-options but read by nothing | LOW | open |
| [519](519.md) | the two SGR attribute tables disagree on double-underline: tty.zig emits 21, render.zig emits 4:2 | LOW | open |
| [520](520.md) | duplication cluster 4: five hand-rolled non-blocking write loops, byte-identical Layout.removePane/extractPane, mirrored vi/emacs copy-mode keymaps, and 30 copies of the active-target prologue | LOW (code quality) | open |
| [521](521.md) | processInput keeps reading MessageReader.buf after a detach keybinding frees the reader (the #428 fix covers the consume path but not the read path) | HIGH | open |
| [522](522.md) | the display client `behind` flag is never cleared when the out-buffer backlog is force-dropped, permanently starving that client | MEDIUM | open |
| [523](523.md) | DECSET/DECRST 6 (DECOM, origin mode) is not wired, so all origin-mode handling is unreachable | MEDIUM | open |
| [524](524.md) | NEL (0x85) performs IND only, so it does not reset the column to 0 | MEDIUM | open |
| [525](525.md) | cursorPosition's origin-mode row addition is non-saturating, unlike its sibling cursorLine | LOW | open |
| [526](526.md) | CBT (`CSI Z`) divides by tab_stop without the zero guard added for bug #463 | LOW | open |
| [527](527.md) | client/raw.zig uses macOS VMIN/VTIME indices on FreeBSD (16/17), where 4/5 are VWERASE/VKILL | LOW | open |
| [528](528.md) | Window.splitPane mutates the layout tree before appending to window.panes, so an OOM append desyncs them | MEDIUM | open |
| [529](529.md) | AGENTS.md claimed version @hasField gates live only in build.zig, contradicted by four OS-ABI gates in the tree | LOW (correctness) | resolved |
