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
hyperfine -S --warmup 5 --min-runs 20 --export-json "$TMP_STARTUP" \
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
hyperfine -S --warmup 5 --min-runs 20 --export-json "$TMP_THROUGHPUT" \
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
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMP_STARTUP" "$TMP_THROUGHPUT" "$MEM_1P_SZN" "$MEM_1P_TMUX" "$MEM_10P_SZN" "$MEM_10P_TMUX" "$MEM_50P_SZN" "$MEM_50P_TMUX" << 'EOF'
import sys, json

use_color = sys.stdout.isatty()
GREEN = "\033[32m" if use_color else ""
CYAN = "\033[36m" if use_color else ""
BOLD = "\033[1m" if use_color else ""
DIM = "\033[2m" if use_color else ""
YELLOW = "\033[33m" if use_color else ""
RESET = "\033[0m" if use_color else ""

def cell(text, width, color=""):
    pad = " " * max(0, width - len(text))
    if color:
        return f"{color}{text}{RESET}{pad}"
    return f"{text}{pad}"

def load_timing(path):
    try:
        with open(path) as f:
            d = json.load(f)
        def get_mean(r):
            if "mean" in r and r["mean"] is not None:
                return r["mean"]
            summary = r.get("summary", {})
            metric = d.get("primary_metric", "time_wall_clock")
            if metric in summary and summary[metric] and "mean" in summary[metric]:
                return summary[metric]["mean"]
            if "time_wall_clock" in summary and summary["time_wall_clock"] and "mean" in summary["time_wall_clock"]:
                return summary["time_wall_clock"]["mean"]
            return 0
        szn_ms = None
        tmux_ms = None
        for r in d.get("results", []):
            cmd = r.get("command", "")
            mean_sec = get_mean(r)
            if "szn" in cmd:
                szn_ms = mean_sec * 1000.0
            elif "tmux" in cmd:
                tmux_ms = mean_sec * 1000.0
        if szn_ms is None and len(d.get("results", [])) > 0:
            szn_ms = get_mean(d["results"][0]) * 1000.0
        if tmux_ms is None and len(d.get("results", [])) > 1:
            tmux_ms = get_mean(d["results"][1]) * 1000.0
        return szn_ms, tmux_ms
    except Exception:
        return None, None

def format_timing(szn_ms, tmux_ms):
    if szn_ms is None or tmux_ms is None:
        return "N/A", "N/A", "N/A", ""
    szn_str = f"{szn_ms:.2f} ms"
    tmux_str = f"{tmux_ms:.2f} ms"
    if szn_ms <= 0 or tmux_ms <= 0:
        return szn_str, tmux_str, "-", ""
    if szn_ms < tmux_ms:
        ratio = tmux_ms / szn_ms
        comp = f"{ratio:.2f}× faster"
        color = GREEN
    elif szn_ms > tmux_ms:
        ratio = szn_ms / tmux_ms
        comp = f"{ratio:.2f}× slower"
        color = YELLOW
    else:
        comp = "equal"
        color = DIM
    return szn_str, tmux_str, comp, color

def format_memory(szn_val, tmux_val):
    try:
        szn_kb = float(szn_val)
        tmux_kb = float(tmux_val)
    except (ValueError, TypeError):
        return f"{szn_val} kB", f"{tmux_val} kB", "N/A", ""

    if szn_kb <= 0 or tmux_kb <= 0:
        return f"{int(szn_kb)} kB", f"{int(tmux_kb)} kB", "N/A", ""

    szn_str = f"{int(szn_kb)} kB"
    tmux_str = f"{int(tmux_kb)} kB"
    pct = ((szn_kb - tmux_kb) / tmux_kb) * 100.0
    if pct < 0:
        comp = f"{pct:.1f}%"
        color = GREEN
    elif pct > 0:
        comp = f"+{pct:.1f}%"
        color = YELLOW
    else:
        comp = "equal"
        color = DIM
    return szn_str, tmux_str, comp, color

startup_szn, startup_tmux = load_timing(sys.argv[1])
through_szn, through_tmux = load_timing(sys.argv[2])

rows = [
    ("Startup time (cold)", *format_timing(startup_szn, startup_tmux)),
    ("Memory: idle (1 session, 1 pane)", *format_memory(sys.argv[3], sys.argv[4])),
    ("Memory: 1 window, 10 panes", *format_memory(sys.argv[5], sys.argv[6])),
    ("Memory: 5 windows, ~50 panes", *format_memory(sys.argv[7], sys.argv[8])),
    ("Session create/destroy throughput", *format_timing(through_szn, through_tmux)),
]

w1, w2, w3, w4 = 34, 10, 10, 13
bar = "─"
top = f"┌{bar * (w1 + 2)}┬{bar * (w2 + 2)}┬{bar * (w3 + 2)}┬{bar * (w4 + 2)}┐"
mid = f"├{bar * (w1 + 2)}┼{bar * (w2 + 2)}┼{bar * (w3 + 2)}┼{bar * (w4 + 2)}┤"
bot = f"└{bar * (w1 + 2)}┴{bar * (w2 + 2)}┴{bar * (w3 + 2)}┴{bar * (w4 + 2)}┘"

print(top)
print(f"│ {cell('Benchmark', w1, BOLD)} │ {cell('szn', w2, BOLD + CYAN)} │ {cell('tmux', w3, BOLD)} │ {cell('Comparison', w4, BOLD)} │")
print(mid)
for name, szn, tmux, comp, comp_color in rows:
    print(f"│ {cell(name, w1)} │ {cell(szn, w2, CYAN)} │ {cell(tmux, w3)} │ {cell(comp, w4, comp_color)} │")
print(bot)
EOF
else
    echo "Benchmark                          | szn        | tmux"
    echo "-----------------------------------+------------+------------"
    printf "%-34s | %-10s | %-10s\n" "Memory: idle (1 session, 1 pane)" "${MEM_1P_SZN} kB" "${MEM_1P_TMUX} kB"
    printf "%-34s | %-10s | %-10s\n" "Memory: 1 window, 10 panes" "${MEM_10P_SZN} kB" "${MEM_10P_TMUX} kB"
    printf "%-34s | %-10s | %-10s\n" "Memory: 5 windows, ~50 panes" "${MEM_50P_SZN} kB" "${MEM_50P_TMUX} kB"
fi

echo
echo -e "${BOLD}${GREEN}✓ done${RESET}"

