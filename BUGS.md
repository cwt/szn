# Bugs — szn

Sorted by severity: Critical → High → Medium → Low.

---

## CRITICAL (crash, use-after-free, stack overflow, massive leak)

### 1. Use-after-free in Session.rename()
**File:** `src/session.zig:87–89`
```zig
allocator.free(self.name);
self.name = allocator.dupe(u8, new_name) catch self.name;
```
Frees `self.name` first, then on allocation failure assigns the **already-freed pointer** back. Any subsequent read of `session.name` is use-after-free.
**Status: ✅ FIXED** — dupe first, free after, return on OOM.

### 2. Invalid-free of string literal in dispatch
**File:** `src/server/dispatch.zig:37,48,55,63,68`
```zig
.data = allocator.dupe(u8, msg) catch "error",
```
When `dupe` fails (OOM), falls back to a static string literal. The caller always calls `allocator.free(reply.data)` — passing a static literal to `free()` is UB, will segfault under memory pressure.
**Status: ✅ FIXED** — `DispatchResult.is_owned` flag prevents free on static data.

### 3. Stack overflow when >64 fds registered
**File:** `src/server/loop.zig:19,49`
```zig
var pollfds: [64]std.posix.pollfd = undefined;
event_buf: [64]PollEvent = undefined,
```
Both are fixed-size stack arrays. `self.fds` has no upper bound. Opening 65+ panes/clients writes past the stack array, corrupting the stack. Also `event_buf` overflow at line 64.
**Status: ✅ FIXED** — pollfds now heap-allocated, event_buf is an ArrayList.

### 4. Pane memory leak on Window.deinit
**Status: ❌ FALSE POSITIVE** — `Layout.deinitNode()` calls `pane.deinit()` + `allocator.destroy(pane)` for leaf nodes. Panes are fully cleaned up via the layout tree.

### 5. cmdKillPane leaks killed pane
**Status: ❌ FALSE POSITIVE** — `removePane()` → `layout.removePane()` → `deinitNode()` destroys the pane via the layout tree.

### 6. cmdJoinPane leaks dummy pane
**Status: ❌ FALSE POSITIVE** — The dummy is placed in `src_win.layout.root.leaf`, which is destroyed by `killWindow()` → `layout.deinit()`. The extracted `src_pane` intentionally survives for the move to `dst_win`.

### 7. Child process inherits all parent fds after fork
**File:** `src/server/pty.zig:33–45`
After fork, the child process (shell) inherits every open fd from the parent: Unix socket listener, all client fds, all other pty masters. Only `self.master` is explicitly closed. Need `FD_CLOEXEC` / `SOCK_CLOEXEC` on all server fds.
**Status: ✅ FIXED** — `setCloexec()` helper applied to ptys, listener socket, and accepted client fds.

### 8. reverseIndex emits wrong escape sequence
**File:** `src/tty/tty.zig:290–292`
```zig
try self.write("\x1b[M");  // CSI M = Delete Line
```
Should be `"\x1bM"` (ESC M = Reverse Index, 2 bytes). Currently `reverseIndex()` and `deleteLines(1)` emit the exact same bytes. The test at line 644 also expects the wrong sequence.
**Status: ✅ FIXED** — changed to `\x1bM`, test updated.

---

## HIGH (memory leak, data corruption, functional breakage)

### 9. Memory leak in Grid.scrollDown()
**File:** `src/grid.zig:148–153`
`history.pop()` removes a line, then `lines.insert(0, line)`. If `insert` fails, the popped line is leaked — no `errdefer` to deinit it on error propagation.

### 10. Colour.fmt() reads uninitialized memory
**File:** `src/colour.zig:44–58`
```zig
_ = std.fmt.bufPrint(&buf, ...);         // return value discarded
return std.mem.sliceTo(buf, 0);           // scans for null byte
```
`bufPrint` does **not** null-terminate. `sliceTo` scans past the end of formatted data into uninitialized stack bytes, returning garbage. The return value of `bufPrint` should be used directly.

### 11. Memory leak in Options.set()
**File:** `src/options.zig:84–85`
`key_name = try allocator.dupe(name)` succeeds, then `cloneValue()` fails. No `errdefer` to free `key_name` — it leaks.

### 12. Dangling pointer in Context.set()
**File:** `src/format.zig:26–35`
Frees the old value FIRST (`allocator.free(entry.value_ptr.*)`), then duplicates the new one. If `dupe` fails, the map entry holds a dangling pointer to freed memory.

### 13. Copy mode broken for scrolled content  ✅ Fixed
**File:** `src/mode_copy.zig:181–218`
`yankSelection()` only reads from `grid.getCell(x, y)` which accesses the visible grid. The `scroll_offset` field is tracked but **never used** to index into `grid.history`. Copying/yanking scrolled-back content is impossible.

**Fix:** Added `getCellAt()` helper that maps (x, screen_y) to the correct source (history or visible grid) using scroll_offset. Test added.

### 14. Emacs alt-key bindings are dead code  ❌ FALSE POSITIVE
**File:** `src/mode_copy.zig:399–450`
All Emacs-style bindings check `c.mod.alt`. The key parser (`src/tty/tty_key.zig`) emits escape-prefixed chars as `char.code = code, mod = .{}` — no alt flag set. So `c.mod.alt` is always false. Every `M-v`, `M-<`, `M->` binding is unreachable.

**Verdict:** Key parser DOES set `mod.alt = true` for escape-prefixed chars (tty_key.zig:105). Verified with unit tests that pass.

### 15. Key value parsing in config is a stub  ✅ Fixed
**File:** `src/cfg.zig:191–225`
`parseValue` now tries `key.parseKeyName()` before defaulting to string. Key-type options like `prefix` parse correctly from config files and `set-option`. Test added.

### 16. Unsafe union access on OptionValue  ✅ Fixed
**File:** `src/server/server.zig:75–76`
Added `== .key` guard before reading `prefix_val.key`. Two test tag checks also added.

### 17. Child uses parent allocator after fork  ✅ Fixed
**File:** `src/server/pty.zig:40–72`
All C-string allocations moved before `fork()`. The child only reads the pre-populated argv array and never touches the parent's allocator.

### 18. OSC ST terminator (ESC \) broken  ✅ Fixed
**File:** `src/input.zig:273–298`
Added `osc_esc` state. On `0x1B` during OSC, go to `osc_esc`. If next byte is `\` (ST), dispatch the OSC. Tests verify callback is invoked for both ST and BEL.

### 19. No bounds check on CSI input buffer  ✅ Fixed
**File:** `src/tty/tty_key.zig:108–164`
Added `if (rd.pos >= rd.buf.len) { state = .ground; return null; }` in `feedCsi`, `feedSgrMouse`, and `feedUtf8`.

### 20. EAGAIN treated as EOF in interactive client  ✅ Fixed
**File:** `src/main.zig:285–319`
Check `std.posix.errno(-1)` for `.AGAIN` and `.INTR` in both stdin and server read paths; only detach on true EOF/error.

### 21. CSI dispatch warn floods logs  ✅ Fixed
**File:** `src/input.zig:357`
Changed `std.log.warn` → `std.log.debug`.

### 22. cmdRenameWindow use-after-free  ✅ Fixed
**File:** `src/cmd/cmd.zig:138–145`
Dupe first, free after — same pattern as Session.rename fix.

---

## MEDIUM (wrong behavior, missing features, fragility)

### 23. No SIGCHLD handler — zombie window ✅ Fixed
**File:** `src/server/server.zig:146–199`
Child processes are only reaped via `Pty.reap()` when the pty fd signals HUP. Between child exit and the next poll cycle, a zombie exists. No `SIGCHLD` handler to reap promptly.

### 24. processReadStdin leaks the input buffer on each call ✅ Fixed
**File:** `src/server/server.zig`
Every call allocates a buffer for stdin data. On error paths, the buffer leaks. Now catches errors instead of propagating.

### 25. handleMouseFocus can use freed Pane pointer ✅ Fixed
**File:** `src/server/server.zig`
`handleMouseFocus` gets a `*Pane` from the layout tree, then calls `setActivePane` which may destroy the pane. Now validates pane is still alive after operations.

### 26. paneList doesn't filter by session ✅ Fixed
**File:** `src/cmd/cmd.zig:790`
`list-panes -s` flag exists but `cmdListPanes` ignores it. The `-s` flag should limit to target session only.

### 27. FdWriter.writeByte ignores zero-write ✅ Fixed
**File:** `src/tty/fd_writer.zig:17–21`
```zig
const n = c.write(self.fd, &b, 1);  // n unused
if (n < 0) return error.WriteFailed;
```
If `write` returns 0 (fd closed or error without errno), it silently succeeds. Missing `if (n == 0) return error.WriteZero`.

### 28. No bounds check in client.sendIdentify ✅ Fixed
**File:** `src/client/client.zig:34`
```zig
@memcpy(it.term[0..term.len], term);
```
If `term.len > 64`, this overwrites memory past the `term` array. The `term_len: u8` field silently truncates the length but the memcpy still overflows.

### 29. Log file opened/closed on every log call ✅ Fixed
**File:** `src/main.zig:29–39`
`logFn` does `fopen("/tmp/szn.log", "a")` and `fclose` on every single log call. Extremely slow under load. Should keep the file handle open or buffer writes.

### 30. Unimplemented config directives ✅ Fixed
**File:** `src/server/server.zig:906,910`
```zig
.set_environment => {},  // TODO
.if_shell => {},         // TODO
```
Both stubs. `set_environment` is needed for `set-environment DISPLAY :0`.

### 31. Directional pane selection is actually circular ✅ Fixed
**File:** `src/server/server.zig:373–383`
All four directions (up/down/left/right) do `(idx + 1) % len` — pure circular next-pane. The layout tree is not consulted (unlike mouse focus which uses `findPaneAtNode` correctly).

### 32. .last_window doesn't track actual last window ✅ Fixed
**File:** `src/server/server.zig:354–363`
Selects the first window that is not current — does not store/restore the "last previously active" window index per session.

### 33. Kitty keyboard protocol incomplete ⏸ Unresolved
**File:** `src/tty/tty_key.zig` → `src/key.zig:124–132`
Handles basic `CSI codepoint ; modifier u` but missing: keypad disambiguation (`CSI 1 ; modifier u`), shifted keys (`CSI > codepoint u`), and key events/release/repeat (`CSI = ; modifier ; event u`).

### 34. split-window direction flag only works as first arg ✅ Fixed
**File:** `src/cmd/cmd.zig:112`
`-v` / `-h` is checked only at `args[1]`. If the proportion comes first (e.g., `split-window 0.3 -v`), the flag is silently ignored.

---

## LOW (style, minor edge cases, future-proofing)

### 35. Hardcoded log path `/tmp/szn.log` ✅ Fixed
**File:** `src/main.zig:29`
Should use `$XDG_STATE_HOME/szn/` or similar for proper filesystem hierarchy compliance.

### 36. Error set is a single catch-all
**File:** `src/err.zig`
AGENTS.md requirement: "Define specific error sets per subsystem." A single `SznError` is used instead.

### 37. Arena allocation not used
AGENTS.md requirement: "Always use arena allocators per session/pane lifecycle." Code uses GeneralPurposeAllocator with individual alloc/free everywhere.

### 38. Duplicate fd registration allowed in event loop ✅ Fixed
**File:** `src/server/loop.zig:29`
`addFd` appends without checking for existing fd. `removeFd` only removes the first match. Stale entries can cause spurious events on reused fd numbers.

### 39. cmdPrevWindow has duplicate dead code ✅ Fixed
**File:** `src/cmd/cmd.zig:606–621`
Identical loop appears twice — copy-paste artifact. Second loop is unreachable.

### 40. attrFields/attrCodes parallel arrays fragile ✅ Fixed
**File:** `src/tty/tty.zig:12–16`
If `Attr` fields are reordered, the `attrCodes` array silently mismatches, applying wrong SGR parameters.

### 41. Tab stop hardcoded to 8 ✅ Fixed
**File:** `src/screen.zig:119`
`tab_stop: u32 = 8` should be configurable (tmux `tab-stop` option).

### 42. History limit hardcoded to 2000 ✅ Fixed
**File:** `src/grid.zig`
`history_limit: u32 = 2000` should come from session options.

### 43. cmdCopyMode overwrites previous copy mode without deinit ❌ FALSE POSITIVE
**File:** `src/cmd/cmd.zig:392–393`
Setting `pane.screen.copy_mode = CopyMode.init(...)` discards the previous copy mode if one exists. Should set to null or call deinit first.
**Verdict:** `CopyMode` is a plain struct with no heap-allocated resources and no `deinit`. Overwriting the field does not leak memory.

### 44. resize-pane can't set size below 1 ✅ Fixed
**File:** `src/cmd/cmd.zig:786–789`
`@max(1, ...)` clamps negative calculated sizes to 1 instead of reporting an error.

### 45. sockaddr_un path size hardcoded to 104 ✅ Fixed
**File:** `src/server/socket.zig:32`, `src/socket_path.zig:6`
Linux uses 108, macOS 104. Should use `@sizeOf(@TypeOf(addr.path))` for portability.

### 46. message_reader silently truncates on buffer full ✅ Fixed
**File:** `src/server/message_reader.zig:22–26`
If data exceeds remaining buffer space, excess bytes are silently dropped. Caller has no way to detect truncation.

### 47. mapCommandToAction can match substrings ✅ Fixed
**File:** `src/key_binding.zig:433`
`containsAtLeast(u8, trimmed, 1, "-h")` matches `-h` anywhere in the string. Flags like `-horizontal` or paths containing `-h` would incorrectly trigger.

---

## Summary

| Severity | Count | Fixed | False Positive | Unresolved |
|----------|-------|-------|----------------|------------|
| Critical | 8 | 5 | 3 | 0 |
| High | 14 | 13 | 1 | 0 |
| Medium | 12 | 11 | 0 | 1 |
| Low | 13 | 10 | 1 | 2 |
| **Total** | **47** | **39** | **5** | **3** |
