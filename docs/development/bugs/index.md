---
type: index
title: "Bug Tracker — szn"
description: "Individual bug entries for szn, one file per bug."
timestamp: 2026-08-03T00:00:00Z
---

# Bugs — szn

Sorted by number. See individual bug files for details.

> **Note:** Bugs **#301** and **#302** were never filed (MIA). The #300–#310 performance sweep skipped straight from #300 to #303, so the tracker covers #1–#300 and #303–#338 — 336 bugs total.

## Summary by Severity

| Severity | Count |
|---|---:|
| CRITICAL | 42 |
| HIGH | 81 |
| MEDIUM | 112 |
| LOW | 83 |
| LOW (architecture) | 3 |
| LOW (code quality) | 5 |
| LOW (correctness) | 1 |
| LOW (cosmetic) | 1 |
| LOW (performance) | 1 |
| LOW (performance) → MEDIUM (correctness regression in original fix) | 1 |
| LOW (safety) | 1 |
| MEDIUM (dead code / refcount drift) | 1 |
| MEDIUM (performance) | 4 |
| **Total** | **336** |

## Summary by Status

| Status | Count |
|---|---:|
| Fixed | 294 |
| False Positive | 14 |
| Intentional | 1 |
| Open | 27 |
| **Total** | **336** |

## All Bugs

| # | Title | Severity | Status |
|---|---|---|---|
| [1](001.md) | Use-after-free in Session.rename() | CRITICAL | Fixed |
| [2](002.md) | Invalid-free of string literal in dispatch | CRITICAL | Fixed |
| [3](003.md) | Stack overflow when >64 fds registered | CRITICAL | Fixed |
| [4](004.md) | Pane memory leak on Window.deinit | CRITICAL | False Positive |
| [5](005.md) | cmdKillPane leaks killed pane | CRITICAL | False Positive |
| [6](006.md) | cmdJoinPane leaks dummy pane | CRITICAL | False Positive |
| [7](007.md) | Child process inherits all parent fds after fork | CRITICAL | Fixed |
| [8](008.md) | reverseIndex emits wrong escape sequence | CRITICAL | Fixed |
| [9](009.md) | Memory leak in Grid.scrollDown() | HIGH | Fixed |
| [10](010.md) | Colour.fmt() reads uninitialized memory | HIGH | Fixed |
| [11](011.md) | Memory leak in Options.set() | HIGH | Fixed |
| [12](012.md) | Dangling pointer in Context.set() | HIGH | Fixed |
| [13](013.md) | Copy mode broken for scrolled content | HIGH | Fixed |
| [14](014.md) | Emacs alt-key bindings are dead code | HIGH | False Positive |
| [15](015.md) | Key value parsing in config is a stub | MEDIUM | Fixed |
| [16](016.md) | Unsafe union access on OptionValue | MEDIUM | Fixed |
| [17](017.md) | Child uses parent allocator after fork | CRITICAL | Fixed |
| [18](018.md) | OSC ST terminator (ESC \) broken | HIGH | Fixed |
| [19](019.md) | No bounds check on CSI input buffer | MEDIUM | Fixed |
| [20](020.md) | EAGAIN treated as EOF in interactive client | HIGH | Fixed |
| [21](021.md) | CSI dispatch warn floods logs | LOW | Fixed |
| [22](022.md) | cmdRenameWindow use-after-free | CRITICAL | Fixed |
| [23](023.md) | No SIGCHLD handler — zombie window | MEDIUM | Fixed |
| [24](024.md) | processReadStdin leaks the input buffer on each call | MEDIUM | Fixed |
| [25](025.md) | handleMouseFocus can use freed Pane pointer | HIGH | Fixed |
| [26](026.md) | paneList doesn't filter by session | MEDIUM | Fixed |
| [27](027.md) | FdWriter.writeByte ignores zero-write | MEDIUM | Fixed |
| [28](028.md) | No bounds check in client.sendIdentify | HIGH | Fixed |
| [29](029.md) | Log file opened/closed on every log call | LOW | Fixed |
| [30](030.md) | Unimplemented config directives | MEDIUM | Fixed |
| [31](031.md) | Directional pane selection is actually circular | MEDIUM | Fixed |
| [32](032.md) | .last_window doesn't track actual last window | MEDIUM | Fixed |
| [33](033.md) | Kitty keyboard protocol incomplete | MEDIUM | Fixed |
| [34](034.md) | split-window direction flag only works as first arg | MEDIUM | Fixed |
| [35](035.md) | Hardcoded log path `/tmp/szn.log` | LOW | Fixed |
| [36](036.md) | Error set is a single catch-all | LOW | Fixed |
| [37](037.md) | Arena allocation not used | MEDIUM | Fixed |
| [38](038.md) | Duplicate fd registration allowed in event loop | MEDIUM | Fixed |
| [39](039.md) | cmdPrevWindow has duplicate dead code | LOW | Fixed |
| [40](040.md) | attrFields/attrCodes parallel arrays fragile | LOW | Fixed |
| [41](041.md) | Tab stop hardcoded to 8 | LOW | Fixed |
| [42](042.md) | History limit hardcoded to 2000 | LOW | Fixed |
| [43](043.md) | cmdCopyMode overwrites previous copy mode without deinit | LOW | False Positive |
| [44](044.md) | resize-pane can't set size below 1 | LOW | Fixed |
| [45](045.md) | sockaddr_un path size hardcoded to 104 | LOW | Fixed |
| [46](046.md) | message_reader silently truncates on buffer full | LOW | Fixed |
| [47](047.md) | mapCommandToAction can match substrings | MEDIUM | Fixed |
| [48](048.md) | `mapCommandToAction` rejects commands with arguments — most config bind-key directives fail silently | CRITICAL | Fixed |
| [49](049.md) | Line-wrapping fires `grid.scrollUp()` instead of `scrollUpInRegion()` — breaks DECSTBM scroll regions | CRITICAL | Fixed |
| [50](050.md) | Double-underline and curly-underline both render as plain underline (SGR 4) | HIGH | Fixed |
| [51](051.md) | `key.format` — `alt` and `meta` modifiers collide on `M-` prefix | HIGH | Fixed |
| [52](052.md) | `feedPty` + `handlePtyEvent` race: PTY deinited in two different code paths | HIGH | Fixed |
| [53](053.md) | Mouse escape sequence bytes leak to child PTY when pane doesn't want mouse events | HIGH | Fixed |
| [54](054.md) | `split-window -h` (exactly, no trailing args) maps to vertical split | MEDIUM | False Positive |
| [55](055.md) | Log file fd shared between parent and child after fork — garbled logs | MEDIUM | Fixed |
| [56](056.md) | `destroyPane` iterates `self.sessions` while `killSession` `swapRemove`s from it | MEDIUM | Fixed |
| [57](057.md) | `handlePtyEvent` casts `udata` pointer without validation — potential stale pointer | MEDIUM | Fixed |
| [58](058.md) | `processInput` — unbounded `esc_buf` growth on malformed or never-completing CSI | LOW | Fixed |
| [59](059.md) | `key.format` — no bounds check on output buffer before writing | LOW | Fixed |
| [60](060.md) | `renderStatusBar` — overflows rendering buffer when many windows with long names | LOW | Fixed |
| [61](061.md) | `cfg.zig` — `stripInlineComment` doesn't handle escaped quotes in value strings | LOW | Fixed |
| [62](062.md) | `resolveLogPath` calls `mkdir` with `0o777` and silently ignores failure | LOW | Fixed |
| [63](063.md) | SGR mouse wheel release events misreported — wheel info lost on release | LOW | Fixed |
| [64](064.md) | Cursor position lost/reset on alternate screen exit (e.g. exiting Vim) | MEDIUM | Fixed |
| [65](065.md) | Use-after-free / double-free via `errdefer` in `Grid.scrollUp()` | CRITICAL | Fixed |
| [66](066.md) | `setAttributes` fails to turn off removed attributes | CRITICAL | Fixed |
| [67](067.md) | `writeCell` writes character with wrong colors after attribute reset emits `\x1b[m` | CRITICAL | Fixed |
| [68](068.md) | Potential double-close of PTY fds from conflicting deinit paths | CRITICAL | Fixed |
| [69](069.md) | Stack buffer overflow in `Client.sendPacket` | HIGH | Fixed |
| [70](070.md) | No upper cap on packet length in `Client.recvPacket` — DoS via 4 GB allocation | HIGH | Fixed |
| [71](071.md) | `drawLine` "clear trailing spaces" is a dead no-op | HIGH | Fixed |
| [72](072.md) | Division by zero in `Grid.resize(0)` | HIGH | Fixed |
| [73](073.md) | Division by zero in `Grid.scrollDown` when `height == 0` | HIGH | Fixed |
| [74](074.md) | Allocation error silently swallowed in `advanceDcsIntermediate` (sixel DCS) | HIGH | Fixed |
| [75](075.md) | `cmdBreakPane` overrides new window's pane without deinit — arena waste | HIGH | Fixed |
| [76](076.md) | `cmdJoinPane` creates dummy pane via `splitPane` that is discarded — arena waste | HIGH | Fixed |
| [77](077.md) | Memory leak in `windowTitleCallback` — old name never freed | HIGH | Fixed |
| [78](078.md) | Memory leak in `renderToDisplayClient` — auto window rename leaks old name | HIGH | Fixed |
| [79](079.md) | Modified function key parsing broken — `~` CSI sequences with modifiers dropped | HIGH | Fixed |
| [80](080.md) | `@intCast` before bounds check in `Client.sendIdentify` — panic in safe builds | MEDIUM | Fixed |
| [81](081.md) | `errdefer` reads uninitialized `fd` if `socket()` fails | MEDIUM | Fixed |
| [82](082.md) | `std.posix.errno(rc)` may lose error specificity for C wrappers | MEDIUM | Fixed |
| [83](083.md) | `@intCast(self.cy)` can panic when cursor position is -1 in `drawLine` | MEDIUM | Fixed |
| [84](084.md) | CSI/SGR mouse/UTF-8 input buffer overflow silently discards data | MEDIUM | Fixed |
| [85](085.md) | DSR response silently dropped on `bufPrint` failure | MEDIUM | Fixed |
| [86](086.md) | XTSMGRAPHICS response silently fails on `bufPrint` overflow or `writeInput` error | MEDIUM | Fixed |
| [87](087.md) | `.?` on `active_window`/`active_pane` without guard in `cmdNewSession` | MEDIUM | Fixed |
| [88](088.md) | `defer free` on `parsed_val.string` relies on undocumented dup-in-set contract | MEDIUM | Fixed |
| [89](089.md) | `logFn` writes garbage bytes from uninitialized buffer on `bufPrint` failure | MEDIUM | Fixed |
| [90](090.md) | `keysEqual` ignores Meta modifier — impossible to bind Meta-modified keys | MEDIUM | Fixed |
| [91](091.md) | `errdefer` registered after `Pane.init` in `Layout.splitPane` — leak on init failure | MEDIUM | Fixed |
| [92](092.md) | History lines not resized when terminal width changes | MEDIUM | Fixed |
| [93](093.md) | Partial `write()` on Unix socket not retried | LOW | Fixed |
| [94](094.md) | Integer overflow in `resize_right` action | LOW | Fixed |
| [95](095.md) | Daemon fork doesn't close stdin/stdout/stderr | LOW | Fixed |
| [96](096.md) | Log directory created with `0o777` (world-writable) | LOW | Fixed |
| [97](097.md) | `socket_path.zig` silently ignores `mkdir` failure | LOW | Fixed |
| [98](098.md) | `logFn` retries `open()` on every call forever if it fails once | LOW | Fixed |
| [99](099.md) | CSI parameter integer overflow — `param_val * 10 + digit` wraps on u32 | LOW | Fixed |
| [100](100.md) | `client/raw.zig` — VMIN/VTIME indices are macOS values, completely wrong on Linux | CRITICAL | Fixed |
| [101](101.md) | `server/server.zig` — Use-after-free during batch PTY event processing | CRITICAL | Fixed |
| [102](102.md) | `main.zig` — `errno` retrieval is always `.SUCCESS`, client disconnects on transient errors | CRITICAL | Fixed |
| [103](103.md) | `log.zig` + `socket_path.zig` — Wrong errno retrieval for C library calls | CRITICAL | Fixed |
| [104](104.md) | `char_width.zig` — Hangul Jamo 0x1100–0x115F reported as width 0 instead of 2 | HIGH | Fixed |
| [105](105.md) | `key.zig` — Alt modifier lost when parsing ESC+char sequences | HIGH | Fixed |
| [106](106.md) | `server/dispatch.zig` — Partial writes not retried on socket I/O | HIGH | Fixed |
| [107](107.md) | `server/protocol.zig` — `IdentifyTerm.decode` missing `len <= 64` validation | HIGH | Fixed |
| [108](108.md) | `server/server.zig` — Unchecked writes to display client | HIGH | Fixed |
| [109](109.md) | `tty/fd_writer.zig` — Missing EINTR handling in writeAll and writeByte | HIGH | Fixed |
| [110](110.md) | `client/client.zig` — Heap-allocated body in recvPacket has no guaranteed free | HIGH | Fixed |
| [111](111.md) | `mode_copy.zig` — `yankSelection` computes wrong bounds for reverse selections | HIGH | Fixed |
| [112](112.md) | `main.zig` — `@enumFromInt` without validation for MessageType | HIGH | Fixed |
| [113](113.md) | `window.zig` + `session.zig` — Pane double-deinit between Session.deinit and Window.deinit | HIGH | Fixed |
| [114](114.md) | `input.zig` — UTF-8 state not cleared on parser reset or state transitions | MEDIUM | Fixed |
| [115](115.md) | `key.zig` — `@intCast` may panic on out-of-range kitty codepoint | MEDIUM | Fixed |
| [116](116.md) | `options.zig` — `choice` values are not cloned or freed | MEDIUM | Fixed |
| [117](117.md) | `cfg.zig` — Quoted string parser doesn't verify closing quote | MEDIUM | Fixed |
| [118](118.md) | `cfg.zig` — `parseSetEnv` doesn't recognize `-g` followed by tab | MEDIUM | Fixed |
| [119](119.md) | `cfg.zig` — `parseIfShell` doesn't handle escaped quotes | MEDIUM | Fixed |
| [120](120.md) | `log.zig` — Data race on `log_fd` and `log_fd_failed` globals | MEDIUM | Fixed |
| [121](121.md) | `socket_path.zig` — Fixed 128-byte buffer for HOME path with no fallback | MEDIUM | Fixed |
| [122](122.md) | `mode_copy.zig` — Selection coordinates are screen-space, not grid-space | MEDIUM | Fixed |
| [123](123.md) | `server/pty.zig` — Memory leak on partial `dupeZ` failure in `spawn` | MEDIUM | Fixed |
| [124](124.md) | `server/pty.zig` — `writeInput` doesn't verify all bytes were written | MEDIUM | Fixed |
| [125](125.md) | `server/pty.zig` — `reap` uses WNOHANG but unconditionally sets pid to -1 | MEDIUM | Fixed |
| [126](126.md) | `server/render.zig` — `self.sy - 1` underflows when `sy == 0` | MEDIUM | Fixed |
| [127](127.md) | `server/server.zig` — `findPaneAtNode` doesn't subtract border width | MEDIUM | Fixed |
| [128](128.md) | `tty/tty.zig` — `cursorDown`/`cursorForward`/`drawLine` panic on zero dimensions | MEDIUM | Fixed |
| [129](129.md) | `tty/tty.zig` — `setCursorStyle` blink/steady mapping is inverted | MEDIUM | Fixed |
| [130](130.md) | `tty/tty.zig` — `writeCell` early return on combining char encode failure leaves `cx` stale | MEDIUM | Fixed |
| [131](131.md) | `input.zig` — SOS/PM/APC string doesn't handle ESC \ (ST) terminator correctly | MEDIUM | Fixed |
| [132](132.md) | `server/loop.zig` — `addFd` silently ignores duplicate fd without updating events/udata | MEDIUM | Fixed |
| [133](133.md) | `server/server.zig` — `killSession` uses `swapRemove` — silently changes active session | MEDIUM | Fixed |
| [134](134.md) | `server/server.zig` — `deinit` doesn't remove client fds from the event loop | MEDIUM | False Positive |
| [135](135.md) | `main.zig` — Command buffer over-allocated by 1 byte | LOW | Fixed |
| [136](136.md) | `main.zig` — Unchecked `c.write` return for resize packet | LOW | Fixed |
| [137](137.md) | `session.zig` — Window IDs are not unique after kills | LOW | Fixed |
| [138](138.md) | `input.zig` — CSI private marker can appear after parameter digits | LOW | Fixed |
| [139](139.md) | `key_binding.zig` — Force unwrap in `mapCommandToAction` may panic | LOW | Fixed |
| [140](140.md) | `key_binding.zig` — `val >= 0` is always true for `u8` | LOW | Fixed |
| [141](141.md) | `format.zig` — `splitArgs` always appends trailing segment even when empty | LOW | Fixed |
| [142](142.md) | `format.zig` — `expandTruncate` integer overflow on large digit sequences | LOW | Fixed |
| [143](143.md) | `colour.zig` — `parse` accepts trailing garbage after colour index | LOW | False Positive |
| [144](144.md) | `char_width.zig` — Dead code: C1 control check unreachable | LOW | Fixed |
| [145](145.md) | `char_width.zig` — Dead code in `isCombining` | LOW | False Positive |
| [146](146.md) | `cfg.zig` — `set -u` silently dropped | LOW | Fixed |
| [147](147.md) | `cfg.zig` — Combined flags like `-gw` misparsed | LOW | Fixed |
| [148](148.md) | `client/raw.zig` — BRKINT left enabled in raw mode | LOW | Fixed |
| [149](149.md) | `client/client.zig` — `recvPacket` doesn't validate msg_type | LOW | Fixed |
| [150](150.md) | `tty/tty_key.zig` — Invalid UTF-8 lead bytes 0xC0–0xC1 accepted into multi-byte state | LOW | Fixed |
| [151](151.md) | `tty/tty_key.zig` — Wheel left/right mouse buttons misidentified | LOW | Fixed |
| [152](152.md) | `tty/tty.zig` — `writeCell` always advances `cx` by 1, ignoring wide character width | LOW | Fixed |
| [153](153.md) | `cmd/cmd.zig` — `src_pane` declared `undefined` in `cmdJoinPane` | LOW | Fixed |
| [154](154.md) | `server/server.zig` — `paneCwd` allocates memory with opaque ownership | LOW | Fixed |
| [155](155.md) | `server/dispatch.zig` — `@intCast` from `usize` to `isize` can panic | LOW | Fixed |
| [156](156.md) | `server/protocol.zig` — `Packet.make` integer overflow on large data | LOW | Fixed |
| [157](157.md) | `server/socket.zig` — `bind` passes oversized `addrlen` | LOW | Fixed |
| [158](158.md) | `status.zig` — Left and right sections can silently overlap | LOW | Fixed |
| [159](159.md) | `server/render.zig` — Status bar column tracking doesn't account for escape sequences | LOW | Fixed |
| [160](160.md) | `server/server.zig` — `loadConfigFile` — `@intCast(size)` from `c_long` to `usize` can panic | LOW | Fixed |
| [161](161.md) | `integration.zig` — `setupServer` discards exec result | LOW | Fixed |
| [162](162.md) | `mode_copy.zig` — `@intCast` of `history.items.len` (usize) to u32 | LOW | Fixed |
| [163](163.md) | `server/socket.zig` — Wrong errno retrieval in `mapErr` (same as #103) | MEDIUM | Fixed |
| [164](164.md) | `server/render.zig` — SGR buffer overflow with all 11 attributes + RGB fg/bg | CRITICAL | Fixed |
| [165](165.md) | `server/render.zig` — `writeBytes` doesn't retry partial writes | HIGH | Fixed |
| [166](166.md) | `main.zig` — Output write to stdout ignores errors and partial writes | HIGH | Fixed |
| [167](167.md) | `server/render.zig` — `utf8Encode` `catch unreachable` for combining codepoints | MEDIUM | Fixed |
| [168](168.md) | `server/pty.zig` — `execvp` assumes argv_z[0] is non-null | MEDIUM | Fixed |
| [169](169.md) | Use-after-free in `windowTitleCallback` — `title_ctx` points to stack Window after heap copy | CRITICAL | Fixed |
| [170](170.md) | Non-sixel DCS (tmux passthrough) body leaks into screen grid as literal text | MEDIUM | Fixed |
| [171](171.md) | `catch unreachable` on CUP bufPrint — 32-byte buffer can overflow for very large terminals | CRITICAL | Fixed |
| [172](172.md) | `catch unreachable` on window index formatting — 16-byte buffer can overflow | CRITICAL | Fixed |
| [173](173.md) | `c.kill` SIGWINCH return silently discarded — child may miss resize | MEDIUM | Fixed |
| [174](174.md) | Double force-unwrap on `session.active_window.?.active_pane.?` in server daemon | MEDIUM | Fixed |
| [175](175.md) | Detach packet write return silently discarded — client may not receive detach | MEDIUM | Fixed |
| [176](176.md) | Use-after-free / crash on OOM inside `server.zig` live clock ticking | CRITICAL | Fixed |
| [177](177.md) | Memory leak on partial allocation failure inside `ChooseMode.enter()` | HIGH | Fixed |
| [178](178.md) | `destroyPane` doesn't remove pty fd from event loop — fd leak / stale events | MEDIUM | Fixed |
| [179](179.md) | Recursive `resizeNode` / `countLeavesNode` may overflow stack on deeply nested layouts | MEDIUM | Fixed |
| [180](180.md) | `handleMouseFocus` `@intCast` from `usize` to `u32` can panic with oversized session name | LOW | Fixed |
| [181](181.md) | Use-after-free in `Session.newWindow` — `title_ctx` points to stack Window after heap copy | CRITICAL | Fixed |
| [182](182.md) | Sixel parser permanently stuck after 16 MiB buffer cap — DoS from missing `.dcs_discard` transition | HIGH | Fixed |
| [183](183.md) | Escape key cannot cancel choose mode — InputReader never emits `.special.escape` for bare `0x1B` | MEDIUM | Fixed |
| [184](184.md) | HUP re-registration window — data may arrive on pty fd while no poll handler is registered | LOW | Fixed |
| [185](185.md) | `renderStatusBar` doesn't truncate long window names — writes past terminal width | MEDIUM | Fixed |
| [186](186.md) | `IdentifyTerm` struct is dead on the wire — live client sends a raw string | MEDIUM | Fixed |
| [187](187.md) | Reserved message types declared but never constructed or handled | LOW | Fixed |
| [188](188.md) | No per-session attach selection in the wire protocol | MEDIUM | Fixed |
| [189](189.md) | Protocol structs are not `packed` despite AGENTS.md claiming so | LOW | Fixed |
| [190](190.md) | Inconsistent packet size limits across the three parsers | MEDIUM | Fixed |
| [191](191.md) | Silent `else` branches drop unknown / ignored messages | LOW | Fixed |
| [192](192.md) | `Packet.deserialize` requires exact buffer length — unsafe for streams | LOW | Fixed |
| [193](193.md) | Sixel image width unknown — cursor advance uses an approximation | MEDIUM | Fixed |
| [194](194.md) | Multi-pane sixel dropped — `rendered_ids` shared across panes | HIGH | Fixed |
| [195](195.md) | Sixel overlay is never actually erased — `ECH` is ineffective, causing ghosting/smearing on scroll | HIGH | Fixed |
| [196](196.md) | `force_clear` wipes the entire multiplexer display and is only propagated from the active pane | MEDIUM | Fixed |
| [197](197.md) | Partially-scrolled images are hidden entirely, contradicting the design doc | MEDIUM | Fixed |
| [198](198.md) | Copy-mode / scrollback sixel is silently lost after the 64-image ring wraps | MEDIUM | Fixed |
| [199](199.md) | Pixel↔cell conversion hardcoded to 20px/row and 10px/col | MEDIUM | Fixed |
| [200](200.md) | Redundant per-cell `dx`/`dy` storage in the 128-bit `Cell` | LOW | Fixed |
| [201](201.md) | `eraseDisplay` `force_clear` triggered by any image in the registry, not the erased region | LOW | Fixed |
| [202](202.md) | Sixel bleeds over the split border and gets stuck when scrolled above the pane | HIGH | Fixed |
| [203](203.md) | `img2sixel` on an image larger than the pane wastes work and destroys scrollback | MEDIUM | Fixed |
| [204](204.md) | First sixel ever displayed always gets extra lines (cell size measured too late) | MEDIUM | Fixed |
| [205](205.md) | Closed PTY fds not removed from event loop on session/window kill — infinite 100% CPU busy-loop | CRITICAL | Fixed |
| [206](206.md) | Stale Unicode width table — agent CLI symbols (✓ ★ ♥ arrows) misclassified width 1, cursor drifts | HIGH | Fixed |
| [207](207.md) | Non-blocking display socket buffer truncation on EAGAIN — server event-loop spin (freeze + 100% CPU) | HIGH | Fixed |
| [208](208.md) | renderToDisplayClient skips frame generation on successful display backlog flush | HIGH | Fixed |
| [209](209.md) | SGR delta emission ignores default color resets — color bleeding on fastfetch / neofetch | MEDIUM | Fixed |
| [210](210.md) | Host terminal auto-wrap (DECAWM) causes screen scrolling on bottom-right cell writes — scattered text and color remnants | HIGH | Fixed |
| [211](211.md) | Overly broad emoji-presentation symbol width ranges in char_width.zig classify standard width-1 characters (✓, ✔, ★, ♥) as width-2, causing cursor drift and character remnants | HIGH | Fixed |
| [212](212.md) | Pane-border loop clobbers the topmost pane's first content line | MEDIUM | Fixed |
| [213](213.md) | Default `pane-border-format "#I"` renders blank | MEDIUM | Fixed |
| [214](214.md) | `status.buildLine` left/right templates resolve to the LAST window, not the active one | MEDIUM | Fixed |
| [215](215.md) | Pane-border format written byte-by-byte — corrupts UTF-8 / invalid codepoints | LOW | Fixed |
| [216](216.md) | `Grid.scrollDown` pops newest history entry instead of oldest — corrupts history after compaction | CRITICAL | False Positive |
| [217](217.md) | `reflowCursorInternal` destroys old grid lines before new lines are committed — unrecoverable on OOM | CRITICAL | Fixed |
| [218](218.md) | Sixel registry eviction (step 4) can evict still-referenced images — dangling cell references | CRITICAL | Fixed |
| [219](219.md) | `shiftSixelAnchors` shifts images belonging to the wrong screen — alt/main anchor drift | CRITICAL | Fixed |
| [220](220.md) | Pane swap (`swap_pane_up`/`swap_pane_down`) does not resize panes to their new positions | HIGH | Fixed |
| [221](221.md) | Use-after-free in `runServerDaemon`: `default_pane` captured across async `server.run` calls | HIGH | Fixed |
| [222](222.md) | New panes in existing sessions miss cell pixel size initialization — sixels use stale defaults | HIGH | Fixed |
| [223](223.md) | `Screen.resize` uses main cursor position to compute alt grid cursor — alt cursor drifts | MEDIUM | Fixed |
| [224](224.md) | `queryCellSize` blocks interactive client event loop for 200 ms on startup | MEDIUM | Fixed |
| [225](225.md) | `isImageReferenced` performs O(total_cells × num_slots) scanning — linear search per sixel placement | LOW (performance) | Fixed |
| [226](226.md) | Dangling pointer in status bar prompt rendering | CRITICAL | Fixed |
| [227](227.md) | Socket write loop pegs CPU on 0-byte writes | CRITICAL | Fixed |
| [228](228.md) | `Packet.deserialize` and `Packet.serialize` buffer panic hazards | CRITICAL | Fixed |
| [229](229.md) | Terminal scrolling logic destroys scrollback history & fails on empty history | CRITICAL | Fixed |
| [230](230.md) | `reflowCursorInternal` double-frees history, leaks memory, and corrupts ring buffer index | CRITICAL | Fixed |
| [231](231.md) | Integer underflow panic in `Grid.clone()` | CRITICAL | Fixed |
| [232](232.md) | Window/layout tree desync on last pane removal & window rotation | CRITICAL | Fixed |
| [233](233.md) | Layout bound invariant violation on small pane splits and resizes | HIGH | Fixed |
| [234](234.md) | Copy mode incremental search fails across soft-wrapped line boundaries | HIGH | Fixed |
| [235](235.md) | Ghost character artifacts and dropped UTF-8 combining marks on soft wraps | HIGH | Fixed |
| [236](236.md) | `SIGWINCH` signal handler missing `SA_RESTART` flag | HIGH | Fixed |
| [237](237.md) | Memory leak of `DispatchResult` in prompt input processing | HIGH | Fixed |
| [238](238.md) | Memory leaks in configuration directive parsing | HIGH | Fixed |
| [239](239.md) | Memory leak on `Pane.init` failure during pane creation | HIGH | Fixed |
| [240](240.md) | O(W×H) matrix scanning for Sixel images during rendering | MEDIUM (performance) | Fixed |
| [241](241.md) | O(N) pixel-level border active checks inside render loop | MEDIUM (performance) | Fixed |
| [242](242.md) | Heap allocation in `getCwd` PTY path resolution | MEDIUM (performance) | Fixed |
| [243](243.md) | Duplicated layout tree traversal logic in server | LOW (code quality) | Fixed |
| [244](244.md) | Duplicated pane swapping logic between up/down actions | LOW (code quality) | Fixed |
| [245](245.md) | Non-compliance with AGENTS.md arena allocator lifecycle rule | LOW (architecture) | Fixed |
| [246](246.md) | Non-compliance with AGENTS.md comptime command table dispatch rule | LOW (architecture) | Fixed |
| [247](247.md) | Non-compliance with AGENTS.md mouse protocol scope rule | LOW (architecture) | Intentional |
| [248](248.md) | pane-border-format defaults to window index (#I) instead of pane index (#P) | LOW (cosmetic) | Fixed |
| [249](249.md) | History restoration order inversion in `Grid.scrollDown` | CRITICAL | Fixed |
| [250](250.md) | Inverted dimension assignment in `swapPaneRelative` | HIGH | Fixed |
| [251](251.md) | Out-of-bounds `cursor_x` in soft-wrapped copy mode search | HIGH | Fixed |
| [252](252.md) | Unimplemented Sixel matrix scanning optimization in `renderSixelImages` | MEDIUM (performance) | Fixed |
| [253](253.md) | Sixel refcount residual leak on slot eviction in `placeSixelImage` | MEDIUM | Fixed |
| [254](254.md) | Parent pane dimensions un-restored on split allocation failure | MEDIUM | Fixed |
| [255](255.md) | Dead active-window variable loop in `status.buildLine` | LOW (code quality) | Fixed |
| [256](256.md) | Dead session list re-validation loop in `runServerDaemon` | LOW (code quality) | Fixed |
| [257](257.md) | Duplicated slot eviction loop in `placeSixelImage` | LOW (code quality) | Fixed |
| [258](258.md) | `Packet.make` integer overflow risk on `5 + data.len` | LOW (safety) | Fixed |
| [259](259.md) | Escaped backslash handling hazard in `unescapeQuoted` | LOW (correctness) | Fixed |
| [260](260.md) | Denial of Service (CPU Exhaustion) via uncapped `CSI b` (`REP`) sequence | HIGH | Fixed |
| [261](261.md) | Unbounded Memory Growth (OOM Vector) in OSC Control String Buffer | HIGH | Fixed |
| [262](262.md) | Protocol Message Corruption on Partial Write in `sendRequestCellSize` | HIGH | Fixed |
| [263](263.md) | Attempting to Free Static Slice in `findWordBreaks` | HIGH | Fixed |
| [264](264.md) | Grid Reflow Trims CJK Padding Cells (`is_padding == true`) | MEDIUM | Fixed |
| [265](265.md) | Cursor Column Clamped to Text Length During Reflow | MEDIUM | Fixed |
| [266](266.md) | Memory Leak in `cmdDisplayMessage` on Error | MEDIUM | Fixed |
| [267](267.md) | Memory Leak in `Pty.spawn` when `fork()` Fails | MEDIUM | Fixed |
| [268](268.md) | Unfreed Window Memory in `Session.killWindow` | MEDIUM | False Positive |
| [269](269.md) | Potential Buffer Memory Leak in `addSixelImage` | MEDIUM | Fixed |
| [270](270.md) | Array Write Without Bounds Check in `InputReader.feedCsi` | MEDIUM | Fixed |
| [271](271.md) | Direct History Length Subtraction Bypasses Safety Bounds Check | MEDIUM | Fixed |
| [272](272.md) | Out-of-Bounds Read in `findWordBreaks` (`libthai` Wrapper) | LOW | False Positive |
| [273](273.md) | Dead Range Check in `isCombining` Omits Hangul Jamo Marks | LOW | Fixed |
| [274](274.md) | Unchecked `@intCast` in `combiningIndex` | LOW | Fixed |
| [275](275.md) | Format Loop Bug in `appendWithStrftime` | LOW | Fixed |
| [276](276.md) | O(M²) Re-evaluations in Copy Mode Search | LOW (performance) → MEDIUM (correctness regression in original fix) | Fixed |
| [277](277.md) | `renderAll` cursor position unclamped to pane and terminal bounds — CUP writes outside pane area | MEDIUM | Fixed |
| [278](278.md) | `insertLines` double-decrements sixel refcount of the discarded bottom line | CRITICAL | Fixed |
| [279](279.md) | `deleteLines` decrements the refcount of the *preserved* bottom line | CRITICAL | Fixed |
| [280](280.md) | `renderToDisplayClient` frees string literals via `pane_border_owned` | HIGH | Fixed |
| [281](281.md) | `searchBackward` cyclic wrap (pass 2) skips the head of a wrapped logical line | HIGH | Fixed |
| [282](282.md) | `processInput` use-after-free when a prompt command kills the session | HIGH | Fixed |
| [283](283.md) | Dangling `mouse_autoscroll_pane` / `mouse_press_pane` after pane destruction | HIGH | Fixed |
| [284](284.md) | `cmdRotateWindow` rotates the pane list but not the layout tree | HIGH | Fixed |
| [285](285.md) | `setMessage` UAF / double-free on allocation failure | MEDIUM | Fixed |
| [286](286.md) | `cmdMoveWindow` orphans the window when `insert` fails (OOM) | MEDIUM | Fixed |
| [287](287.md) | `cmdBreakPane` / `cmdJoinPane` orphan the pane on failure after extraction | MEDIUM | Fixed |
| [288](288.md) | `formatHelp` leaks `buf` on error | MEDIUM | Fixed |
| [289](289.md) | `cmdResizePane` signed overflow on accumulated adjustments | MEDIUM | Fixed |
| [290](290.md) | `handleMouseFocus` status-bar hit-testing doesn't match the rendered status line | MEDIUM | Fixed |
| [291](291.md) | `decrementAltGridRef` is dead code — alt-screen sixel refcounts never decremented | MEDIUM (dead code / refcount drift) | Fixed |
| [292](292.md) | `insertChars` / `deleteChars` refcount bookkeeping only covers the tail cells | MEDIUM | Fixed |
| [293](293.md) | Raw history-length subtraction at remaining call sites bypasses `historyLen()` guard | LOW | Fixed |
| [294](294.md) | `esc_buf` cleared at the top of `processInput` drops split escape sequences | LOW | Fixed |
| [295](295.md) | `handleAccept` error paths leak fd / MessageReader | LOW | Fixed |
| [296](296.md) | `newSession` leaks session internals if `sessions.append` fails | LOW | Fixed |
| [297](297.md) | `out_buf` / `command_buf` unbounded growth with a non-reading client | LOW | Fixed |
| [298](298.md) | Client freezes on a full stdout — blocking `writeAll` stalls input forwarding (mosh backpressure) | HIGH | Fixed |
| [299](299.md) | `awaiting_cell_size` stdin forwarding overruns a 40-byte buffer — client crash / input corruption (regression from #298) | HIGH | Fixed |
| [300](300.md) | getForegroundProcessName called every render for automatic_rename windows | MEDIUM | Fixed |
| [303](303.md) | anyDisplayClientBehind() called 3+ times per render loop | LOW | Fixed |
| [304](304.md) | pane_border format strings allocated per-pane per-client every render | MEDIUM | Fixed |
| [305](305.md) | isPaneValid is O(N*M*P) called on every PTY event | LOW | Fixed |
| [306](306.md) | collectPaneBounds allocates ArrayList on every call | LOW | False Positive |
| [307](307.md) | pane_border_format re-expanded every render even when unchanged | LOW | Fixed |
| [308](308.md) | merged screen init/deinit path has unnecessary allocation checks | LOW | False Positive |
| [309](309.md) | status line built from scratch every render | LOW | Fixed |
| [310](310.md) | tickAutoscroll traverses full session tree on every loop iteration | LOW | Fixed |
| [311](311.md) | Multiline prompt cursor jumping and text scrambling during line editing | HIGH | Fixed |
| [312](312.md) | Use-after-free in Server.processInput when action destroys active pane or session | CRITICAL | Open |
| [313](313.md) | Window title callback calls allocator.free on Session arena | HIGH | Open |
| [314](314.md) | Memory leak when expanding pane border format strings during rendering | HIGH | Open |
| [315](315.md) | cmdMoveWindow orphans window and leaks memory on insert OOM rollback failure | HIGH | Open |
| [316](316.md) | Sixel image refcounts leaked on vertical screen shrink in Screen.resize | HIGH | Open |
| [317](317.md) | Sixel image refcounts leaked on grid history limit eviction | HIGH | Open |
| [318](318.md) | Layout split failure leaves pane internal dimensions un-restored | HIGH | Open |
| [319](319.md) | Desynchronization between Window.panes array rotation and Layout tree DFS rotation | HIGH | Open |
| [320](320.md) | State desync on cmdJoinPane layout node lookup failure | HIGH | Open |
| [321](321.md) | Uncapped loop in CSI 'Z' handler causes CPU exhaustion DoS | HIGH | Open |
| [322](322.md) | Synchronous blocking write in server response dispatch halts main loop | HIGH | Open |
| [323](323.md) | Dummy pane allocation wasted in cmdBreakPane | MEDIUM | Open |
| [324](324.md) | cmdRenameWindow leaks window name memory into session arena | MEDIUM | Open |
| [325](325.md) | Option set -u directive silently ignored in configuration parser | MEDIUM | Open |
| [326](326.md) | Substring flag matching and combined flag failure in mapCommandToAction | MEDIUM | Open |
| [327](327.md) | Copy mode single-line backward selection yank failure | MEDIUM | Open |
| [328](328.md) | Format string truncation specifier slices UTF-8 codepoints | MEDIUM | Open |
| [329](329.md) | Missing OSC discard transition on buffer overflow causes input injection | MEDIUM | Open |
| [330](330.md) | Input parser drops interrupting Escape (0x1B) control bytes | MEDIUM | Open |
| [331](331.md) | SIGWINCH configured with SA_RESTART delays client resize redraws | MEDIUM | Open |
| [332](332.md) | Recursive layout tree traversals risk stack overflow on deep split hierarchies | MEDIUM | Open |
| [333](333.md) | O(L^2) re-evaluation loop during Thai line rewrapping | MEDIUM | Open |
| [334](334.md) | Dropped keystroke on interrupted UTF-8 continuation sequence | LOW | Open |
| [335](335.md) | Command table execution uses function pointer dispatch violating AGENTS.md | LOW | Open |
| [336](336.md) | Duplicated key binding flag parsing loop in cfg.zig | LOW | Open |
| [337](337.md) | Duplicated target window index resolution in cmd.zig | LOW | Open |
| [338](338.md) | Redundant status line string duplication per render frame | LOW | Open |
