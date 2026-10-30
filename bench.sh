#!/usr/bin/env bash
# szn vs tmux — resource usage benchmarks
set -eu

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
RESET='\033[0m'

SZN=./zig-out/bin/szn
TMUX="tmux -u"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/szn-bench.XXXXXX" 2>/dev/null || mktemp -d)
TMP_STARTUP="$TMP_DIR/startup.json"
TMP_THROUGHPUT="$TMP_DIR/throughput.json"

ZIG=${ZIG:-"zig"}

cleanup_procs() {
    $SZN kill-session 2>/dev/null || true
    pkill -9 szn 2>/dev/null || true
    $TMUX kill-server 2>/dev/null || true
    sleep 0.2
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

PREPARE_SZN="pkill -9 szn 2>/dev/null || true; sleep 0.3"
PREPARE_TMUX="$TMUX kill-server 2>/dev/null || true; sleep 0.3"

# ── build ──
echo -e "${DIM}building szn uzing ${ZIG}…${RESET}"
${ZIG} build -Doptimize=ReleaseFast 2>&1
cleanup_procs

# =========================================================================
header "1. Startup time (cold)"
# -------------------------------------------------------------------------
hyperfine --shell default --warmup 5 --min-runs 20 --export-json "$TMP_STARTUP" \
    --prepare "$PREPARE_SZN" \
    -n "szn new -d" \
    "$SZN new-session -d b 2>/dev/null" \
    --prepare "$PREPARE_TMUX" \
    -n "tmux new -d" \
    "$TMUX new -d -s b 2>/dev/null"

# =========================================================================
# Clean slate for memory tests
cleanup_procs
header "2. Memory: idle (1 session, 1 pane)"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
$SZN new-session -d bench
sleep 0.5
SZN_PID=$(pgrep -x -n szn || echo "")
MEM_1P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "1 session, 1 pane" "$MEM_1P_SZN"

echo -e "${CYAN}tmux${RESET}"
$TMUX new -d -s bench
TMUX_PID=$($TMUX display -p '#{pid}' 2>/dev/null)
MEM_1P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "1 session, 1 pane" "$MEM_1P_TMUX"

# =========================================================================
header "3. Memory: 10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
for _ in $(seq 1 9); do
    $SZN split-window -v 2>/dev/null || break
done
sleep 0.5
MEM_10P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "1 window, 10 panes" "$MEM_10P_SZN"

echo -e "${CYAN}tmux${RESET}"
for _ in $(seq 1 9); do
    $TMUX split-window -t bench 2>/dev/null || break
done
sleep 0.5
MEM_10P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "1 window, 10 panes" "$MEM_10P_TMUX"

# =========================================================================
header "4. Memory: 5 windows × ~10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
for i in $(seq 2 5); do
    $SZN new-window "win$i" 2>/dev/null || true
    for _ in $(seq 1 9); do
        $SZN split-window -v 2>/dev/null || break
    done
done
sleep 0.5
MEM_50P_SZN=$(get_rss_kb "$SZN_PID")
print_rss "5 windows, ~50 panes" "$MEM_50P_SZN"

echo -e "${CYAN}tmux${RESET}"
for i in $(seq 2 5); do
    $TMUX new-window -t bench -n "win$i" 2>/dev/null || true
    for _ in $(seq 1 9); do
        $TMUX split-window -t bench 2>/dev/null || break
    done
done
sleep 0.5
MEM_50P_TMUX=$(get_rss_kb "$TMUX_PID")
print_rss "5 windows, ~50 panes" "$MEM_50P_TMUX"

# =========================================================================
cleanup_procs
header "5. Session create/destroy throughput"
# -------------------------------------------------------------------------
hyperfine --shell default --warmup 5 --min-runs 20 --export-json "$TMP_THROUGHPUT" \
    --prepare "$PREPARE_SZN" \
    -n "szn new + kill" \
    "$SZN new-session -d b 2>/dev/null && $SZN kill-session" \
    --prepare "$PREPARE_TMUX" \
    -n "tmux new + kill" \
    "$TMUX new -d -s b 2>/dev/null && $TMUX kill-session -t b"

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
    printf "%-34s | %-10s | %-10s\n" "Memory: 5 windows, ~50 panes" "${MEM_50P_SZN} kB" "${MEM_50P_TMUX} kB"
fi

echo
echo -e "${BOLD}${GREEN}✓ done${RESET}"

