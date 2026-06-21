# Migration Plan: tmux (C) → szn (Zig)

## Why Zig?

| Problem in C | Zig Solution |
|---|---|
| `compat/` — 46 files, 7,108 lines of portability shims | `std.os`, `std.fs`, `std.net` — standard library covers all targets |
| `configure.ac` + `Makefile.am` — 1,319 lines of autotools | `build.zig` — 50 lines, built-in |
| `queue.h` / `tree.h` — 1,281 lines of macro-based data structures | `std.TailQueue`, `std.Treap`, `std.ArrayList` — generic, type-safe |
| `imsg` — 1,530 lines of custom IPC framework | Unix sockets + `std.io.Writer` / packed structs |
| `osdep-*.c` — 844 lines of platform probing | Zig comptime + `@import("builtin").os.tag` |
| `xmalloc.c` / OOM-on-NULL pattern | `try allocator.alloc(u8, n)` — alloc returns error, not null |
| `TAILQ_FOREACH` / `RB_INSERT` macros | `for (list.first) \|node\| { ... }` — real iteration |
| `if (x == NULL) return (-1)` everywhere | Error unions — `try` propagates automatically |
| `goto cleanup` | `defer` — scoped, composable |
| Function pointer tables + void* casts | Tagged unions — `switch` exhaustiveness checked |
| Integer state machines | Zig unions with variants per state |

## What We're Dropping

### Dead Platforms
- HP-UX, AIX, Solaris, Haiku, DragonFly, Cygwin
- **Kept**: Linux (glibc/musl), macOS, FreeBSD, OpenBSD
- No osdep files needed — Zig comptime detects platform

### Dead Features
- Lock server, server access control
- Keypad application mode (DECKPAM / MODE_KKEYPAD)
- X10 mouse, button-mode mouse, UTF-8 mouse (DECSET 1005)
- Only SGR mouse (DECSET 1006) and kitty extended keys

### Dead Terminal Protocols
- **Terminfo** — hardcode xterm-256color escape sequences
- **ACS/SCS** — emit UTF-8 box-drawing characters directly
- **Legacy key tables** — VT100/VT220 key sequences dropped
- **8/16-colour fallback** — RGB or 256, nothing less
- **X11 colour names** (578 entries) — `#RRGGBB` only
- **256-colour palette table** — accept `colourN` as shorthand, map via comptime

### Dead Build System
- `configure.ac`, `Makefile.am`, `autogen.sh` → `build.zig`
- `.travis.yml` → GitHub Actions if needed

### Compat Layer
Every file in `compat/` goes away. Zig's stdlib provides all of it.

---

## Testing-First Phases

Every phase has one deliverable: **`zig build test` passes**. Phases are ordered so
each can be implemented and tested in isolation without needing later phases.

```
Phase 0:  Scaffolding + test harness      (zig build test: compiles, 0 tests)
Phase 1:  Grid + Colour + Screen          (zig build test: 40+ tests, no I/O)
Phase 2:  Key + Session + Window + Layout (zig build test: 60+ tests, no I/O)
Phase 3:  Options + Config                (zig build test: 80+ tests, no I/O)
Phase 4:  TTY output engine               (zig build test: 100+ tests, strings only)
Phase 5:  TTY input parsing               (zig build test: 120+ tests, strings only)
Phase 6:  Input escape parser             (zig build test: 240+ tests, strings only)
Phase 7:  Format + Status                 (zig build test: 270+ tests, strings only)
Phase 8:  Mode + Key bindings             (zig build test: 300+ tests, strings only)
Phase 9:  Client-server IPC               (zig build test: 330+ tests, integration)
Phase 10: Commands                        (zig build test: 450+ tests, integration)
Phase 11: Full integration                (zig build test: 490+ tests, full stack)
```

---

## Phase 0: Scaffolding + Test Harness

**Goal**: `zig build` produces a binary, `zig build test` compiles and passes.

### Files
```
build.zig              — build target + test target
build.zig.zon          — package manifest
src/main.zig           — stub entry point
src/test.zig           — test runner (imports all module tests)
src/err.zig            — shared error sets
src/log.zig            — logging wrapper
```

### Test structure
```zig
// src/test.zig
comptime {
    // Phase 1 modules imported as they're created
    // _ = @import("grid.zig");
    // _ = @import("colour.zig");
}
```

### Acceptance
```
$ zig build test
All 0 tests passed.
```

---

## Phase 1: Grid + Colour + Screen

**Goal**: Grid data structure, colour types, and screen wrapper — all pure data,
fully unit-testable without I/O.

### `grid.zig` (~800 lines)
Replaces `grid.c`, `grid-view.c`, `grid-reader.c` (~2,300 lines of C).

```zig
pub const Cell = packed struct(u64) {
    char: u24,          // Unicode code point
    attr: Attr,         // bold, dim, italic, underline, blink, reverse, etc.
    fg: Colour,         // foreground colour
    bg: Colour,         // background colour
    _padding: u6,
};

pub const Attr = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    concealed: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    double_underline: bool = false,
    curly_underline: bool = false,
    _padding: u5,
};

pub const Colour = packed struct(u32) {
    tag: ColourTag,     // indexed, rgb, default, terminal
    value: u24,         // palette index or RGB value
};

pub const Grid = struct {
    lines: std.ArrayListUnmanaged(GridLine),
    width: u32,
    height: u32,
    // ...
};
```

**Tests** (20+):
- Create grid, write cells, read back
- Scroll lines into history
- Clear lines, clear screen
- Insert/delete lines
- Copy/paste regions
- Scrollback bounds (max history)
- Cell attribute combinations

### `colour.zig` (~300 lines)
Replaces `colour.c` (~1,179 lines of C).

```zig
pub const ColourTag = enum(u8) {
    indexed,   // colour0-colour255
    rgb,       // #RRGGBB
    default_,  // default colour
    terminal,  // terminal colour
};

pub fn parse(hex: []const u8) !Colour { ... }
pub fn paletteIndex(n: u8) Colour { ... }
pub fn toRgb(c: Colour) ?[3]u8 { ... }
```

**Tests** (15+):
- Parse `#RRGGBB` → correct RGB
- Parse `colour0` through `colour255`
- Reject invalid hex strings
- Reject unknown named colours
- Palette index 0-15 = ANSI, 16-231 = 6×6×6 cube, 232-255 = greyscale
- `default` and `terminal` round-trip correctly
- A named colour like `"red"` returns index 1, not an X11 colour

### `screen.zig` (~200 lines)
Replaces `screen.c` (~900 lines of C).

```zig
pub const Mode = packed struct(u32) {
    insert: bool = false,
    keypad: bool = false,     // MODE_KKEYPAD — kept for compat, not emitted
    line_wrap: bool = true,
    mouse_standard: bool = false,
    mouse_button: bool = false,
    mouse_utf8: bool = false,  // DECSET 1005 — not emitted, kept for input compat
    mouse_sgr: bool = false,
    focus: bool = false,
    paste: bool = false,
    alt_screen: bool = false,
    cursor: bool = true,
    origin: bool = false,
    _padding: u20,
};

pub const Screen = struct {
    grid: Grid,
    cursor: Cursor,
    mode: Mode,
    // ...
};
```

**Tests** (10+):
- Create screen, write chars, verify cursor moves
- Line wrapping on/off
- Scroll region
- Alt screen buffer swap
- Mode flag combinations

### Phase 1 Acceptance
```
$ zig build test
All 45 tests passed.
```

---

## Phase 2: Key + Session + Window + Layout

**Goal**: Core data types for session management — pure data, no I/O.

### `key.zig` (~300 lines)
Replaces parts of `key-string.c`, `tmux.h` key enum, `input-keys.c`.

```zig
pub const Key = union(enum) {
    char: u21,              // Unicode character
    function: Function,     // F1-F12
    arrow: Arrow,           // up/down/left/right
    modifier: ModifierSet,  // ctrl, alt, shift, meta combinations
    // ...
};

pub const Modifier = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    _padding: u4,
};

// Parse a CSI sequence like \e[1;5A → Ctrl+Up
pub fn parseCsi(seq: []const u8) !Key { ... }

// Format a key to its canonical string representation
pub fn format(key: Key) []const u8 { ... }
```

**Tests** (15+):
- Parse standard escape sequences
- Parse kitty extended sequences
- Reject malformed sequences
- Key round-trip (parse → format → parse)
- Modifier combinations (Ctrl+Shift+A, etc.)

### `session.zig` (~200 lines)
```zig
pub const Session = struct {
    id: u32,
    name: []const u8,
    windows: std.ArrayListUnmanaged(*Window),
    active_window: ?*Window,
    options: Options,
    // ...
};
```
**Tests** (5+): create, rename, attach/detach windows.

### `window.zig` (~300 lines)
```zig
pub const Window = struct {
    id: u32,
    name: []const u8,
    layout: Layout,
    panes: std.ArrayListUnmanaged(*Pane),
    active_pane: ?*Pane,
    // ...
};

pub const Pane = struct {
    id: u32,
    screen: Screen,
    // ...
};
```
**Tests** (10+): create, rename, add/remove panes.

### `layout.zig` (~400 lines)
Replaces `layout.c`, `layout-custom.c`, `layout-set.c`.

Binary tree of splits (same algorithm as tmux):
```zig
pub const Layout = struct {
    root: *Node,
};

pub const Node = union(enum) {
    leaf: *Pane,
    split: struct {
        direction: SplitDir,  // horizontal, vertical
        proportion: f64,
        a: *Node,
        b: *Node,
    },
};
```
**Tests** (15+):
- Create horizontal/vertical splits
- Even resize distributes space correctly
- Uneven resize preserves proportions
- Close pane → parent collapses
- Layout serialization (tiled, even-horizontal, even-vertical)

### Phase 2 Acceptance
```
$ zig build test
All 90 tests passed.
```

---

## Phase 3: Options + Config

**Goal**: Options storage and config file parser — pure data, no I/O.

### `options.zig` (~400 lines)
Replaces `options.c`, `options-table.c` (~1,900 lines of C).

Comptime-generated option definitions:
```zig
pub const OptionType = enum {
    number,
    string,
    colour,
    key,
    flag,
    choice,
};

pub const Option = struct {
    name: []const u8,
    type: OptionType,
    default: union {
        number: i64,
        string: []const u8,
        // ...
    },
};

pub const Options = struct {
    map: std.StringHashMap(OptionValue),
    // ...
};
```
**Tests** (15+): set, get, unset, default values, type validation.

### `cfg.zig` (~500 lines)
Replaces `cfg.c` (~600 lines of C).

Parse tmux-compatible config syntax:
- `set -g option value`
- `bind-key key command`
- `unbind-key key`
- `set-environment -g VAR value`
- `source-file path`
- `if-shell condition command`
- Comments (`#`) and line continuations

**Tests** (15+):
- Parse simple options
- Parse quoted strings
- Parse comments
- Error on unknown options
- Error on invalid values
- `#` comments at end of line

### Phase 3 Acceptance
```
$ zig build test
All 120 tests passed.
```

---

## Phase 4: TTY Output Engine

**Goal**: Write escape sequences to a real terminal. Testable by capturing
output to a buffer instead of a real FD.

### `tty.zig` (~600 lines)
Replaces `tty.c`, `tty-draw.c` (~3,500 lines of C).

```zig
pub const Term = struct {
    // Hardcoded escape sequences — no terminfo
    const caps = comptime blk: {
        // Validate all sequences at compile time
        break :blk std.ComptimeStringMap([]const u8, .{
            .{ "cuu1", "\x1b[A" },
            .{ "cud1", "\x1b[B" },
            .{ "cuf1", "\x1b[C" },
            .{ "cub1", "\x1b[D" },
            .{ "el",   "\x1b[K" },
            .{ "ed",   "\x1b[J" },
            .{ "smcup", "\x1b[?1049h" },
            .{ "rmcup", "\x1b[?1049l" },
            // ~40 entries total
        });
    };

    writer: std.io.AnyWriter,
    // ...
    
    pub fn writeEscape(self: *Term, name: []const u8) !void { ... }
    pub fn setCursor(self: *Term, x: u32, y: u32) !void { ... }
    pub fn setColour(self: *Term, fg: ?Colour, bg: ?Colour) !void { ... }
    pub fn clearScreen(self: *Term) !void { ... }
    pub fn writeCell(self: *Term, cell: Cell) !void { ... }
};
```

**Tests** (20+):
- Write to `std.io.ArrayListWriter`, verify output bytes
- Cursor movement produces correct CSI sequences
- RGB colour produces `\e[38;2;R;G;Bm`
- Indexed colour produces `\e[38;5;Nm`
- Screen diff — only emit changed cells
- Full redraw vs incremental redraw match

### Phase 4 Acceptance
```
$ zig build test
All 140 tests passed.
```

---

## Phase 5: TTY Input Parsing

**Goal**: Parse terminal input (key presses, mouse events) into Key events.

### `tty_key.zig` (~400 lines)
Replaces `tty-keys.c`, `input-keys.c` (~2,600 lines of C).

Only modern key sequences:
- CSI sequences (`\e[A` → up, `\e[1;5A` → Ctrl+Up)
- Kitty extended keys (`\e[97;5u` → Ctrl+Tab)
- SGR mouse (`\e[<0;40;25M` → mouse click at (40,25))

```zig
pub const Event = union(enum) {
    key: Key,
    mouse: MouseEvent,
    resize: struct { cols: u32, rows: u32 },
    focus_in: void,
    focus_out: void,
    paste: []const u8,
};

pub const MouseEvent = struct {
    button: MouseButton,
    action: MouseAction,  // press, release, drag
    col: u32,
    row: u32,
};

pub fn parse(bytes: []const u8) !?Event { ... }
```

**Tests** (20+):
- Parse arrow keys with modifiers
- Parse kitty key sequences
- Parse mouse press, release, drag
- Parse focus events
- Reject malformed sequences
- Multi-byte UTF-8 sequences passthrough

### Phase 5 Acceptance
```
$ zig build test
All 160 tests passed.
```

---

## Phase 6: Input Escape Sequence Parser

**Goal**: Parse escape sequences from child process output and update the grid.
This is the heart of terminal emulation.

### `input.zig` (~1,500 lines)
Replaces `input.c` (~3,600 lines of C).

Tagged union state machine:
```zig
const Parser = struct {
    state: State = .ground,
    
    const State = union(enum) {
        ground: void,
        esc: struct { intermediate: u8 = 0 },
        csi: struct {
            params: std.ArrayList(u8),
            intermediate: u8 = 0,
            final: u8 = 0,
        },
        osc: struct {
            cmd: u8 = 0,
            data: std.ArrayList(u8),
        },
        dcs: struct { ... },
        sos_pm_apc: void,
    };
    
    pub fn feed(self: *Parser, bytes: []const u8) !void { ... }
};
```

**What's dropped from C input.c:**
- G0/G1 charset selection (SCS)
- DECALN (screen alignment test)
- 1005 mouse parsing
- X10 mouse parsing
- non-SGR mouse parsing
- Keypad application mode (DECKPAM)

**Tests** (80+):
- Feed printable chars → cells on grid
- SGR sequences → cell attributes
- Cursor movement → cursor position
- Line wrapping
- Scroll regions
- Alt screen buffer
- OSC sequences (title, clipboard, hyperlinks, colour)
- Sixel passthrough (if enabled)
- Reset sequences
- DEC private modes (DECSET/DECRESET)
- Malformed sequences (error recovery)
- Each dropped feature explicitly tested as *not handled* (returns to ground)

### Phase 6 Acceptance
```
$ zig build test
All 240 tests passed.
```

---

## Phase 7: Format + Status

**Goal**: Template expansion and status bar rendering.

### `format.zig` (~500 lines)
Replaces `format.c`, `format-draw.c` (~7,500 lines of C).

```zig
pub fn expand(template: []const u8, ctx: *Context, allocator: Allocator) ![]const u8 {
    // Support tmux-compatible #{} syntax
    // #{session_name}, #{window_index}, #{pane_title}, etc.
    // #{?condition,true,false} ternary
}
```

Comptime parsing of format strings — validate at compile time where possible.

**Tests** (20+):
- Simple variable expansion
- Nested conditionals
- Format flags (for window/pane lists)
- Custom callbacks

### `status.zig` (~300 lines)
Replaces `status.c` (~1,800 lines of C).

```zig
pub const StatusBar = struct {
    left: []const u8,
    centre: []const u8,
    right: []const u8,
    bg: Colour,
    fg: Colour,
};
```

**Tests** (10+): rendering with sample configs.

### Phase 7 Acceptance
```
$ zig build test
All 270 tests passed.
```

---

## Phase 8: Mode + Key Bindings

**Goal**: Copy mode, tree mode, and key binding dispatch.

### `mode_copy.zig` (~1,000 lines)
Replaces `window-copy.c` (~6,000 lines of C).

Copy mode with vim and emacs keybindings:
- Vi mode: `hjkl` movement, `/` search, `v` visual select, `y` yank
- Emacs mode: arrow keys, `C-s` search, `C-space` select, `M-w` yank

**Tests** (30+):
- Movement commands
- Search forward/backward
- Text selection
- Yank/paste
- Vi and emacs keybindings

### `key_binding.zig` (~300 lines)
Replaces `key-bindings.c` (~500 lines of C).

Comptime-generated default key tables.

### Phase 8 Acceptance
```
$ zig build test
All 300 tests passed.
```

---

## Phase 9: Client-Server IPC

**Goal**: Multi-process architecture with socket communication.

### `proc.zig` (~400 lines)
Replaces `proc.c` (~700 lines of C).

```zig
pub const Message = packed struct {
    magic: u32 = 0x5A4D5558,  // "SZN"
    length: u32,
    type: MessageType,
    data: [4096]u8,
};

pub const MessageType = enum(u32) {
    identify,
    command,
    command_result,
    notify,
    // ...
};
```

### `server.zig` (~1,000 lines)
Replaces `server.c`, `server-fn.c`, `server-client.c` (~4,000 lines of C).

### `client.zig` (~500 lines)
Replaces `client.c` (~1,500 lines of C).

**Tests** (15+):
- Server starts, accepts connections
- Client connects, sends command, receives response
- Multiple clients
- Session attach/detach
- Window resize notification

### Phase 9 Acceptance
```
$ zig build test
All 330 tests passed.
```

---

## Phase 10: Commands

**Goal:** Command implementations with comptime dispatch.

### File layout
```
src/
  cmd/
    new_session.zig
    split_window.zig
    kill_pane.zig
    ...
  command.zig   — comptime dispatch table
```

### MVP commands (25 total)
```
Session:      new-session, kill-session, attach-session, detach-client,
              switch-client, rename-session
Window:       new-window, kill-window, rename-window, move-window,
              select-window, swap-window, rotate-window
Pane:         split-window, kill-pane, select-pane, resize-pane,
              swap-pane, join-pane, break-pane
Input:        send-keys, capture-pane, paste-buffer
Config:       bind-key, unbind-key, set-option, show-options, source-file
Navigation:   copy-mode, find-window
Misc:         show-messages, list-keys, list-commands
```

**Tests** (50+):
- Each command succeeds with valid args
- Each command fails with invalid args
- Command table is complete (no missing handlers)
- Help/usage output

### Phase 10 Acceptance
```
$ zig build test
All 450 tests passed.
```

---

## Phase 11: Full Integration

**Goal**: End-to-end tests against a real pseudo-terminal.

```zig
test "full session lifecycle" {
    const szn = try sznProcess.start(test_allocator, .{});
    defer szn.kill();

    _ = try szn.sendCommand("new-session -d -s test");
    _ = try szn.sendCommand("split-window -h");
    _ = try szn.sendCommand("select-pane -t 1");
    
    const output = try szn.sendCommand("list-panes -a -F '#{pane_id}'");
    try testing.expectEqualStrings("%0\n%1\n", output);
}
```

### Phase 11 Acceptance
```
$ zig build test
All 490 tests passed.
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                      main.zig                           │
│   parse args → fork → server or client                  │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│                   proc.zig (process)                     │
│              event loop (epoll/kqueue)                   │
└──┬────────┬──────────┬──────────┬──────────┬───────────┘
   │        │          │          │          │
   ▼        ▼          ▼          ▼          ▼
┌──────┐ ┌──────┐ ┌────────┐ ┌────────┐ ┌────────┐
│server│ │client│ │input.zig│ │tty.zig │ │grid.zig│
│ .zig │ │ .zig │ │escape  │ │output  │ │screen  │
│sess'n│ │conn  │ │parser  │ │+ term  │ │buffer  │
│ mgmt │ │ to   │ │for     │ │I/O     │ │+scroll │
│      │ │server│ │child   │ │        │ │back    │
└──────┘ └──────┘ └────────┘ └────────┘ └────────┘
                              │
                              ▼
                         ┌────────┐
                         │format  │
                         │ .zig   │
                         │strings │
                         └────────┘
```

## Reference Implementation Strategy

The `tmux/` directory tracks the upstream C source. Use it as follows:

- For **behaviour verification**: search tmux source for escape sequences
- For **edge cases**: tmux's input.c handles hundreds of obscure sequences;
  reference it to make sure we don't miss something important
- For **window manager layout**: the binary tree split algorithm is unchanged
- For **grid scrollback**: the buffer-winnowing logic is subtle

**Never** copy C patterns. When looking at tmux C code:

1. Understand what the code *does* (not how)
2. Design a Zig-native equivalent
3. Test against the same input/output as tmux

## Key Architectural Decisions

### No imsg
Simple packet protocol over Unix sockets:
```zig
const Packet = packed struct {
    magic: u32 = 0x5A4D5558,  // "SZN"
    length: u32,
    type: MessageType,
    data: [4096]u8,
};
```

### Arena allocators
- One arena per session
- One arena per pane (for grid data)
- One arena per command execution
- When a session is killed, free its arena — no individual frees needed

### Single poll loop
Use `std.os.poll` or epoll/kqueue wrapper. No libevent dependency.

### Comptime key bindings
Default key bindings generated and validated at compile time.

## How to Contribute

1. Read the tmux C source for the subsystem you want to port
2. Understand the behaviour (test with `tmux -L test ...`)
3. Design the Zig interface
4. Write the Zig implementation + tests
5. Run `zig build test` — all tests must pass
6. Open a PR

See AGENTS.md for coding conventions.
