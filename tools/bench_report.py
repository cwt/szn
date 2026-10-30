#!/usr/bin/env python3
"""Benchmark report generator for szn vs tmux.

Parses hyperfine JSON exports and memory RSS figures, computes comparisons,
and renders a formatted Unicode comparison table.
"""

import argparse
import json
import os
import sys
from typing import Any


def get_color_map(use_color: bool) -> dict[str, str]:
    if not use_color:
        return {
            "green": "",
            "cyan": "",
            "bold": "",
            "dim": "",
            "yellow": "",
            "reset": "",
        }
    return {
        "green": "\033[32m",
        "cyan": "\033[36m",
        "bold": "\033[1m",
        "dim": "\033[2m",
        "yellow": "\033[33m",
        "reset": "\033[0m",
    }


def format_cell(text: str, width: int, color: str = "", reset: str = "") -> str:
    pad = " " * max(0, width - len(text))
    if color:
        return f"{color}{text}{reset}{pad}"
    return f"{text}{pad}"


def extract_mean_seconds(result: dict[str, Any], data: dict[str, Any]) -> float:
    if "mean" in result and result["mean"] is not None:
        return float(result["mean"])

    summary = result.get("summary", {})
    metric = data.get("primary_metric", "time_wall_clock")
    if metric in summary and summary[metric] and "mean" in summary[metric]:
        return float(summary[metric]["mean"])

    if "time_wall_clock" in summary and summary["time_wall_clock"] and "mean" in summary["time_wall_clock"]:
        return float(summary["time_wall_clock"]["mean"])

    return 0.0


def load_timing(path: str | None) -> tuple[float | None, float | None]:
    if not path or not os.path.isfile(path):
        return None, None

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        results = data.get("results", [])
        szn_ms = None
        tmux_ms = None

        for result in results:
            cmd = result.get("command", "")
            mean_sec = extract_mean_seconds(result, data)
            if "szn" in cmd:
                szn_ms = mean_sec * 1000.0
            elif "tmux" in cmd:
                tmux_ms = mean_sec * 1000.0

        if szn_ms is None and len(results) > 0:
            szn_ms = extract_mean_seconds(results[0], data) * 1000.0
        if tmux_ms is None and len(results) > 1:
            tmux_ms = extract_mean_seconds(results[1], data) * 1000.0

        return szn_ms, tmux_ms
    except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError, IndexError):
        return None, None


def format_timing(
    szn_ms: float | None, tmux_ms: float | None, colors: dict[str, str]
) -> tuple[str, str, str, str]:
    if szn_ms is None or tmux_ms is None:
        return "N/A", "N/A", "N/A", ""

    szn_str = f"{szn_ms:.2f} ms"
    tmux_str = f"{tmux_ms:.2f} ms"

    if szn_ms <= 0 or tmux_ms <= 0:
        return szn_str, tmux_str, "-", ""

    if szn_ms < tmux_ms:
        ratio = tmux_ms / szn_ms
        comp = f"{ratio:.2f}× faster"
        color = colors["green"]
    elif szn_ms > tmux_ms:
        ratio = szn_ms / tmux_ms
        comp = f"{ratio:.2f}× slower"
        color = colors["yellow"]
    else:
        comp = "equal"
        color = colors["dim"]

    return szn_str, tmux_str, comp, color


def format_memory(
    szn_val: str | None, tmux_val: str | None, colors: dict[str, str]
) -> tuple[str, str, str, str]:
    if not szn_val or not tmux_val:
        return f"{szn_val or 'N/A'} kB", f"{tmux_val or 'N/A'} kB", "N/A", ""

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
        color = colors["green"]
    elif pct > 0:
        comp = f"+{pct:.1f}%"
        color = colors["yellow"]
    else:
        comp = "equal"
        color = colors["dim"]

    return szn_str, tmux_str, comp, color


def render_table(rows: list[tuple[str, str, str, str, str]], colors: dict[str, str]) -> None:
    w1, w2, w3, w4 = 34, 10, 10, 13
    bar = "─"
    top = f"┌{bar * (w1 + 2)}┬{bar * (w2 + 2)}┬{bar * (w3 + 2)}┬{bar * (w4 + 2)}┐"
    mid = f"├{bar * (w1 + 2)}┼{bar * (w2 + 2)}┼{bar * (w3 + 2)}┼{bar * (w4 + 2)}┤"
    bot = f"└{bar * (w1 + 2)}┴{bar * (w2 + 2)}┴{bar * (w3 + 2)}┴{bar * (w4 + 2)}┘"

    bold = colors["bold"]
    cyan = colors["cyan"]
    reset = colors["reset"]

    print(top)
    print(
        f"│ {format_cell('Benchmark', w1, bold, reset)} │ "
        f"{format_cell('szn', w2, bold + cyan, reset)} │ "
        f"{format_cell('tmux', w3, bold, reset)} │ "
        f"{format_cell('Comparison', w4, bold, reset)} │"
    )
    print(mid)
    for name, szn, tmux, comp, comp_color in rows:
        print(
            f"│ {format_cell(name, w1, reset=reset)} │ "
            f"{format_cell(szn, w2, cyan, reset)} │ "
            f"{format_cell(tmux, w3, reset=reset)} │ "
            f"{format_cell(comp, w4, comp_color, reset)} │"
        )
    print(bot)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Format and display szn vs tmux benchmark results."
    )
    parser.add_argument(
        "--startup",
        help="Path to hyperfine startup JSON export file",
        default=None,
    )
    parser.add_argument(
        "--throughput",
        help="Path to hyperfine throughput JSON export file",
        default=None,
    )
    parser.add_argument(
        "--mem-1p-szn",
        help="szn RSS in kB for 1 session, 1 pane",
        default="",
    )
    parser.add_argument(
        "--mem-1p-tmux",
        help="tmux RSS in kB for 1 session, 1 pane",
        default="",
    )
    parser.add_argument(
        "--mem-10p-szn",
        help="szn RSS in kB for 1 window, 10 panes",
        default="",
    )
    parser.add_argument(
        "--mem-10p-tmux",
        help="tmux RSS in kB for 1 window, 10 panes",
        default="",
    )
    parser.add_argument(
        "--mem-50p-szn",
        help="szn RSS in kB for 5 windows, ~50 panes",
        default="",
    )
    parser.add_argument(
        "--mem-50p-tmux",
        help="tmux RSS in kB for 5 windows, ~50 panes",
        default="",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI colors",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()

    use_color = (not args.no_color) and sys.stdout.isatty()
    colors = get_color_map(use_color)

    startup_szn, startup_tmux = load_timing(args.startup)
    through_szn, through_tmux = load_timing(args.throughput)

    rows = [
        (
            "Startup time (cold)",
            *format_timing(startup_szn, startup_tmux, colors),
        ),
        (
            "Memory: idle (1 session, 1 pane)",
            *format_memory(args.mem_1p_szn, args.mem_1p_tmux, colors),
        ),
        (
            "Memory: 1 window, 10 panes",
            *format_memory(args.mem_10p_szn, args.mem_10p_tmux, colors),
        ),
        (
            "Memory: 5 windows, ~50 panes",
            *format_memory(args.mem_50p_szn, args.mem_50p_tmux, colors),
        ),
        (
            "Session create/destroy throughput",
            *format_timing(through_szn, through_tmux, colors),
        ),
    ]

    render_table(rows, colors)


if __name__ == "__main__":
    main()
