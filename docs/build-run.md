---
type: runbook
title: "szn Build, Run, and Test"
description: "How to build, run, test, and benchmark szn, plus prerequisites and dependencies."
status: stable
sources:
  - build.zig
  - build.zig.zon
  - src/main.zig
  - src/test.zig
verified: human-reviewed
stale_after: 2027-01-01T00:00:00Z
tags: [runbook, build, test, benchmark, zig]
timestamp: 2026-10-30T07:40:00Z
---

# Build, Run, and Test

## Prerequisites

- **Zig 0.16.0 or Zig 0.17.0** — the source compiles on both (see
  [Zig version compatibility](https://github.com/cwt/szn/blob/main/README.md#zig-version-compatibility)).
  There is no `.zig-version` pin and `build.zig.zon` has no
  `minimum_zig_version`, so either 0.16.x or 0.17.x works.
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
tests live next to the code they cover. As of 2026-10-30 the suite is
**1082 tests**, all passing on a clean tree under both Zig 0.16.0 and 0.17.0
(`-Doptimize=ReleaseFast`, fresh cache).

```bash
zig build test
```

To check both toolchains from one tree, give each its own cache directory:

```bash
rm -rf .cache .zig-cache
zig build test -Doptimize=ReleaseFast --summary all --cache-dir .cache/bt16                 # 0.16.0
/opt/zig/0.17.0/zig build test -Doptimize=ReleaseFast --summary all --cache-dir .cache/bt17 # 0.17.0
```

Notes:
- No custom test harness or timeout overrides in `build.zig`. The Zig test
  runner **randomises execution order** unless `--seed` is passed.
- `test "detectNested ..."` self-skips when run inside szn
  (`error.SkipZigTest` if `SZN` is set).
- Some integration tests spawn real PTYs / `fork` (e.g. `integration.zig`) —
  run on a terminal-capable host.

### Allocator differences between 0.16 and 0.17

`std.testing.allocator` is a `DebugAllocator` on 0.16.0 but a `SafeAllocator`
on 0.17.0. The test runner configures it with `check_write_after_free = true`
on `page_allocator`. `SafeAllocator` never reuses memory and returns freed
pages to the OS. So a test that reads a pointer after freeing it can pass on
0.16, where the stale bytes are still mapped, and **crash with SIGSEGV on
0.17**. Bug [#562](development/bugs/562.md) was exactly this. If a test passes
on 0.16 but crashes on 0.17, look for a use-after-free first.

### Socket tests

Older revisions left `szn.sock` behind after `zig build test`, and the next run
then failed three socket tests. That no longer happens. The tests clean up the
default socket path, and as of 2026-10-30 the suite also passes when a stale
socket is already there before the run.

## Dev script: `bench.sh`

`bench.sh` builds `szn` with `ReleaseFast` and benchmarks startup time and
create/destroy throughput (and RSS memory) against `tmux -u` using
`hyperfine`. Requires `hyperfine` and `tmux` on `PATH`. It does **not**
correspond to a `zig build bench` step.

## Dependencies

**None** beyond libc. `build.zig.zon` declares no `.dependencies`; everything
is in-tree under `src/`.
