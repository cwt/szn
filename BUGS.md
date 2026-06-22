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
**Status:** ✅ FIXED — added errdefer to pop/deinit on error.

`history.pop()` removes a line, then `lines.insert(0, line)`. If `insert` fails, the popped line is leaked — no `errdefer` to deinit it on error propagation.

### 10. Colour.fmt() reads uninitialized memory
**File:** `src/colour.zig:44–58`
**Status:** ✅ FIXED — bufPrint result used directly.

```zig
_ = std.fmt.bufPrint(&buf, ...);         // return value discarded
return std.mem.sliceTo(buf, 0);           // scans for null byte
```

`bufPrint` does **not** null-terminate. `sliceTo` scans past the end of formatted data into uninitialized stack bytes, returning garbage. The return value of `bufPrint` should be used directly.

### 11. Memory leak in Options.set()
**File:** `src/options.zig:84–85`
**Status:** ✅ FIXED — added errdefer to free key_name.

`key_name = try allocator.dupe(name)` succeeds, then `cloneValue()` fails. No `errdefer` to free `key_name` — it leaks.

### 12. Dangling pointer in Context.set()
**File:** `src/format.zig:26–35`
**Status:** ✅ FIXED — dupe new value before freeing old value.

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

### 33. Kitty keyboard protocol incomplete ✅ Fixed
**File:** `src/tty/tty_key.zig` → `src/key.zig:124–132`
Handles basic `CSI codepoint ; modifier u` but was missing: keypad disambiguation (`>codepoint`), shifted keys (`>codepoint`), and key events (`=codepoint;mod;event`).

### 34. split-window direction flag only works as first arg ✅ Fixed
**File:** `src/cmd/cmd.zig:112`
`-v` / `-h` is checked only at `args[1]`. If the proportion comes first (e.g., `split-window 0.3 -v`), the flag is silently ignored.

---

## LOW (style, minor edge cases, future-proofing)

### 35. Hardcoded log path `/tmp/szn.log` ✅ Fixed
**File:** `src/main.zig:29`
Should use `$XDG_STATE_HOME/szn/` or similar for proper filesystem hierarchy compliance.

### 36. Error set is a single catch-all ✅ Fixed
**File:** Removed `src/err.zig` — `SznError` was dead code.
Every subsystem now has its own `pub const Error` set: grid, screen, tty, fd_writer, layout, options, cfg, key_binding, input, pty, render, loop, protocol, socket, dispatch, client, connect, raw, window, session, server, main, cmd (ParseError), status, mode_copy, socket_path.

### 37. Arena allocation not used  ✅ Fixed
AGENTS.md requirement: "Always use arena allocators per session/pane lifecycle." `Session` now owns a `std.heap.ArenaAllocator`. All window/grid/screen/layout/option allocations go through the session arena. Individual `allocator.free`/`allocator.destroy` calls for arena-owned memory removed.

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

## NEW BUGS (2026-06-22 codebase audit)

---
### 48. `mapCommandToAction` rejects commands with arguments — most config bind-key directives fail silently
**File:** `src/key_binding.zig:430–466`
**Severity:** CRITICAL
**Status:** ✅ FIXED

```zig
const trimmed = std.mem.trim(u8, cmd, " \t\"");
if (std.mem.eql(u8, trimmed, "new-window") or std.mem.eql(u8, trimmed, "neww")) return .new_window;
...
```

`trim()` strips outer whitespace and quotes, but everything after the command name (e.g. `-n test`, `-t target`) stays in `trimmed`. `eql` requires an **exact match** — so `new-window -n "my window"` fails, `kill-pane -t 0` fails, `next-window -a` fails. Only `split-window`/`splitw` use `startsWith`.

**Impact:** `bind-key C-n new-window -n test` in `.tmux.conf` is parsed as a valid directive but mapped to `null` (no action), silently doing nothing. Every user who migrates a tmux config with argument-bearing bindings will hit this.

### 49. Line-wrapping fires `grid.scrollUp()` instead of `scrollUpInRegion()` — breaks DECSTBM scroll regions
**File:** `src/screen.zig:153–162`
**Severity:** CRITICAL
**Status:** ✅ FIXED

```zig
if (self.mode.line_wrap) {
    self.cursor.x += 1;
    if (self.cursor.x >= self.grid.width) {
        self.cursor.x = 0;
        if (self.scroll_region) |r| {
            if (self.cursor.y == r[1]) {
                try self.scrollUpInRegion();
            } else {
                self.cursor.y += 1;
            }
        } else {
            if (self.cursor.y + 1 >= self.grid.height) {
                try self.grid.scrollUp();
            } else {
                self.cursor.y += 1;
            }
        }
    }
} else {
    self.cursor.x = @min(self.cursor.x + 1, self.grid.width - 1);
}
```

When a pane has `DECSTBM` set (e.g. `\e[2;4r`), text that autowraps at the region bottom pushes the entire grid up instead of scrolling only within regions 2–4. The region outside 2–4 gets corrupted. The fix makes autowrap respect the scroll region, matching the behavior used for explicit `\n` handling.

### 50. Double-underline and curly-underline both render as plain underline (SGR 4)
**File:** `src/server/render.zig:272–276`
**Severity:** HIGH
**Status:** ✅ FIXED — render.zig updated to emit 4:2 and 4:3, input.zig SGR parsing updated to split on ':' to parse subparameters.


```zig
const attrFields = comptime blk: {
    const all = std.meta.fields(Attr);
    break :blk all[0 .. all.len - 1];  // bold, dim, italic, underline, blink, reverse, concealed, strikethrough, overline, double_underline, curly_underline
};
const attrCodes = [_]u8{ 1, 2, 3, 4, 5, 7, 8, 9, 53, 4, 4 };
//                        b  d  i  u  b  r  c  s  o   dbl_u  cur_u
```

`double_underline` and `curly_underline` are both mapped to SGR code `4` (standard underline). The correct codes are `4:2` for double-underline and `4:3` for curly, but these require sub-parameter syntax (`\e[4:2m`, `\e[4:3m`). Also `overline` maps to `53` which some terminals don't support.

**Impact:** The off-codes (`21` for double, `24` for underline-off) are never emitted — so once double/curly underline is set in a cell, it stays "on" forever in the render output (the attribute tracker never sees an off code matching these states).

### 51. `key.format` — `alt` and `meta` modifiers collide on `M-` prefix
**File:** `src/key.zig:220–224`
**Severity:** HIGH
**Status:** ✅ FIXED — key format/prependModifiers updated to format meta as "Meta-", parseKeyName updated to parse "Meta-".


```zig
if (mod.alt)  { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
if (mod.shift) { buf[pos] = 'S'; buf[pos + 1] = '-'; pos += 2; }
if (mod.meta) { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
```

`alt` → `M-`, `meta` → `M-` — same prefix. A key with both `alt` and `meta` set produces `M-M-Key`, indistinguishable from alt-only. Additionally, `meta` is never actually set by the InputReader kitty parser (`src/tty/tty_key.zig` only reads bits 0-2: shift/alt/ctrl), making the meta format branch dead code. Logging output from `server.zig:605-607` and `server.zig:658-659` uses `key.format()` for tracing, so misreported modifiers show in `show-messages`.

### 52. `feedPty` + `handlePtyEvent` race: PTY deinited in two different code paths
**File:** `src/window.zig:91–104`, `src/server/server.zig:234–258`
**Severity:** HIGH
**Status:** ✅ FIXED — early PTY deinit removed from feedPty and handlePtyEvent; Pty is now solely deinited via Pane.deinit() during pane destruction.


In `feedPty()`:
```zig
pub fn feedPty(self: *Pane) Error!void {
    const pty = &(self.pty orelse return);
    var buf: [4096]u8 = undefined;
    const n = pty.readOutput(&buf) catch |err| {
        pty.deinit();       // (A) deinit + null
        self.pty = null;
        return err;
    };
```

Then in `handlePtyEvent`:
```zig
if (has_in) {
    pane.feedPty() catch |err| { ... exited = true; };
} else if (has_hup or has_err) {  // (B) else-if prevents double entry
    if (pane.pty) |*pty| {
        pty.deinit();       // guarded by null check, currently safe
    }
    pane.pty = null;
    ...
    exited = true;
}
if (exited) { self.destroyPane(pane); }
```

When `POLL.IN` + `POLL.HUP` arrive simultaneously, `feedPty` catches `ProcessExited`, deinits PTY, sets `pane.pty = null`. The `else if` at (B) never fires because `has_in` was true. Currently safe, but fragile — if someone reorders the if-else chain or moves the exited flag, double-deinit becomes reachable. Also `destroyPane` → `layout.deinitNode` → `pane.deinit()` → `p.pty.deinit()` is guarded by `if (self.pty) |*p|`.

### 53. Mouse escape sequence bytes leak to child PTY when pane doesn't want mouse events
**File:** `src/server/server.zig:623–646`
**Severity:** HIGH
**Status:** ✅ FIXED — mouse event handler in server.zig updated to discard all mouse events (handled = true) if session mouse option is disabled, preventing leaks.


```zig
.mouse => |m| {
    const mouse_opt = session.options.asFlag("mouse") orelse false;
    if (mouse_opt and m.button == .left) {
        self.handleMouseFocus(m.x, m.y) catch {};
        handled = true;
    }
    const wants_mouse = pane.screen.mode.mouse_standard or
        pane.screen.mode.mouse_button or
        pane.screen.mode.mouse_sgr;
    if (!wants_mouse) {
        handled = true;   // only set here
    }
},
```

When `mouse_opt` is `false` (szn-level mouse disabled) OR button is not `.left`, `handled` stays `false`. Then at line 639:
```zig
if (!handled) {
    pty.writeInput(esc_buf.items) catch {};   // raw CSI mouse bytes forwarded to shell
}
```

**Impact:** The pane's child process receives raw `\e[<0;40;12M` garbage on stdin. In a shell, mostly invisible (shell ignores unknown ESC), but in a REPL or editor that reads raw terminal input, this injects bytes.

### 54. `split-window -h` (exactly, no trailing args) maps to vertical split
**File:** `src/key_binding.zig:432–440`
**Severity:** MEDIUM
**Status:** ❌ FALSE POSITIVE — condition correctly returns split_horizontal when flag is at end.


```zig
if (std.mem.startsWith(u8, trimmed, "split-window") or std.mem.startsWith(u8, trimmed, "splitw")) {
    if (std.mem.indexOf(u8, trimmed, " -h")) |idx| {
        const after = idx + 3;
        if (after >= trimmed.len or trimmed[after] == ' ') return .split_horizontal;
    }
    return .split_vertical;
}
```

For `"split-window -h"`: `idx = 12`, `after = 15`, `trimmed.len = 15`. `after >= trimmed.len` is true → falls through to `.split_vertical`. So the exact bare command `split-window -h` returns `.split_vertical`. Only `split-window -h <something>` correctly returns `.split_horizontal`. Also, `split-window -hv` (combined flags) would not match `" -h"` since there's no space before.

### 55. Log file fd shared between parent and child after fork — garbled logs
**File:** `src/main.zig:18,48–69,204–217`
**Severity:** MEDIUM
**Status:** ✅ FIXED — logFn updated to format/write messages atomically in a single write call, and log_fd is closed/nullified in the child process immediately post-fork.


```zig
var log_fd: ?std.posix.fd_t = null;  // module-level static

pub fn logFn(...) void {
    if (log_fd == null) {
        const fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o666);
        log_fd = fd;
    }
    const fd = log_fd.?;
    writeAllRaw(fd, msg);
    ...
}
```

When `main` forks to create the server daemon, the child inherits the parent's `log_fd` (or opens it independently, sharing the inode). Both processes then call `logFn` which does `c.write()` to the same fd/inode without any synchronisation. For the brief period between fork and parent exit, log lines from child and parent interleave. After parent exits, only the child writes. Corrupts the first few log lines on every startup.

### 56. `destroyPane` iterates `self.sessions` while `killSession` `swapRemove`s from it
**File:** `src/server/server.zig:261–293`
**Severity:** MEDIUM
**Status:** ✅ FIXED — refactored destroyPane to a scan-then-destroy pattern, avoiding loop mutation bugs.


```zig
pub fn destroyPane(self: *Server, pane: *Pane) void {
    for (self.sessions.items) |session| {          // outer loop
        for (session.windows.items) |win| {         // middle loop
            for (win.panes.items) |p| {              // inner loop
                if (p == pane) {
                    win.removePane(self.allocator, pane);
                    if (win.panes.items.len == 0) {
                        session.killWindow(self.allocator, win);
                    }
                    if (session.windows.items.len == 0) {
                        self.killSession(session.name) catch {};
                        // ^^ swapRemove on self.sessions
                    }
                    ...
                    return;  // early exit salvages correctness
                }
            }
        }
    }
}
```

Currently safe because the `return` at line 288 exits all loops immediately after a mutation. However, the three loops are simultaneously invalidated:
- `removePane` → `swapRemove` on `window.panes`
- `killWindow` → `swapRemove` on `session.windows`
- `killSession` → `swapRemove` on `self.sessions`

If anyone adds code after the `return` statement (e.g. a `break` to the outer loop, or additional cleanup), the iterator will access stale/moved elements. Should be refactored to a single `find then destroy` pattern.

### 57. `handlePtyEvent` casts `udata` pointer without validation — potential stale pointer
**File:** `src/server/server.zig:228`
**Severity:** MEDIUM
**Status:** ✅ FIXED — added `isPaneValid` helper to check if a pane is still alive before using its pointer cast from `udata`.


```zig
fn handlePtyEvent(self: *Server, ev: loop_mod.PollEvent) bool {
    if (ev.fd == self.listener_fd or ev.fd == self.stdin_fd) return false;
    for (self.client_fds.items) |cfd| {
        if (ev.fd == cfd) return false;
    }
    const pane: *Pane = @ptrCast(@alignCast(ev.udata orelse return false));
```

`udata` was set to `*Pane` in `watchPanePty`. By elimination (not listener, not stdin, not client fd), the code assumes the fd must be a PTY fd with a valid pane pointer. If a race condition exists where a pane is destroyed but its fd is still in the poll set (e.g. between `removeFd` in `handlePtyEvent` and the next `pollOnce`), `udata` could point to freed memory. Arena allocation masks this (memory is not actually freed), but it's a semantic issue that could become a real crash if allocation strategy changes.

### 58. `processInput` — unbounded `esc_buf` growth on malformed or never-completing CSI
**File:** `src/server/server.zig:538–539,595–598`
**Severity:** LOW
**Status:** ✅ FIXED — Added 1024-byte capacity check and reset mechanism on esc_buf.

```zig
var esc_buf: std.ArrayList(u8) = .empty;
defer esc_buf.deinit(self.allocator);

while (i < buf.len) : (i += 1) {
    const byte = buf[i];
    ...
    if (self.input_reader.state != .ground or byte == 0x1b or byte < 0x20) {
        try esc_buf.append(self.allocator, byte);
```

If an attacker sends a stream of never-terminated escape sequences (e.g. `\e[1;2;3;4;5;6;7;...` with no final byte), `esc_buf` grows without bound. Each `processInput` call processes one 4KB block from `handleStdin`. Within that block, bytes keep appending to `esc_buf`. While limited to one 4KB stdin read per call, a burst of CSI sequences with many parameters could push `esc_buf` to OOM territory. No max size check exists.

### 59. `key.format` — no bounds check on output buffer before writing
**File:** `src/key.zig:215–301`
**Severity:** LOW
**Status:** ✅ FIXED — Added bounds and remaining capacity checks in format and prependModifiers to prevent buffer overflow.

```zig
pub fn format(key: Key, buf: []u8) []const u8 {
    ...
    // Modifier prefixes (up to 8 bytes: "C-M-S-M-")
    if (mod.ctrl) { buf[pos] = 'C'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.alt)  { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.shift) { buf[pos] = 'S'; buf[pos + 1] = '-'; pos += 2; }
    if (mod.meta) { buf[pos] = 'M'; buf[pos + 1] = '-'; pos += 2; }
    ...
    @memcpy(buf[pos..][0..n.len], n);
    ...
    std.fmt.bufPrint(buf[pos..], "{u}", .{...});
```

Multiple `@memcpy` and `bufPrint` calls write into the buffer without checking remaining capacity against `buf.len`. If the caller passes a buffer too small (e.g. 2 bytes for a modifier-heavy key name), it's a buffer overflow. All current call sites pass `[64]u8` or `[128]u8` which are safely oversized, but the function itself provides no protection.

### 60. `renderStatusBar` — overflows rendering buffer when many windows with long names
**File:** `src/server/render.zig:327–359`
**Severity:** LOW
**Status:** ✅ FIXED — Rewrote renderStatusBar to write pieces directly to the output stream without using a fixed-size buffer.

```zig
var buf: [256]u8 = undefined;
for (windows, 0..) |win, idx| {
    const win_str = std.fmt.bufPrint(&buf, " {d}:{s}{s}", .{ idx, win.name, suffix }) catch " win";
    try self.writeBytes(win_str);
```

With many windows or long window names, `bufPrint` catches the overflow and falls back to `" win"` — but this produces broken output with missing window indices and names. The status bar silently shows garbage entries instead of failing gracefully. A max-truncation strategy or dynamic allocation would be more robust.

### 61. `cfg.zig` — `stripInlineComment` doesn't handle escaped quotes in value strings
**File:** `src/cfg.zig:149–162`
**Severity:** LOW

```zig
fn stripInlineComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |pos| {
        const before = line[0..pos];
        var in_quote = false;
        for (before) |c| {
            if (c == '"') in_quote = !in_quote;
        }
        if (!in_quote) return std.mem.trim(u8, before, " \t");
    }
    return line;
}
```

Quoted strings with an escaped quote inside (e.g. `set -g something "value \"with\" hash # comment"`) would toggle `in_quote` on each `\"` as well as real `"`, miscounting and treating the `#` as a comment start. A proper escape-aware parser would skip `\"` pairs.

### 62. `resolveLogPath` calls `mkdir` with `0o777` and silently ignores failure
**File:** `src/main.zig:30`
**Severity:** LOW

```zig
_ = c.mkdir(dir_z.ptr, 0o777);
return try std.fmt.bufPrintZ(buf, "{s}/szn/szn.log", .{xdg});
```

If the intermediate directory (`$XDG_STATE_HOME`) doesn't exist or isn't writable, `mkdir` silently fails. The subsequent `open()` for the log file also fails silently (the log function just returns without logging). The first `std.log.info` or `std.log.warn` calls during server startup are lost, making startup issues hard to debug.

### 63. SGR mouse wheel release events misreported — wheel info lost on release
**File:** `src/tty/tty_key.zig:241–256`
**Severity:** LOW

```zig
const wheel_up = (btn & 0xC3) == 0x40;
const wheel_down = (btn & 0xC3) == 0x41;

const button: MouseButton = if (release)
    .release
else if (wheel_up)
    .scroll_up
else if (wheel_down)
    .scroll_down
else switch (btn_type) {
```

When a wheel event has the release bit set (button + 0x20), `wheel_up` detection fails: `(0x40 | 0x20) & 0xC3` = `0x60 & 0xC3` = `0x40`. Wait — actually `0x60 & 0xC3` = `0x40`: the release bit 0x20 is masked out by `& 0xC3`. So wheel + release still correctly reports as `scroll_up`/`scroll_down`. But `release` is checked FIRST, so wheel-release events would report `.release` instead. In the SGR protocol, wheel events always have `M` final byte (press) and `m` final byte (release) — meaning release tracking for wheel is already handled by the `release` parameter. The current code maps wheel+m to `.scroll_up`/`.scroll_down` correctly (since release is false for `m`? No — looking at line 137: `parseSgrMouse(seq, byte == 'm')` where `'m'` means release=true). So wheel with `'m'` final byte has `release=true`, hits the first `if`, returns `.release`. The wheel direction information is lost. Minor because most terminals only send press events for wheels.

---

## Summary

| Severity | Count | Fixed | False Positive | Unresolved |
|----------|-------|-------|----------------|------------|
| Critical | 10 | 7 | 3 | 0 |
| High | 18 | 17 | 1 | 0 |
| Medium | 16 | 15 | 1 | 0 |
| Low | 19 | 12 | 1 | 6 |
| **Total** | **63** | **51** | **6** | **6** |
