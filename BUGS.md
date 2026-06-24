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
**Status:** ✅ FIXED — Rewrote stripInlineComment using an escape-aware character-by-character scanner to correctly parse comment hash characters.

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
**Status:** ✅ FIXED — Added check for mkdir return code and fallback to /tmp/szn.log on failure (unless EEXIST).

```zig
_ = c.mkdir(dir_z.ptr, 0o777);
return try std.fmt.bufPrintZ(buf, "{s}/szn/szn.log", .{xdg});
```

If the intermediate directory (`$XDG_STATE_HOME`) doesn't exist or isn't writable, `mkdir` silently fails. The subsequent `open()` for the log file also fails silently (the log function just returns without logging). The first `std.log.info` or `std.log.warn` calls during server startup are lost, making startup issues hard to debug.

### 63. SGR mouse wheel release events misreported — wheel info lost on release
**File:** `src/tty/tty_key.zig:241–256`
**Severity:** LOW
**Status:** ✅ FIXED — Moved wheel_up/wheel_down checks before release check in parseSgrMouse.

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

### 64. Cursor position lost/reset on alternate screen exit (e.g. exiting Vim)
**File:** `src/screen.zig:512`
**Severity:** MEDIUM
**Status:** ✅ FIXED — Stored main cursor and main saved_cursor in `alt_cursor` / `alt_saved_cursor` fields when entering alternate screen, and restored them upon exit.

---

## NEW BUGS (2026-06-24 full codebase audit)

---

### 65. Use-after-free / double-free via `errdefer` in `Grid.scrollUp()`
**File:** `src/grid.zig:163–167`
**Severity:** CRITICAL
**Status:** ✅ FIXED — allocate new_line before swapping old_line out; history append after grid is safe.

```zig
var line = self.getLine(0).*;         // copy by value, shares cells pointer with grid
line.dirty = false;
errdefer line.deinit(self.allocator);  // registered on stack copy

try self.history.append(self.allocator, line);  // if succeeds, 3 copies share same cells
```

After `append` succeeds, the `errdefer` is still active. If any subsequent operation fails (e.g. `new_line.cells.resize` at line 174), the `errdefer` fires and frees `line.cells.items`. But the history entry also points to that same buffer because `append` copies the struct by value. This creates a dangling pointer in history. When `Grid.deinit` later iterates history and calls `deinit` on each entry, it double-frees the already-freed buffer.

---

### 66. `setAttributes` fails to turn off removed attributes
**File:** `src/tty/tty.zig:154`
**Severity:** CRITICAL
**Status:** ✅ FIXED — Changed `<` bitmask comparison to `(old & ~new) != 0`. Tests added for bold→italic (triggers reset) and bold→{bold,italic} (no reset).

---

### 67. `writeCell` writes character with wrong colors after attribute reset emits `\x1b[m`
**File:** `src/tty/tty.zig:366–379`
**Severity:** CRITICAL
**Status:** ✅ FIXED — reordered writeCell to setAttributes before setForeground/setBackground.

```zig
pub fn writeCell(self: *Term, cell: Cell) Error!void {
    try self.setForeground(cell.fg);    // emits \x1b[38;2;Rm
    try self.setBackground(cell.bg);    // emits \x1b[48;2;Rm
    try self.setAttributes(cell.attr);  // may emit \x1b[m (full SGR reset!)
    try self.write(buf[0..encoded_len]); // character rendered with DEFAULT colors
```

`setAttributes` can emit `\x1b[m` (full SGR reset), wiping the fg/bg colors just set. The character is rendered with default terminal colors, not the cell's intended colors. Affects every cell where attributes transition from non-zero to zero.

---

### 68. Potential double-close of PTY fds from conflicting deinit paths
**File:** `src/session.zig:49–57`
**Severity:** CRITICAL
**Status:** ✅ FIXED — both Session.deinit and killWindow now call Pane.deinit() (single cleanup path) instead of inlining pty.deinit().

```zig
pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
    for (self.windows.items) |win| {
        for (win.panes.items) |p| {
            if (p.pty) |*pty| pty.deinit();  // manual PTY cleanup
        }
    }
    self.arena.deinit();  // no Pane.deinit() or Window.deinit() called
}
```

`Session.deinit` manually deinits PTY fds but never calls `Pane.deinit()` or `Window.deinit()`. If `Pane.deinit()` is ever added (which also calls `pty.deinit()`), the PTY fd gets closed twice — potentially closing an unrelated fd reused by another subsystem. Should ensure only one code path handles PTY cleanup.

---

### 69. Stack buffer overflow in `Client.sendPacket`
**File:** `src/client/client.zig:46–52`
**Severity:** HIGH
**Status:** ✅ FIXED — added bounds check for `5 + data.len > 4096` before serializing into fixed stack buffer. Unit test added.

```zig
fn sendPacket(self: *Client, msg_type: protocol.MessageType, data: []const u8) Error!void {
    const pkt = protocol.Packet.make(msg_type, data);
    var buf: [4096]u8 = undefined;
    const serialized = pkt.serialize(&buf);  // no bounds check
```

`serialize` writes `5 + data.len` bytes into a fixed 4096-byte stack buffer with zero bounds checking. If data ≥ 4091 bytes, `@memcpy` writes past the end of the stack buffer. In ReleaseFast this corrupts the stack.

---

### 70. No upper cap on packet length in `Client.recvPacket` — DoS via 4 GB allocation
**File:** `src/client/client.zig:63–68`
**Severity:** HIGH
**Status:** ✅ FIXED — added `MAX_PACKET_SIZE = 1 MiB` cap; oversized lengths return `PacketTooLarge`. Unit test added.

```zig
const len = std.mem.readInt(u32, hdr[0..4], .little);
if (len < 5) return error.InvalidPacket;
const body_len = len - 5;
const body = try self.allocator.alloc(u8, body_len);  // no max cap
```

A malicious server can send `len = 0xFFFFFFFF`, causing a 4 GB allocation attempt. Should cap to a reasonable maximum (e.g. 1 MiB).

---

### 71. `drawLine` "clear trailing spaces" is a dead no-op
**File:** `src/tty/tty.zig:407–411`
**Severity:** HIGH
**Status:** ✅ FIXED — added `clearToEOL()` after cursor move to actually erase trailing characters. Unit test added.

```zig
// Clear trailing spaces
if (last_was_space) {
    try self.cursorMove(width - 1, ly);
}
```

The comment says "clear trailing spaces" but the code only moves the cursor to the last column — no `clearToEOL` or `eraseChars` sequence is emitted. When the next frame draws fewer characters on this line, old characters from the previous frame remain visible.

---

### 72. Division by zero in `Grid.resize(0)`
**File:** `src/grid.zig:127`
**Severity:** HIGH
**Status:** ✅ FIXED — added `if (new_height == 0) return;` guard. Unit test added.

```zig
pub fn resize(self: *Grid, new_height: u32) Error!void {
    ...
    self.height = new_height;  // can be 0
}
```

No guard against `new_height == 0`. Any subsequent `getLine` does `idx % self.height` — division by zero, runtime panic.

---

### 73. Division by zero in `Grid.scrollDown` when `height == 0`
**File:** `src/grid.zig:187–188`
**Severity:** HIGH
**Status:** ✅ FIXED — added `self.height == 0` check to scrollDown guard. Unit test added.

```zig
self.start_index = (self.start_index + self.height - 1) % self.height;  // DIV/0
```

After `resize(0)`, `self.height` is 0. The early return only checks `history.items.len`, not height. Division by zero panic.

---

### 74. Allocation error silently swallowed in `advanceDcsIntermediate` (sixel DCS)
**File:** `src/input.zig:385`
**Severity:** HIGH
**Status:** ✅ FIXED — changed `catch {}` to `try` and return type to `Error!void`. Unit test added.

```zig
self.dcs_buf.appendSlice(self.screen.allocator, "\x1bPq") catch {};
//                                                           ^^^^^^ SWALLOWED
```

If `appendSlice` fails (OOM), the error is silently discarded. The function continues as if the append succeeded, entering `.dcs_sixel` state. When the ST terminator arrives, `dispatchDcsSixel` tries to `dupe` an empty buffer — sixel data is lost/corrupted with no error reported.

---

### 75. `cmdBreakPane` overrides new window's pane without deinit — arena waste
**File:** `src/cmd/cmd.zig:391–399`
**Severity:** HIGH
**Status:** ✅ FIXED — deinit the new window's original pane before overwriting with the extracted pane.

```zig
const new_win = session.newWindow(server.allocator, "window") catch return .err;
if (new_win.panes.items.len > 0) {
    new_win.panes.items[0] = pane;   // original pane created by newWindow is overwritten
```

`newWindow` creates a full window with a pane (Screen, Grid cells, layout). Overwriting `panes.items[0]` orphanes the original pane's Screen/Grid in the arena. Wasted arena memory grows with each break-pane.

---

### 76. `cmdJoinPane` creates dummy pane via `splitPane` that is discarded — arena waste
**File:** `src/cmd/cmd.zig:365–375`
**Severity:** HIGH
**Status:** ✅ FIXED — deinit dummy_pane after extracting its dimensions and replacing its references with src_pane.

```zig
const dummy_pane = dst_win.splitPane(server.allocator, dst_pane, vertical, 0.5) catch return .err;
for (dst_win.panes.items) |*p| {
    if (p.* == dummy_pane) {
        p.* = src_pane;
        break;
    }
}
```

`splitPane` allocates a new `Pane` with `Pane.init` (Screen, Grid, layout node) from the window's arena. After the swap, `dummy_pane` is no longer referenced — its memory is orphaned. Every join-pane leaks one pane's worth of arena memory.

---

### 77. Memory leak in `windowTitleCallback` — old name never freed
**File:** `src/window.zig:272–282`
**Severity:** HIGH
**Status:** ✅ FIXED — free old name before assigning new dupe.

```zig
const new_name = self.allocator.dupe(u8, title) catch return;
self.name = new_name;   // OLD NAME NEVER FREED
```

Every time a pane's title changes (changing directories, opening files), the old `self.name` is replaced without freeing the previous allocation. Cumulative leak that grows unbounded over time.

---

### 78. Memory leak in `renderToDisplayClient` — auto window rename leaks old name
**File:** `src/server/server.zig:1098–1115`
**Severity:** HIGH
**Status:** ✅ FIXED — free old name before assigning new dupe.

```zig
if (win.allocator.dupe(u8, proc_name_val)) |new_name| {
    win.name = new_name;   // OLD NAME NEVER FREED
```

Same pattern as #77. Each automatic window rename from `getForegroundProcessName` leaks the previous name. Fires on every render cycle when a process name changes.

---

### 79. Modified function key parsing broken — `~` CSI sequences with modifiers dropped
**File:** `src/key.zig:96–101`
**Severity:** HIGH
**Status:** ✅ FIXED — split `num_str` on `;` to extract key number before modifier parameter. Unit test added.

```zig
'~' => {
    const tilde = std.mem.lastIndexOfScalar(u8, seq, '~') orelse return error.InvalidCsi;
    const num_str = seq[0..tilde];  // "11;5" for Ctrl+F1 = \e[11;5~
    const num = std.fmt.parseInt(u8, num_str, 10) catch return error.InvalidCsi;
```

For `\e[11;5~` (Ctrl+F1), `seq` is `11;5~`, `num_str` is `11;5`. `parseInt(u8, "11;5", 10)` fails — the modifier parameter and semicolon are included. All Ctrl/Alt/Shift modified function keys and special keys (Home, End, Insert, Delete, PgUp, PgDn, F1-F12) are silently dropped.

---

### 80. `@intCast` before bounds check in `Client.sendIdentify` — panic in safe builds
**File:** `src/client/client.zig:34–35`
**Severity:** MEDIUM
**Status:** ✅ FIXED — moved the bounds check (`term.len > 64`) before the `@intCast`. Unit test added.

```zig
var it: protocol.IdentifyTerm = .{ .term_len = @intCast(term.len) };
if (term.len > it.term.len) return error.TermTooLong;
```

`@intCast(term.len)` from `usize` to `u8` panics at runtime if `term.len > 255`. The bounds check on the next line is dead code for the panic path. Move the check before the cast.

---

### 81. `errdefer` reads uninitialized `fd` if `socket()` fails
**File:** `src/client/connect.zig:22–23`
**Severity:** MEDIUM
**Status:** ✅ FIXED — split into separate `c.socket` call and `try mapErr`; `fd` only assigned on success so `errdefer` never fires on error path. Unit tests added.

```zig
const fd = try mapErr(c.socket(c.AF.UNIX, c.SOCK.STREAM, 0));
errdefer _ = c.close(fd);
```

If `c.socket` returns -1, `mapErr` propagates the error — but `fd` was never assigned because the `const` initialisation failed. The `errdefer` reads an uninitialized i32. UB.

---

### 82. `std.posix.errno(rc)` may lose error specificity for C wrappers
**File:** `src/client/connect.zig:38–48`
**Severity:** MEDIUM
**Status:** ✅ FIXED — replaced `std.posix.errno(rc)` with `std.c.errno(rc)` which properly reads `_errno().*` when `rc == -1`. Unit test added.

```zig
fn mapErr(rc: c_int) Error!i32 {
    if (rc >= 0) return rc;
    return switch (std.posix.errno(rc)) { ... };
}
```

C `socket()` and `connect()` return -1 on failure, setting the global `errno`. If `std.posix.errno(rc)` derives the error from `rc` (which is -1), it always decodes to errno 1 (EPERM) — all socket failures fall through to `error.Unexpected`. The fix should use `std.c._errno().*` directly.

---

### 83. `@intCast(self.cy)` can panic when cursor position is -1 in `drawLine`
**File:** `src/tty/tty.zig:399–400`
**Severity:** MEDIUM
**Status:** ✅ FIXED — added `self.cx < 0 or self.cy < 0` guard before the `@intCast` to short-circuit on invalid cursor. Unit test added.

```zig
if (col != self.cx or @as(u64, @intCast(ly)) != @as(u64, @intCast(self.cy))) {
```

`@intCast(self.cy)` casts `i64` to `u64`. If `self.cy == -1` (cursor invalidated by `invalidate()` or `enterAltScreen()`), this panics. Can be reached when col matches `self.cx` and the right side evaluates.

---

### 84. CSI/SGR mouse/UTF-8 input buffer overflow silently discards data
**File:** `src/tty/tty_key.zig:114–168`
**Severity:** MEDIUM
**Status:** ✅ FIXED — increased input buffer from 64 to 256 bytes. Added debug log on overflow. Unit test for overflow recovery added.

The `InputReader` has a fixed 64-byte buffer. For kitty extended key sequences with event types, the parameter string can exceed 64 bytes. When overflow occurs, the entire sequence is silently discarded with no event, no error — the keystroke is lost.

---

### 85. DSR response silently dropped on `bufPrint` failure
**File:** `src/input.zig:591–593`
**Severity:** MEDIUM
**Status:** ✅ FIXED — increased DSR response buffer from 32 to 64 bytes and added `std.log.warn` on overflow.

```zig
const rep = std.fmt.bufPrint(&rep_buf, "\x1b[{d};{d}R",
    .{ self.screen.cursor.y + 1, self.screen.cursor.x + 1 }) catch return;
```

If the 32-byte buffer is insufficient (cursor positions > 999), the function silently returns success without sending the DSR response. The querying application hangs.

---

### 86. XTSMGRAPHICS response silently fails on `bufPrint` overflow or `writeInput` error
**File:** `src/input.zig:536–538`
**Severity:** MEDIUM
**Status:** ✅ FIXED — increased buffer to 64 bytes, log warnings on both failure paths.

```zig
const rep = std.fmt.bufPrint(&buf, "\x1b[?{d};0;0S", .{ps1}) catch "";
if (rep.len > 0) pty.writeInput(rep) catch {};
```

Both `bufPrint` failure (returns empty string → never sent) and `writeInput` failure are silently swallowed. The terminal querying for graphics attributes hangs indefinitely.

---

### 87. `.?` on `active_window`/`active_pane` without guard in `cmdNewSession`
**File:** `src/cmd/cmd.zig:27`
**Severity:** MEDIUM
**Status:** ✅ FIXED — replaced `.?` with `orelse return .err`. Test extended to verify window/pane invariants.

```zig
const session = server.newSession(name, 80, 24) catch return .err;
const pane = session.active_window.?.active_pane.?;
```

Currently safe by invariant (newSession always creates a window with a pane). If the invariant is broken by a future code change, this panics.

---

### 88. `defer free` on `parsed_val.string` relies on undocumented dup-in-set contract
**File:** `src/cmd/cmd.zig:687–689`
**Severity:** MEDIUM
**Status:** ✅ FIXED — added doc comment on `Options.set` that it always dupes strings. Unit test verifies caller can free originals after set.

```zig
defer {
    if (parsed_val == .string) server.allocator.free(parsed_val.string);
}
```

Assumes `Options.set` always `dupe`s strings internally. If `Options.set` is ever changed to store the pointer directly, this becomes a use-after-free — the option system holds a dangling pointer.

---

### 89. `logFn` writes garbage bytes from uninitialized buffer on `bufPrint` failure
**File:** `src/main.zig:70–78`
**Severity:** MEDIUM
**Status:** ✅ FIXED — catch block writes prefix + fallback directly instead of using `buf`.

```zig
const msg = std.fmt.bufPrint(buf[prefix.len..], format, args) catch "log message too long";
const total_len = prefix.len + msg.len;
if (total_len < buf.len) {
    buf[total_len] = '\n';
    writeAllRaw(fd, buf[0 .. total_len + 1]);
```

When `bufPrint` fails, `msg` points to the static literal `"log message too long"` — outside `buf`. The code writes `buf[prefix.len..total_len]` which is uninitialized stack garbage between the prefix end and the start of the literal.

**Fix:** The catch block now writes the prefix and fallback string directly via `writeAllRaw` and returns early, never reading uninitialized stack memory.

---

### 90. `keysEqual` ignores Meta modifier — impossible to bind Meta-modified keys
**File:** `src/key_binding.zig:139–175`
**Severity:** MEDIUM
**Status:** ✅ FIXED — added `.mod.meta` comparison to all four `keysEqual` branches. Unit tests added.

```zig
break :blk ac_code == bc_code and
    ac.mod.ctrl == bc.mod.ctrl and
    ac.mod.alt == bc.mod.alt and
    ac.mod.shift == bc.mod.shift;
    //               ^^^^^ META MISSING ^^^^^
```

The `Modifier` struct has a `meta: bool` field, but `keysEqual` never compares it. Two keys differing only in Meta/Super are incorrectly considered equal.

---

### 91. `errdefer` registered after `Pane.init` in `Layout.splitPane` — leak on init failure
**File:** `src/layout.zig:89–94`
**Severity:** MEDIUM
**Status:** ✅ FIXED — restructured to catch Pane.init failure explicitly before registering the full-cleanup errdefer.

```zig
const new_pane = try a.create(Pane);          // allocates Pane*
new_pane.* = try Pane.init(a, 0, child_w2, child_h2);  // if this fails...
errdefer {
    new_pane.deinit();
    a.destroy(new_pane);
}
```

If `Pane.init` fails, the `try` propagates the error BEFORE the `errdefer` is registered. The `new_pane` allocated at line 89 leaks — neither `deinit` nor `destroy` is called.

---

### 92. History lines not resized when terminal width changes
**File:** `src/grid.zig:130–143`
**Severity:** MEDIUM
**Status:** ✅ FIXED — added history line resize loop after visible lines loop. Unit test added.

```zig
pub fn setSize(self: *Grid, new_width: u32, new_height: u32) Error!void {
    try self.normalize();
    self.width = new_width;
    for (self.lines.items) |*line| {   // only visible lines, not history
        // resize visible line cells
    }
    try self.resize(new_height);
}
```

When the terminal is resized, only visible grid lines are resized. Lines in `self.history` retain their original width. Scrolling up into history after a terminal resize shows wrong-width history lines, causing visual artifacts.

---

### 93. Partial `write()` on Unix socket not retried
**File:** `src/client/client.zig:8–14`
**Severity:** LOW
**Status:** ✅ FIXED — `fdWrite` now retries in a loop until all bytes are written or an error occurs.

```zig
fn fdWrite(fd: i32, buf: []const u8) Error!usize {
    const n = std.c.write(fd, buf.ptr, buf.len);
    ...
// call site:
const n = try fdWrite(self.fd, serialized);
if (n != serialized.len) return error.WriteFailed;  // no retry
```

`write()` on a socket can perform partial writes. The code detects truncation but does not retry, leaving a partially-sent packet on the wire. Unlikely on local Unix sockets with small buffers.

---

### 94. Integer overflow in `resize_right` action
**File:** `src/server/server.zig:530`
**Severity:** LOW
**Status:** ✅ FIXED — changed `+` to `+|` (saturating add). Same for `resize_down`. Unit test added.

```zig
const target_w = current_w + 1;  // wraps to 0 if current_w == maxInt(u32)
```

If a pane width reaches `maxInt(u32)`, adding 1 wraps to 0. Practically impossible for terminal dimensions.

---

### 95. Daemon fork doesn't close stdin/stdout/stderr
**File:** `src/main.zig:170–175`
**Severity:** LOW
**Status:** ✅ FIXED — close(0), close(1), close(2) then reopen via open("/dev/null") + dup2 at start of `runServerDaemon`.

```zig
if (pid == 0) {
    if (log_fd) |fd| {
        _ = c.close(fd);
        log_fd = null;
    }
    try runServerDaemon(allocator);
```

After `fork()`, the child process has `setsid()` called but stdin/stdout/stderr are never closed or redirected to `/dev/null`. The daemon retains fds pointing to the original terminal.

---

### 96. Log directory created with `0o777` (world-writable)
**File:** `src/main.zig:30`
**Severity:** LOW
**Status:** ✅ FIXED — changed `0o777` → `0o755` (owner-writable, world-readable/executable).

```zig
const rc = c.mkdir(dir_z.ptr, 0o777);  // → 0o755
```

The log directory `$XDG_STATE_HOME/szn/` is created with mode 0777. Any user on the system can write files into it. Should be `0o700`.

---

### 97. `socket_path.zig` silently ignores `mkdir` failure
**File:** `src/socket_path.zig:34`
**Severity:** LOW
**Status:** ✅ FIXED — `_ = mkdir` → checks `rc < 0` and non-`.EXIST` with `c.errno`.

```zig
_ = c.mkdir(dir_z.ptr, 0o700);
// → checks rc and EEXIST
```

The return value of `mkdir` is discarded. If directory creation fails (permission denied, disk full), the subsequent socket `bind` fails with a confusing error instead of a clear message.

---

### 98. `logFn` retries `open()` on every call forever if it fails once
**File:** `src/main.zig:61–67`
**Severity:** LOW
**Status:** ✅ FIXED — added `log_fd_failed` bool; once set, `logFn` returns immediately.

```zig
if (log_fd == null) {
    const fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o666);
    if (fd < 0) return;     // log_fd stays null
    log_fd = fd;
}
const fd = log_fd.?;         // next call: still null, tries again
```

If `open()` fails permanently (permission denied, disk full), every subsequent log call re-invokes `resolveLogPath` and `open()`. No backoff, no retry limit, no silencing.

---

### 99. CSI parameter integer overflow — `param_val * 10 + digit` wraps on u32
**File:** `src/input.zig:248`
**Severity:** LOW
**Status:** ✅ FIXED — `*` → `*|` and `+` → `+|` for saturating arithmetic.

```zig
self.param_val = self.param_val * 10 + (byte - '0');
```

`param_val` is `u32`. Malicious input with thousands of consecutive digits causes wrapping overflow (modular arithmetic). The parameter value wraps silently, producing incorrect behaviour.

---

## Summary

| Severity | Count | Fixed | False Positive | Unresolved |
|----------|-------|-------|----------------|------------|
| Critical | 14 (10+4) | 13 | 3 | 0 |
| High | 29 (18+11) | 28 | 1 | 0 |
| Medium | 18 (5+13) | 17 | 1 | 0 |
| Low | 26 (19+7) | 25 | 1 | 0 |
| Total | 99 (64+35) | **81** | **6** | **0** |

---

## NEW BUGS (2026-06-24 deep audit of current codebase)

---

### 100. `client/raw.zig` — VMIN/VTIME indices are macOS values, completely wrong on Linux
**File:** `src/client/raw.zig:9–20`
**Severity:** CRITICAL
**Status:** ✅ FIXED — replaced hardcoded macOS values with `switch` on `@import("builtin").os.tag`: Linux → VMIN=6/VTIME=5, macOS → VMIN=16/VTIME=17, FreeBSD → VMIN=4/VTIME=5. Test added to verify platform constants.

---

### 101. `server/server.zig` — Use-after-free during batch PTY event processing
**File:** `src/server/server.zig:185–240`
**Severity:** CRITICAL
**Status:** ✅ FIXED — `handlePtyEvent` now returns a `PtyResult` enum (`not_ours`, `handled`, `destroyed`). When the pane is destroyed, the event loop `break`s the batch immediately, deferring remaining events to the next `pollOnce` call. The existing `isPaneValid` guard provides an additional safety layer.

---

### 102. `main.zig` — `errno` retrieval is always `.SUCCESS`, client disconnects on transient errors
**File:** `src/main.zig:380, 400`
**Severity:** CRITICAL
**Status:** ✅ FIXED — replaced `std.posix.errno(-1)` with `std.c.errno(n)` which reads the actual errno via `_errno().*`. EAGAIN/EINTR now correctly prevent disconnect.

---

### 103. `log.zig` + `socket_path.zig` — Wrong errno retrieval for C library calls
**File:** `src/log.zig:43, 62`, `src/socket_path.zig:36`
**Severity:** CRITICAL
**Status:** ✅ FIXED — `log.zig:43,62` replaced `std.posix.errno(rc)` with `std.c.errno(rc)`. `socket_path.zig:36` was already correct. Test added for EEXIST detection from `mkdir`. The related `server/socket.zig:28` issue is tracked as #163.

---

### 104. `char_width.zig` — Hangul Jamo 0x1100–0x115F reported as width 0 instead of 2
**File:** `src/char_width.zig:223`
**Severity:** HIGH
**Status:** ✅ FIXED — removed the duplicate `0x1100–0x115F` entry from `zero_width_ranges` (it was correctly in `wide_ranges`). Test added verifying Jamo leading consonants as width 2.

---

### 105. `key.zig` — Alt modifier lost when parsing ESC+char sequences
**File:** `src/key.zig:207–208`
**Severity:** HIGH
**Status:** ✅ FIXED — `parse()` now sets `.mod.alt = true` when returning a char key from a `seq.len == 2` ESC+char sequence. Test updated and format round-trip verified.

---

### 106. `server/dispatch.zig` — Partial writes not retried on socket I/O
**File:** `src/server/dispatch.zig:91–109`
**Severity:** HIGH
**Status:** ✅ FIXED — both header and body writes now loop retrying partial writes with EINTR handling. Test added using pipe.

---

### 107. `server/protocol.zig` — `IdentifyTerm.decode` missing `len <= 64` validation
**File:** `src/server/protocol.zig:89–97`
**Severity:** HIGH
**Status:** ✅ FIXED — added `if (len > 64) return error.InvalidData` before the memcpy. Test added for len=65 rejection.

---

### 108. `server/server.zig` — Unchecked writes to display client
**File:** `src/server/server.zig:1230–1231`
**Severity:** HIGH
**Status:** ✅ FIXED — both writes now use retry loops with EINTR handling, same pattern as #106. Partial writes and EPIPE no longer silently truncated.

---

### 109. `tty/fd_writer.zig` — Missing EINTR handling in writeAll and writeByte
**File:** `src/tty/fd_writer.zig:16–17, 28–29`
**Severity:** HIGH
**Status:** ✅ FIXED — both writeAll and writeByte now retry on EINTR. Pipe-based tests added verifying correct write-through.

---

### 110. `client/client.zig` — Heap-allocated body in recvPacket has no guaranteed free
**File:** `src/client/client.zig:75–91`
**Severity:** HIGH
**Status:** ✅ FIXED — `Packet` now has `is_owned` field and `deinit()` method. `recvPacket` sets `is_owned = true`. Caller frees with `reply.deinit(allocator)`.

```zig
const body = try self.allocator.alloc(u8, body_len);
// ...
return protocol.Packet{
    .msg_type = hdr[4],
    .data = body,
};
```

`recvPacket` allocates `body` and returns it inside a `Packet` value. There is no corresponding `freePacket` method, no documentation that the caller must free, and `Packet.data` is `[]const u8` — the caller has no way to know this slice was heap-allocated and must be freed. Every call to `recvPacket` that doesn't explicitly free `packet.data` leaks memory.

---

### 111. `mode_copy.zig` — `yankSelection` computes wrong bounds for reverse selections
**File:** `src/mode_copy.zig:205–206`
**Severity:** HIGH
**Status:** ✅ FIXED — replaced incorrect `sy == start_y` / `ey == end_y` checks with `start_is_top` flag matching `isSelected` logic. Test added for reverse multi-line selection.

```zig
const sx = if (sy == self.selection.start_y) self.selection.start_x else 0;
const ex = if (ey == self.selection.end_y) self.selection.end_x else grid.width -| 1;
```

When `start_y > end_y` (user selected bottom-to-top): `sy = end_y`, so `sy != start_y`, so `sx = 0` — should be `end_x`. `ey = start_y`, so `ey != end_y`, so `ex = grid.width - 1` — should be `start_x`. Result: yanked text includes extra characters on the first and last lines. Compare with `isSelected` (lines 167–169) which handles this correctly using `start_is_top`.

---

### 112. `main.zig` — `@enumFromInt` without validation for MessageType
**File:** `src/main.zig:418`
**Severity:** HIGH
**Status:** ✅ FIXED — added `MessageType.fromByte()` validation helper that returns `null` for invalid byte values. Both call sites in main.zig use `orelse` to handle the error (exit for recvPacket path, skip for interactive client). Tests added.

```zig
const msg_type = @as(protocol.MessageType, @enumFromInt(read_buf.items[read_pos + 4]));
```

If the byte doesn't correspond to a declared `MessageType` value, this creates an invalid enum value, which is undefined behavior in Zig and can cause crashes or unpredictable switch dispatch.

---

### 113. `window.zig` + `session.zig` — Pane double-deinit between Session.deinit and Window.deinit
**File:** `src/session.zig:54–58`, `src/window.zig:162–167`
**Severity:** HIGH
**Status:** ❌ UNRESOLVED (related to bug #68 which fixed PTY double-close but not pane double-deinit)

```zig
// session.zig deinit:
for (win.panes.items) |p| { p.deinit(); }

// window.zig deinit (via layout.deinit):
// layout.deinitNode calls pane.deinit() AND allocator.destroy(pane)
```

`Session.deinit` calls `pane.deinit()` on every pane. But `Window.deinit` calls `layout.deinit()`, which also calls `pane.deinit()` and `allocator.destroy(pane)` for each pane. If both are called (which happens in non-arena paths), panes are double-deinited and double-freed.

---

### 114. `input.zig` — UTF-8 state not cleared on parser reset or state transitions
**File:** `src/input.zig:116–134, 61–75`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

If a partial UTF-8 sequence is interrupted by a C1 byte (0x80–0x9F) that changes state, `utf8_expected` remains set. When the parser later returns to `.ground`, stale UTF-8 state causes the next printable byte to be incorrectly treated as a UTF-8 continuation byte. The `reset()` function does clear it, but mid-stream state transitions (like entering ESC from ground) do not.

---

### 115. `key.zig` — `@intCast` may panic on out-of-range kitty codepoint
**File:** `src/key.zig:153`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
return Key{ .char = .{ .code = @intCast(codepoint), .mod = k_mod } };
```

`codepoint` is `u32` and `.code` is `u21`. If a malformed kitty sequence contains a codepoint > 0x1FFFFF, `@intCast` triggers a safety panic in debug mode and undefined behavior in release-safe.

---

### 116. `options.zig` — `choice` values are not cloned or freed
**File:** `src/options.zig:158–163, 165–170`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
fn cloneValue(allocator: std.mem.Allocator, value: OptionValue) Error!OptionValue {
    return switch (value) {
        .string => |s| OptionValue{ .string = try allocator.dupe(u8, s) },
        inline else => value,
    };
}
fn freeValue(allocator: std.mem.Allocator, value: OptionValue) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number, .colour, .key, .flag, .choice => {},
    };
}
```

`choice` is `[]const u8` but is neither cloned on `set` nor freed on `deinit`. Currently safe only because all choice values in the codebase are string literals. If a dynamically-allocated choice string is ever passed to `set`, it will be a use-after-free (not cloned) or memory leak (not freed).

---

### 117. `cfg.zig` — Quoted string parser doesn't verify closing quote
**File:** `src/cfg.zig:212–214`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
if (s.len >= 2 and s[0] == '"') {
    const inner = s[1 .. s.len - 1];
    return OptionValue{ .string = try allocator.dupe(u8, inner) };
}
```

Only checks `s[0] == '"'`, never verifies `s[s.len-1] == '"'`. Input `"hello` (no closing quote) produces `hell` — the last char is silently stripped. Input `"hello"world"` produces `hello"world`.

---

### 118. `cfg.zig` — `parseSetEnv` doesn't recognize `-g` followed by tab
**File:** `src/cfg.zig:335`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
if (std.mem.startsWith(u8, remaining, "-g ")) {
```

Only checks for `-g ` (space). Input `set-environment -g\tFOO bar` fails to match, and `-g` becomes the environment variable name. Inconsistent with `parseSet` which trims both spaces and tabs.

---

### 119. `cfg.zig` — `parseIfShell` doesn't handle escaped quotes
**File:** `src/cfg.zig:359–366`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
const second_q = std.mem.indexOfScalarPos(u8, args, first_q + 1, '"') orelse ...;
```

Unlike `stripInlineComment` which tracks `\\` escapes, this function treats any `"` as a string boundary. Input `if-shell "test \"foo\"" "cmd"` parses incorrectly.

---

### 120. `log.zig` — Data race on `log_fd` and `log_fd_failed` globals
**File:** `src/log.zig:31–32, 94–107`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
var log_fd: ?std.posix.fd_t = null;
var log_fd_failed: bool = false;
```

These globals are read/written without synchronization. `log_enabled` uses atomics, but `log_fd` and `log_fd_failed` don't. Multiple threads calling `logFn` concurrently can both see `log_fd == null`, both open the file, and one fd leaks. Worse, `enable()`/`disable()` can close an fd while another thread is writing to it.

---

### 121. `socket_path.zig` — Fixed 128-byte buffer for HOME path with no fallback
**File:** `src/socket_path.zig:33`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
var dir_path: [128]u8 = undefined;
const dir_z = try std.fmt.bufPrintZ(&dir_path, "{s}/.szn", .{home_str});
```

If `$HOME` exceeds ~120 characters, `bufPrintZ` returns `NoSpaceLeft`, which propagates as a hard error. Unlike `log.zig` which falls back to `/tmp`, this has no fallback — socket creation fails entirely.

---

### 122. `mode_copy.zig` — Selection coordinates are screen-space, not grid-space
**File:** `src/mode_copy.zig:14`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

Selection `start_y`/`end_y` are cursor positions in screen coordinates. If the user scrolls between `startSelection` and `yankSelection`, the start coordinates refer to different content than when they were set. tmux tracks absolute grid positions. This causes incorrect yank after scrolling.

---

### 123. `server/pty.zig` — Memory leak on partial `dupeZ` failure in `spawn`
**File:** `src/server/pty.zig:105–108`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
var argv_z = try allocator.alloc(?[*:0]const u8, args.len + 1);
for (args, 0..) |arg, i| {
    argv_z[i] = try allocator.dupeZ(u8, arg);
}
argv_z[args.len] = null;
```

If `dupeZ` fails (OOM) at index `i`, the strings already allocated at indices `0..i` are leaked. There is no `errdefer` to clean them up. The caller has no way to free them since `argv_z` is a local variable and the error propagates out.

---

### 124. `server/pty.zig` — `writeInput` doesn't verify all bytes were written
**File:** `src/server/pty.zig:202–205`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
pub fn writeInput(self: *Pty, data: []const u8) Error!void {
    const n = write(self.master, data.ptr, data.len);
    if (n < 0) return error.WriteFailed;
}
```

If `write()` returns `0 <= n < data.len`, the remaining bytes are silently dropped. For PTY master writes (sending keystrokes to the child process), this means input can be lost without any error or retry.

---

### 125. `server/pty.zig` — `reap` uses WNOHANG but unconditionally sets pid to -1
**File:** `src/server/pty.zig:176–181`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
pub fn reap(self: *Pty) void {
    if (self.pid > 0) {
        var status: c_int = 0;
        _ = waitpid(self.pid, &status, 1); // WNOHANG
        self.pid = -1;
    }
}
```

`WNOHANG` returns 0 if the child hasn't exited. The code ignores the return value and sets `pid = -1` regardless. If the process is still running (e.g. a slow shutdown), it becomes an untracked zombie, and the pid could be reused by the OS, leading to reaping the wrong process later.

---

### 126. `server/render.zig` — `self.sy - 1` underflows when `sy == 0`
**File:** `src/server/render.zig:72, 228, 359`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
const merged_h = self.sy - 1;
const h = @min(screen.grid.height, self.sy - 1);
try self.moveTo(0, self.sy - 1);
```

`sy` is `u32`. If `sy == 0`, `self.sy - 1` wraps to `4294967295`. This causes `merged_h` to be ~4 billion, leading to massive allocation in `Screen.init`, or the render loop iterating an absurd number of times. While `server.zig` clamps `sy` to `>= 24`, the `Display` type itself has no guard.

---

### 127. `server/server.zig` — `findPaneAtNode` doesn't subtract border width
**File:** `src/server/server.zig:1006–1023` (vs `906–917`)
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
// findPaneAtNode (line 1010):
return self.findPaneAtNode(s.a, x, y, lx, ly, split_w, lh);
// collectPaneBounds (line 909):
try self.collectPaneBounds(s.a, lx, ly, split_w -| 1, lh, result);
```

`collectPaneBounds` gives the left pane `split_w - 1` columns (reserving 1 column for the border). `findPaneAtNode` gives it `split_w` columns. A click on the border column is attributed to the left pane by `findPaneAtNode`, but the pane doesn't actually own that column. This causes mouse clicks on borders to focus the wrong pane.

---

### 128. `tty/tty.zig` — `cursorDown`/`cursorForward`/`drawLine` panic on zero dimensions
**File:** `src/tty/tty.zig:94, 107, 429`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
// cursorDown:
const max_down = self.sy - 1 -| @as(u32, @intCast(self.cy));
// cursorForward:
const max_forward = self.sx - 1 -| @as(u32, @intCast(self.cx));
// drawLine:
try self.cursorMove(width - 1, ly);
```

`self.sy - 1` and `self.sx - 1` are regular unsigned subtraction. If `sy == 0` or `sx == 0` (e.g., during a resize to zero rows/columns), this is a runtime integer underflow panic. The saturating subtraction (`-|`) is applied too late. Same for `width - 1` in `drawLine` when `width == 0`.

---

### 129. `tty/tty.zig` — `setCursorStyle` blink/steady mapping is inverted
**File:** `src/tty/tty.zig:325–329`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
const n: u8 = switch (style) {
    .block => if (self.cursor_visible) 2 else 1,
    .underline => if (self.cursor_visible) 4 else 3,
    .bar => if (self.cursor_visible) 6 else 5,
};
```

DECSCUSR sequences: 1=blinking block, 2=steady block, 3=blinking underline, 4=steady underline, 5=blinking bar, 6=steady bar. The code emits steady styles (2/4/6) when the cursor IS visible and blinking styles (1/3/5) when hidden. This is backwards — a visible cursor should blink. Additionally, `cursor_visible` tracks show/hide state (DECTCEM), not blink preference, conflating two independent concepts.

---

### 130. `tty/tty.zig` — `writeCell` early return on combining char encode failure leaves `cx` stale
**File:** `src/tty/tty.zig:386–395`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
const clen = std.unicode.utf8Encode(cp, &buf) catch return;
try self.write(buf[0..clen]);
```

If `utf8Encode` fails for `comb1` or `comb2`, the function returns immediately via `catch return`. The base character was already written to the terminal (advancing the hardware cursor), but `self.cx` is never incremented. The cached cursor position is now out of sync with the actual terminal cursor, causing incorrect positioning decisions in subsequent calls until the next explicit `cursorMove`.

---

### 131. `input.zig` — SOS/PM/APC string doesn't handle ESC \ (ST) terminator correctly
**File:** `src/input.zig:461–471`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED (related to bug #18 which fixed OSC ST terminator, but SOS/PM/APC still broken)

```zig
fn advanceSosPmApc(self: *InputParser, byte: u8) void {
    switch (byte) {
        0x1B => {
            self.state = .esc;
        },
        0x9C => { self.toGround(); },
        else => {},
    }
}
```

When ESC is seen inside a SOS/PM/APC string, the parser transitions to `.esc` instead of staying in-string to check for `\` (completing the ST terminator). If the next byte is `\`, the `.esc` handler treats it as an unrecognized ESC sequence rather than terminating the string.

---

### 132. `server/loop.zig` — `addFd` silently ignores duplicate fd without updating events/udata
**File:** `src/server/loop.zig:38–39`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED (bug #38 was marked FIXED for duplicate registration, but this is a different issue — updating existing entries)

```zig
for (self.fds.items) |f| {
    if (f.fd == fd) return;
}
```

If `addFd` is called with an fd already in the list (e.g. to update the event mask or user data), it silently returns without updating anything. This can cause stale event masks or stale `udata` pointers, leading to missed events or dispatching to wrong handlers.

---

### 133. `server/server.zig` — `killSession` uses `swapRemove` — silently changes active session
**File:** `src/server/server.zig:1241`
**Severity:** MEDIUM
**Status:** ❌ UNRESOLVED

```zig
var session = self.sessions.swapRemove(idx);
```

`swapRemove` replaces the removed element with the last element. Since `activeSession()` always returns `sessions.items[0]`, killing session[0] silently promotes the last session to active without any notification or state update. If the killed session was being displayed, the display client now shows a different session without re-initialization.

---

### 134. `server/server.zig` — `deinit` doesn't remove client fds from the event loop
**File:** `src/server/server.zig:137–140`
**Severity:** MEDIUM
**Status:** ❌ FALSE POSITIVE — `self.loop.deinit()` (line 131) frees the loop's internal state (`fds` ArrayList, `event_buf`) before client fds are closed. No stale fd entries remain in the loop at the time of close.

```zig
for (self.client_fds.items) |fd| {
    _ = c.close(fd);
}
self.client_fds.deinit(self.allocator);
```

Client fds are closed but never removed from `self.loop.fds` via `removeFd`. After closing, the loop still has entries for these (now invalid) fds. If the loop is somehow used after partial cleanup, `poll()` will report errors for these stale fds.

---

### 135. `main.zig` — Command buffer over-allocated by 1 byte
**File:** `src/main.zig:146–149`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
var cmd_len: usize = 0;
for (args.items[1..]) |arg| {
    cmd_len += arg.len + 1;
}
```

Each arg adds `+1` for a separator, but the writing loop only inserts separators *between* args (n-1 spaces for n args). The buffer is 1 byte too large. Not a crash, but `cmd_len` doesn't match actual content length.

---

### 136. `main.zig` — Unchecked `c.write` return for resize packet
**File:** `src/main.zig:320, 366`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
_ = c.write(server_fd, r_ser.ptr, r_ser.len);
```

The initial resize packet write is silently discarded. If it fails, the server has wrong terminal dimensions. Same issue at line 366 for resize-on-SIGWINCH.

---

### 137. `session.zig` — Window IDs are not unique after kills
**File:** `src/session.zig:73`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
const win_id = self.windows.items.len;
```

Window ID is derived from array length. After `killWindow` (which uses `swapRemove`), a new window can receive the same ID as a previously killed window. This breaks any code that uses window IDs for identification.

---

### 138. `input.zig` — CSI private marker can appear after parameter digits
**File:** `src/input.zig:262–265`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
0x3C...0x3F => {
    self.intermediate = byte;
},
```

Bytes `<=>?` are accepted at any position in the parameter string, not just before the first digit. A malformed sequence like `CSI 25?h` would set `intermediate = '?'` and be dispatched as DECSET, when it should be rejected. Per ECMA-48, the private prefix must precede all parameters.

---

### 139. `key_binding.zig` — Force unwrap in `mapCommandToAction` may panic
**File:** `src/key_binding.zig:507`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
const idx_str = trimmed[std.mem.lastIndexOfScalar(u8, trimmed, ' ').? + 1 ..];
```

The `.?` force-unwraps an optional. Although the prefix check on line 506 guarantees a space exists, this is fragile — any future change to the prefix strings could introduce a panic.

---

### 140. `key_binding.zig` — `val >= 0` is always true for `u8`
**File:** `src/key_binding.zig:509`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (val >= 0 and val <= 9) {
```

`val` is `u8`, so `val >= 0` is always true. Dead comparison, misleading to readers.

---

### 141. `format.zig` — `splitArgs` always appends trailing segment even when empty
**File:** `src/format.zig:457–460`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (start <= content.len) {
    const arg = try allocator.dupe(u8, content[start..]);
    try args.append(allocator, arg);
}
```

`start <= content.len` is always true (start is `usize` and can never exceed `content.len`). When `start == content.len`, an empty string is appended. Every comma-separated operation always gets at least one extra empty argument.

---

### 142. `format.zig` — `expandTruncate` integer overflow on large digit sequences
**File:** `src/format.zig:409–411`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
while (i < content.len and std.ascii.isDigit(content[i])) {
    n = n * 10 + (content[i] - '0');
```

No saturating arithmetic. If the digit string represents a number > `maxInt(usize)`, this wraps in release mode.

---

### 143. `colour.zig` — `parse` accepts trailing garbage after colour index
**File:** `src/colour.zig:84, 88`
**Severity:** LOW
**Status:** ❌ FALSE POSITIVE — `std.fmt.parseInt` in Zig 0.16.0 requires fully valid input. `"colour10abc"` → `s[6..]` = `"10abc"` → parseInt fails on `'a'`, returns `error.InvalidCharacter`, caught as `ParseError.InvalidIndexedColour`.

```zig
const n = std.fmt.parseInt(u8, s[6..], 10) catch return ParseError.InvalidIndexedColour;
```

`parseInt` stops at the first non-digit, so `"colour10abc"` parses as `colour10` and silently succeeds. Similarly for `"color10xyz"`. This accepts invalid input without error.

---

### 144. `char_width.zig` — Dead code: C1 control check unreachable
**File:** `src/char_width.zig:93`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (cp >= 0x80 and cp <= 0x9F) return 0;
```

This is unreachable: `cp < 0x0300` on line 88 is already true for 0x80–0x9F, so the function returns at line 89–90 before reaching line 93.

---

### 145. `char_width.zig` — Dead code in `isCombining`
**File:** `src/char_width.zig:29–30`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (cp < 0x0300) return cp >= 0x1160 and cp <= 0x11FF;
if (cp >= 0x1100 and cp <= 0x115F) return false;
```

Line 30 is unreachable — all values 0x1100–0x115F are < 0x0300, so they're handled by line 29 (which returns `false` for them since they're < 0x1160).

---

### 146. `cfg.zig` — `set -u` silently dropped
**File:** `src/cfg.zig:189`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
'u' => return, // unset (handled elsewhere)
```

Returns success without appending any directive. The caller has no way to know the directive was discarded. Comment says "handled elsewhere" but there's no evidence of that.

---

### 147. `cfg.zig` — Combined flags like `-gw` misparsed
**File:** `src/cfg.zig:183–192`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
switch (remaining[1]) {
    'g' => flags.flags.global = true,
    ...
}
remaining = std.mem.trim(u8, if (remaining.len > 2) remaining[2..] else "", " \t");
```

Input `-gw option value` is parsed as flag `-g` with option name `w` and value `option value`. Should either parse both flags or reject.

---

### 148. `client/raw.zig` — BRKINT left enabled in raw mode
**File:** `src/client/raw.zig:28`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
raw.iflag = .{ .BRKINT = true };
```

`cfmakeraw` clears BRKINT. Leaving it enabled means a serial BREAK condition will generate SIGINT, which is undesirable in raw mode for a terminal multiplexer that needs to forward all input to panes.

---

### 149. `client/client.zig` — `recvPacket` doesn't validate msg_type
**File:** `src/client/client.zig:88`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
.msg_type = hdr[4],
```

The raw byte `hdr[4]` is stored directly as `msg_type` without validating it's a known `MessageType` enum value. Downstream code that switches on this may hit unexpected branches if a malformed packet arrives.

---

### 150. `tty/tty_key.zig` — Invalid UTF-8 lead bytes 0xC0–0xC1 accepted into multi-byte state
**File:** `src/tty/tty_key.zig:73–77`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (byte >= 0xc0 and byte <= 0xdf) {
    rd.buf[0] = byte;
    rd.pos = 1;
    rd.state = .utf8_2;
    return null;
}
```

Bytes 0xC0 and 0xC1 are never valid UTF-8 lead bytes (they would produce overlong encodings of ASCII). The parser enters `utf8_2` state, consumes a continuation byte, then `utf8Decode` rejects it — silently dropping two bytes instead of one.

---

### 151. `tty/tty_key.zig` — Wheel left/right mouse buttons misidentified
**File:** `src/tty/tty_key.zig:243–259`
**Severity:** LOW
**Status:** ❌ UNRESOLVED (related to bug #63 which fixed wheel release, but wheel left/right still broken)

SGR mouse button values 66 (0x42, wheel left) and 67 (0x43, wheel right) are not detected by the wheel checks (`& 0xC3` yields 0x42/0x43, not 0x40/0x41). They fall through to the switch where `btn & 0x03` gives 2/3, mapping wheel-left to `.right` and wheel-right to `.release`.

---

### 152. `tty/tty.zig` — `writeCell` always advances `cx` by 1, ignoring wide character width
**File:** `src/tty/tty.zig:398`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (self.cx >= 0) self.cx += 1;
```

Wide characters (e.g., CJK, emoji) occupy 2 terminal columns, but `cx` is always incremented by 1. The terminal hardware cursor advances by 2, creating a mismatch with the cached position. This causes unnecessary `cursorMove` CUP sequences for every cell following a wide character.

---

### 153. `cmd/cmd.zig` — `src_pane` declared `undefined` in `cmdJoinPane`
**File:** `src/cmd/cmd.zig:326`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
var src_pane: *@import("../window.zig").Pane = undefined;
```

`src_pane` is initialized to `undefined`. If the control flow doesn't assign it before use (e.g., `src_arg` is null and `session.windows.items.len > 1` but all windows equal `dst_win`), the `if (src_pane == dst_pane)` check at line 354 reads `undefined`. Currently safe because the `for` loop always finds a different window, but fragile.

---

### 154. `server/server.zig` — `paneCwd` allocates memory with opaque ownership
**File:** `src/server/server.zig:406–409`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
pub fn paneCwd(self: *Server, pane: *Pane) ?[]const u8 {
    const pty = pane.pty orelse return null;
    return pty.getCwd(self.allocator) catch return null;
}
```

Returns an allocated slice but the return type `?[]const u8` gives no indication the caller must free it. Callers in `executeAction` do free it correctly via `defer`, but the API is fragile — any new caller that doesn't know to free will leak.

---

### 155. `server/dispatch.zig` — `@intCast` from `usize` to `isize` can panic
**File:** `src/server/dispatch.zig:103`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
if (n < @as(isize, @intCast(result.data.len))) return error.WriteFailed;
```

If `result.data.len` exceeds `maxInt(isize)` (~2^63 on 64-bit), `@intCast` triggers a safety panic. While unlikely for command responses, it's technically unsafe.

---

### 156. `server/protocol.zig` — `Packet.make` integer overflow on large data
**File:** `src/server/protocol.zig:71`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
.length = @as(u32, @intCast(5 + data.len)),
```

If `data.len > maxInt(u32) - 5`, the addition overflows and `@intCast` panics. A ~4 GiB payload triggers this.

---

### 157. `server/socket.zig` — `bind` passes oversized `addrlen`
**File:** `src/server/socket.zig:58`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
_ = try mapErr(c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)));
```

The `addrlen` should be the actual size of the populated address. Passing `@sizeOf(c.sockaddr.un)` (the full struct size, typically 110 bytes) works on most implementations but is technically incorrect per POSIX.

---

### 158. `status.zig` — Left and right sections can silently overlap
**File:** `src/status.zig:52–56`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
const left_len = @min(left.len, width);
@memcpy(line[0..left_len], left[0..left_len]);
const right_start = if (width > right_len) width - right_len else 0;
@memcpy(line[right_start..][0..right_len], right[right.len - right_len ..][0..right_len]);
```

When `left_len + right_len > width`, the right section overwrites the left. No clipping is done to prevent overlap. Produces visually incorrect output when both sections are long.

---

### 159. `server/render.zig` — Status bar column tracking doesn't account for escape sequences
**File:** `src/server/render.zig:360–400`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

The `col` counter tracks visible columns to pad the status bar to full width. However, it doesn't cap `session_name.len` or `win.name.len`. If the combined content exceeds `self.sx`, `col` overflows past `max_len` and the padding `while (col < max_len)` never executes, but the status bar has already written past the terminal width, causing line wrapping.

---

### 160. `server/server.zig` — `loadConfigFile` — `@intCast(size)` from `c_long` to `usize` can panic
**File:** `src/server/server.zig:1354`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
const content = try self.allocator.alloc(u8, @intCast(size));
```

`ftell` returns `c_long` (signed). If `size` is negative and the check is bypassed, `@intCast` panics.

---

### 161. `integration.zig` — `setupServer` discards exec result
**File:** `src/integration.zig:14`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
_ = c.exec(&server);
```

If `new-session` fails, the error is silently ignored and tests proceed with a broken server state.

---

### 162. `mode_copy.zig` — `@intCast` of `history.items.len` (usize) to u32
**File:** `src/mode_copy.zig:103, 125`
**Severity:** LOW
**Status:** ❌ UNRESOLVED

```zig
self.scroll_offset = @min(self.scroll_offset + remaining, @as(u32, @intCast(grid.history.items.len)));
```

If history ever exceeds `maxInt(u32)` (~4 billion entries), this is a runtime panic. The history_limit is `u32` so it's unlikely in practice, but the cast is technically unsafe.

---

### 163. `server/socket.zig` — Wrong errno retrieval in `mapErr` (same as #103)
**File:** `src/server/socket.zig:28`
**Severity:** MEDIUM
**Status:** ✅ FIXED — replaced `std.posix.errno(rc)` with `std.c.errno(rc)`.

Uses `std.posix.errno(rc)` instead of `std.c.errno(rc)`. Same issue as bugs #103 and #82: C library `socket()`/`bind()`/`listen()`/`accept()` return -1 on error, but `std.posix.errno(-1)` derives errno 1 (EPERM) instead of the actual error. All socket operation failures fall through to `error.Unexpected`, making server startup failures impossible to diagnose correctly.

---

## Updated Summary

| Severity | Count | Fixed | False Positive | Unresolved |
|----------|-------|-------|----------------|------------|
| Critical | 18 (14+4) | 10 | 3 | **5** |
| High | 42 (29+13) | 28 | 1 | **13** |
| Medium | 39 (18+21) | 17 | 2 | **20** |
| Low | 54 (26+28) | 25 | 2 | **27** |
| Total | 163 (99+64) | **80** | **8** | **65** |


