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

cleanup() {
    $SZN kill-session 2>/dev/null || true
    kill -9 $(pidof szn) 2>/dev/null || true
    $TMUX kill-server 2>/dev/null || true
    sleep 0.2
}
trap cleanup EXIT

rss_kb() {
    local pid=$1 label=$2
    local rss
    rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo "N/A")
    printf "  %-30s %s kB\n" "$label" "$rss"
}

header() {
    echo
    echo -e "${BOLD}${CYAN}━━━ $1 ━━━${RESET}"
}

prepare_tmux() { "$TMUX kill-server 2>/dev/null; sleep 0.3"; }
prepare_szn()  { "kill -9 \$(pidof szn) 2>/dev/null || true; sleep 0.3"; }

# ── build ──
echo -e "${DIM}building szn …${RESET}"
zig build -Doptimize=ReleaseFast 2>&1
cleanup

# =========================================================================
header "1. Startup time — tmux"
# -------------------------------------------------------------------------
hyperfine --warmup 5 --min-runs 20 \
    --prepare "$TMUX kill-server 2>/dev/null; sleep 0.3" \
    -n "tmux new -d" \
    "$TMUX new -d -s b 2>/dev/null && $TMUX kill-session -t b"

# =========================================================================
header "2. Startup time — szn"
# -------------------------------------------------------------------------
hyperfine --warmup 5 --min-runs 20 \
    --prepare "kill -9 \$(pidof szn) 2>/dev/null || true; sleep 0.3" \
    -n "szn new -d" \
    "$SZN new-session -d b 2>/dev/null && $SZN kill-session"

# =========================================================================
header "3. Memory: idle (1 session, 1 pane)"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
$SZN new-session -d bench
SZN_PID=$(pgrep -x szn || echo "")
sleep 0.5
rss_kb $SZN_PID "1 session, 1 pane"

echo -e "${CYAN}tmux${RESET}"
$TMUX new -d -s bench
TMUX_PID=$($TMUX display -p '#{pid}' 2>/dev/null)
rss_kb $TMUX_PID "1 session, 1 pane"

# =========================================================================
header "4. Memory: 10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
for _ in $(seq 1 9); do
    $SZN split-window -v 2>/dev/null || break
done
sleep 0.5
rss_kb $SZN_PID "1 window, 10 panes"

echo -e "${CYAN}tmux${RESET}"
for _ in $(seq 1 9); do
    $TMUX split-window -t bench 2>/dev/null || break
done
sleep 0.5
rss_kb $TMUX_PID "1 window, 10 panes"

# =========================================================================
header "5. Memory: 5 windows × ~10 panes"
# -------------------------------------------------------------------------
echo -e "${CYAN}szn${RESET}"
for i in $(seq 2 5); do
    $SZN new-window "win$i" 2>/dev/null || true
    for _ in $(seq 1 9); do
        $SZN split-window -v 2>/dev/null || break
    done
done
sleep 0.5
rss_kb $SZN_PID "5 windows, ~50 panes"

echo -e "${CYAN}tmux${RESET}"
for i in $(seq 2 5); do
    $TMUX new-window -t bench -n "win$i" 2>/dev/null || true
    for _ in $(seq 1 9); do
        $TMUX split-window -t bench 2>/dev/null || break
    done
done
sleep 0.5
rss_kb $TMUX_PID "5 windows, ~50 panes"

# =========================================================================
header "6. Session create/destroy throughput"
# -------------------------------------------------------------------------
cleanup

hyperfine --warmup 5 --min-runs 20 \
    --prepare "$TMUX kill-server 2>/dev/null; sleep 0.3" \
    -n "tmux new + kill" \
    "$TMUX new -d -s b 2>/dev/null && $TMUX kill-session -t b"

hyperfine --warmup 5 --min-runs 20 \
    --prepare "kill -9 \$(pidof szn) 2>/dev/null || true; sleep 0.3" \
    -n "szn new + kill" \
    "$SZN new-session -d b 2>/dev/null && $SZN kill-session"

# =========================================================================
cleanup
echo
echo -e "${BOLD}${GREEN}✓ done${RESET}"
