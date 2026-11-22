#!/usr/bin/env bash
# szn vs tmux — resource usage benchmarks
set -eu

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
RESET='\033[0m'

SZN_BIN=./zig-out/bin/szn

# Use a short /tmp path so the Unix socket stays well below macOS's 104-byte
# sun_path limit, and isolate both szn and tmux sockets from any live user
# sessions (bug #567).
TMP_DIR=$(mktemp -d "/tmp/szn-bench.XXXXXX")
SZN_SOCK_DIR="$TMP_DIR/szn"
mkdir -p "$SZN_SOCK_DIR"
TMUX_SOCK="tmux-bench-$$"
TMUX_CMD="tmux -L $TMUX_SOCK -u"

TMP_STARTUP="$TMP_DIR/startup.json"
TMP_THROUGHPUT="$TMP_DIR/throughput.json"

ZIG=${ZIG:-"zig"}

# Detach from any outer multiplexer session and normalize SHELL so user shell
# rc/prompt scripts do not skew startup latency or RSS measurements (bug #567).
unset SZN SZN_PANE TMUX TMUX_PANE
export XDG_RUNTIME_DIR="$SZN_SOCK_DIR"
export SHELL="/bin/sh"

find_szn_pid() {
    if [[ -S "$SZN_SOCK_DIR/szn.sock" ]]; then
        lsof -t "$SZN_SOCK_DIR/szn.sock" 2>/dev/null | head -n 1 || true
    fi
}

cleanup_szn() {
    local pid
    pid=$(find_szn_pid)
    for _ in 1 2 3 4 5; do
        $SZN_BIN kill-session >/dev/null 2>&1 || break
    done
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.05
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$SZN_SOCK_DIR/szn.sock"
}

cleanup_procs() {
    cleanup_szn
    $TMUX_CMD kill-server >/dev/null 2>&1 || true
    sleep 0.1
}

cleanup_all() {
    cleanup_procs
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT

get_rss_kb() {
    local pid=$1
    local rss="0"
    if [[ -n "$pid" ]]; then
        if [[ "$(uname)" == Darwin ]]; then
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
        else
            rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
        fi
    fi
    echo "${rss:-0}"
}

print_rss() {
    local label=$1 rss=$2
    printf "  %-30s %s kB\n" "$label" "$rss"
}

header() {
    echo
    echo -e "${BOLD}${CYAN}━━━ $1 ━━━${RESET}"
}

# Build an identical 2×5 grid (10 panes) inside an 80×24 window for both szn
# and tmux; repeated vertical-only splits hit minimum pane height after 3–4
# splits and produced unequal pane counts (5 vs 4) (bug #567).
split_to_10_panes_szn() {
    $SZN_BIN split-window -v >/dev/null 2>&1
    for _ in 1 2 3 4; do
        $SZN_BIN split-window -h >/dev/null 2>&1
    done
    $SZN_BIN select-pane -U >/dev/null 2>&1
    for _ in 1 2 3 4; do
        $SZN_BIN split-window -h >/dev/null 2>&1
    done
}

split_to_10_panes_tmux() {
    $TMUX_CMD split-window -t bench -v >/dev/null 2>&1
    for _ in 1 2 3 4; do
        $TMUX_CMD split-window -t bench -h >/dev/null 2>&1
    done
    $TMUX_CMD select-pane -t bench -U >/dev/null 2>&1
    for _ in 1 2 3 4; do
        $TMUX_CMD split-window -t bench -h >/dev/null 2>&1
    done
}

# POSIX-sh prepare hooks scoped strictly to the isolated sockets. Unlinking
# szn.sock ensures every cold-start iteration benchmarks a fresh start rather
# than stale-socket ECONNREFUSED recovery (bug #567).
PREPARE_SZN="XDG_RUNTIME_DIR='$SZN_SOCK_DIR' $SZN_BIN kill-session >/dev/null 2>&1 || true; pid=\$(lsof -t '$SZN_SOCK_DIR/szn.sock' 2>/dev/null | head -n 1); if [ -n \"\$pid\" ]; then kill -TERM \"\$pid\" 2>/dev/null || true; sleep 0.05; kill -KILL \"\$pid\" 2>/dev/null || true; fi; rm -f '$SZN_SOCK_DIR/szn.sock'; sleep 0.1"
PREPARE_TMUX="$TMUX_CMD kill-server >/dev/null 2>&1 || true; sleep 0.1"

# ── build ──
echo -e "${DIM}building szn using ${ZIG}…${RESET}"
${ZIG} build -Doptimize=ReleaseFast 2>&1
cleanup_procs

# =========================================================================
header "1. Startup time (cold)"
# -------------------------------------------------------------------------
hyperfine --shell default --warmup 5 --min-runs 20 --export-json "$TMP_STARTUP" \
    --prepare "$PREPARE_SZN" \
    -n "szn new -d" \
    "$SZN_BIN new-session -d b >/dev/null 2>&1" \
    --prepare "$PREPARE_TMUX" \
    -n "tmux new -d" \
    "$TMUX_CMD new -d -s b >/dev/null 2>&1"

# =========================================================================
# Clean slate for memory tests
cleanup_procs
header "2. Memory: idle (1 session, 1 pane)"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
$SZN_BIN new-session -d bench >/dev/null 2>&1
sleep 0.5
SZN_PID=$(find_szn_pid)
MEM_1P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "1 session, 1 pane" "$MEM_1P_SZN"

echo -e "${CYAN}tmux${RESET}"
$TMUX_CMD new -d -s bench
sleep 0.5
TMUX_PID=$($TMUX_CMD display -p '#{pid}' 2>/dev/null)
MEM_1P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "1 session, 1 pane" "$MEM_1P_TMUX"

# =========================================================================
header "3. Memory: 10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
split_to_10_panes_szn
sleep 0.5
MEM_10P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "1 window, 10 panes" "$MEM_10P_SZN"

echo -e "${CYAN}tmux${RESET}"
split_to_10_panes_tmux
sleep 0.5
MEM_10P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "1 window, 10 panes" "$MEM_10P_TMUX"

# =========================================================================
header "4. Memory: 5 windows × 10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
for i in $(seq 2 5); do
    $SZN_BIN new-window "win$i" >/dev/null 2>&1
    split_to_10_panes_szn
done
sleep 0.5
MEM_50P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "5 windows, 50 panes" "$MEM_50P_SZN"

echo -e "${CYAN}tmux${RESET}"
for i in $(seq 2 5); do
    $TMUX_CMD new-window -t bench -n "win$i" >/dev/null 2>&1
    split_to_10_panes_tmux
done
sleep 0.5
MEM_50P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "5 windows, 50 panes" "$MEM_50P_TMUX"

# =========================================================================
cleanup_procs
header "5. Session create/destroy throughput"
# -------------------------------------------------------------------------
hyperfine --shell default --warmup 5 --min-runs 20 --export-json "$TMP_THROUGHPUT" \
    --prepare "$PREPARE_SZN" \
    -n "szn new + kill" \
    "$SZN_BIN new-session -d b >/dev/null 2>&1 && $SZN_BIN kill-session >/dev/null 2>&1" \
    --prepare "$PREPARE_TMUX" \
    -n "tmux new + kill" \
    "$TMUX_CMD new -d -s b >/dev/null 2>&1 && $TMUX_CMD kill-session -t b >/dev/null 2>&1"

# =========================================================================
cleanup_procs
header "Summary"
# -------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPORT_SCRIPT="$SCRIPT_DIR/tools/bench_report.py"

if command -v python3 >/dev/null 2>&1 && [[ -f "$REPORT_SCRIPT" ]]; then
    python3 "$REPORT_SCRIPT" \
        --startup "$TMP_STARTUP" \
        --throughput "$TMP_THROUGHPUT" \
        --mem-1p-szn "$MEM_1P_SZN" \
        --mem-1p-tmux "$MEM_1P_TMUX" \
        --mem-10p-szn "$MEM_10P_SZN" \
        --mem-10p-tmux "$MEM_10P_TMUX" \
        --mem-50p-szn "$MEM_50P_SZN" \
        --mem-50p-tmux "$MEM_50P_TMUX"
else
    echo "Benchmark                          | szn        | tmux"
    echo "-----------------------------------+------------+------------"
    printf "%-34s | %-10s | %-10s\n" "Memory: idle (1 session, 1 pane)" "${MEM_1P_SZN} kB" "${MEM_1P_TMUX} kB"
    printf "%-34s | %-10s | %-10s\n" "Memory: 1 window, 10 panes" "${MEM_10P_SZN} kB" "${MEM_10P_TMUX} kB"
    printf "%-34s | %-10s | %-10s\n" "Memory: 5 windows, 50 panes" "${MEM_50P_SZN} kB" "${MEM_50P_TMUX} kB"
fi

echo
echo -e "${BOLD}${GREEN}✓ done${RESET}"
