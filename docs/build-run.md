---
type: runbook
title: "szn Build, Run, and Test"
description: "How to build, run, test, and benchmark szn, plus prerequisites and dependencies."
timestamp: 2026-08-30T16:20:00Z
---

# Build, Run, and Test

## Prerequisites

- **Zig 0.16.0** (documented target; no `.zig-version` pin and
  `build.zig.zon` has no `minimum_zig_version`, so a 0.16.x toolchain is the
  safe bet).
- **libc** required — both the executable module and the test module set
  `link_libc = true`. Uses `fork`/`setsid`/`ioctl`/`tcsetattr` etc.
- **OS**: macOS and Linux both supported.

## Build

```bash
zig build                                    # -> zig-out/bin/szn (Debug)
zig build -Doptimize=ReleaseFast --prefix ~/.local   # -> ~/.local/bin/szn
zig build run                                 # build + run
zig build test                                # run the test binary
```

Build options are the standard Zig flags (`b.standardTargetOptions` and
`b.standardOptimizeOption`): `-Dtarget=<triple>` (default host) and
`-Doptimize=<Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>` (default Debug).

Release behaviour: for **non-Darwin + non-Debug**, `lto = .thin` and
`use_lld = true` are applied to both the executable and the test binary, and
the executable is stripped. macOS release builds **skip** thin-LTO/lld
(guarded by `!is_darwin`).

## Run

`szn` is both client and server. With no socket it auto-spawns the daemon
(creates a `default` session at 80×23 and runs `$SHELL`); otherwise it attaches.

| Command | Purpose |
|---------|---------|
| `szn` | Start default session (auto daemon) + attach |
| `szn new -d <name>` | Create a detached session |
| `szn attach` | Attach to running session |
| `szn split-window -v` / `-h` | Split pane vertically / horizontally |
| `szn new-window [name]` | New window |
| `szn list-sessions` (`ls`) | List sessions |
| `szn kill-session [name]` | Kill session |
| `szn send-keys <keys>` | Send keystrokes to active pane |
| `szn resize-pane -L/-R/-U/-D` | Resize pane |
| `szn set-option -g/-w <k> <v>` | Set session/window option |
| `szn source-file ~/.szn.conf` | Load config |
| `szn help [cmd]` | Help |

Config lives at `~/.szn.conf` (tmux-style). Debug logging is off by default;
enable with `set -g server-log-file default` → `$XDG_STATE_HOME/szn/szn.log`
(`log-file` is still accepted as an alias). The client logs separately via
`client-log-file`.

Nested szn is blocked (env `SZN` set → `detectNested` returns true).

## Test

`src/test.zig` is a **comptime aggregator** that `@import`s every module so
their top-level `test {}` blocks compile into one test binary (see the
`b.addTest` call in `build.zig`). There is no separate `tests/` directory —
tests live next to the code they cover. As of 2026-08-30 the suite is
**944 tests**, all passing on a clean tree.

```bash
zig build test
```

Notes:
- No custom test harness or timeout overrides in `build.zig`. The Zig test
  runner **randomises execution order** unless `--seed` is passed.
- `test "detectNested ..."` self-skips when run inside szn
  (`error.SkipZigTest` if `SZN` is set).
- Some integration tests spawn real PTYs / `fork` (e.g. `integration.zig`) —
  run on a terminal-capable host.

### Stale socket makes 3 tests fail

`zig build test` binds a listener at the default socket path
(`$TMPDIR/szn.sock`, resolved by `socket_path.resolve`) and does **not**
remove it afterwards. On the next run, three tests that share that global
path then interfere with each other and report 941/944:

```
server.server.test.server listen creates socket
server.socket.test.listener creates and closes
client.connect.test.connectToServer fails gracefully when no server running
```

Remove the leftover socket before testing for a clean 944/944:

```bash
rm -f "$TMPDIR/szn.sock" && zig build test
```

The underlying cause is that these tests share one global path instead of
each using a unique one, so they also race against each other when the
runner schedules them concurrently.

## Dev script: `bench.sh`

`bench.sh` builds `szn` with `ReleaseFast` and benchmarks startup time and
create/destroy throughput (and RSS memory) against `tmux -u` using
`hyperfine`. Requires `hyperfine` and `tmux` on `PATH`. It does **not**
correspond to a `zig build bench` step.

## Dependencies

**None** beyond libc. `build.zig.zon` declares no `.dependencies`; everything
is in-tree under `src/`.
