#!/usr/bin/env python3
"""Compare szn algorithmic benchmark JSON reports (Layer 1 & Layer 2).

Supports:
  1. A/B diff mode: bench_compare.py baseline.json candidate.json
     Computes median speedup ratios, IQR overlap test, scaling exponent (alpha)
     deltas, and deterministic allocation / memmove / row-skip deltas.
  2. Single-run summary / baseline gate verification:
     bench_compare.py --summary baseline.json [--check-baseline]
"""

import argparse
import json
import sys
from typing import Any


def fmt_duration_ns(ns: float) -> str:
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.3f} s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.3f} ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.2f} µs"
    return f"{ns:.1f} ns"


def fmt_bytes(b: int) -> str:
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024 ** 3):.2f} GiB"
    if b >= 1024 * 1024:
        return f"{b / (1024 ** 2):.2f} MiB"
    if b >= 1024:
        return f"{b / 1024:.1f} KiB"
    return f"{b} B"


def fmt_param(param: int, unit: str) -> str:
    if unit == "bytes" and param >= 1024 * 1024 and param % (1024 * 1024) == 0:
        return f"{param // (1024 * 1024)} MiB"
    if unit == "bytes" and param >= 1024 and param % 1024 == 0:
        return f"{param // 1024} KiB"
    if param >= 1_000_000 and param % 1_000_000 == 0:
        return f"{param // 1_000_000}M"
    if param >= 1024 and param % 1024 == 0 and unit in ("cells",):
        return f"{param // 1024}k"
    return str(param)


def iqr_overlap(base: dict[str, Any], cand: dict[str, Any]) -> bool:
    return not (cand["p75_ns"] < base["p25_ns"] or base["p75_ns"] < cand["p25_ns"])


def compute_scaling_map(data: dict[str, Any]) -> dict[tuple[str, int, int], float]:
    out: dict[tuple[str, int, int], float] = {}
    for entry in data.get("scaling", []):
        key = (entry["id"], int(entry["from_param"]), int(entry["to_param"]))
        out[key] = float(entry["alpha"])
    return out


def compute_top_alpha(data: dict[str, Any]) -> dict[str, tuple[int, int, float]]:
    """Return the largest-N adjacent scaling exponent per case id."""
    top: dict[str, tuple[int, int, float]] = {}
    for entry in data.get("scaling", []):
        cid = entry["id"]
        fp = int(entry["from_param"])
        tp = int(entry["to_param"])
        alpha = float(entry["alpha"])
        if cid not in top or tp > top[cid][1]:
            top[cid] = (fp, tp, alpha)
    return top


def print_metadata(label: str, meta: dict[str, Any]) -> None:
    print(
        f"{label}: szn={meta.get('szn_version')} zig={meta.get('zig_version')} "
        f"opt={meta.get('optimize_mode')} {meta.get('os')}-{meta.get('arch')} "
        f"cpu={meta.get('cpu_model')} rev={meta.get('vcs_rev')} "
        f"libthai={meta.get('libthai_available')}"
    )


def render_summary(data: dict[str, Any], phase_filter: str | None, markdown: bool) -> None:
    meta = data.get("metadata", {})
    print_metadata("Run", meta)
    print()

    cases = [
        c for c in data.get("cases", [])
        if phase_filter is None or c.get("phase") == phase_filter
    ]

    headers = [
        "Phase", "Case", "N", "Median", "IQR", "p95", "Allocs",
        "Peak Live", "Memmove", "Extra"
    ]
    rows: list[list[str]] = []
    for c in cases:
        extra_parts: list[str] = []
        if c.get("rows_skipped") is not None and c.get("total_rows") is not None:
            extra_parts.append(f"skip={c['rows_skipped']}/{c['total_rows']}")
        if c.get("bytes_processed", 0) > 0 and c["median_ns"] > 0 and c["unit"] == "bytes":
            mib_s = (c["bytes_processed"] / (1024 * 1024)) / (c["median_ns"] / 1e9)
            extra_parts.append(f"{mib_s:.1f} MiB/s")
        rows.append([
            c["phase"],
            c["id"],
            fmt_param(c["param"], c["unit"]),
            fmt_duration_ns(c["median_ns"]),
            fmt_duration_ns(c["iqr_ns"]),
            fmt_duration_ns(c["p95_ns"]),
            str(c["alloc_calls"]),
            fmt_bytes(c["peak_live_bytes"]),
            fmt_bytes(c["bytes_memmoved"]) if c["bytes_memmoved"] > 0 else "0",
            ", ".join(extra_parts) if extra_parts else "-",
        ])

    print_table(headers, rows, markdown)

    scaling = [
        s for s in data.get("scaling", [])
        if phase_filter is None or any(c["id"] == s["id"] and c["phase"] == phase_filter for c in cases)
    ]
    if scaling:
        print("\nScaling Exponents (α = log2(T2/T1) / log2(N2/N1)):")
        s_headers = ["Case", "Range", "α"]
        s_rows = [
            [s["id"], f"{s['from_param']} -> {s['to_param']}", f"{s['alpha']:.2f}"]
            for s in scaling
        ]
        print_table(s_headers, s_rows, markdown)


def check_baseline_gates(data: dict[str, Any]) -> int:
    """Verify Phase 0 gate: predicted quadratic baselines actually exhibit α ≈ 2.0."""
    top = compute_top_alpha(data)
    case_map = {(c["id"], c["param"]): c for c in data.get("cases", [])}

    checks: list[tuple[str, bool, str]] = []

    for cid, min_alpha in [
        ("rewrap_thai_breaks", 1.70),
        ("reflow_numeric_dots", 1.70),
        ("queue_drain_1k", 1.70),
        ("screen_region_scroll", 1.70),
    ]:
        if cid in top:
            fp, tp, alpha = top[cid]
            ok = alpha >= min_alpha
            checks.append((f"{cid} ({fp}->{tp}) α >= {min_alpha:.2f}", ok, f"α={alpha:.2f}"))
        else:
            checks.append((f"{cid} scaling present", False, "missing"))

    if ("queue_drain_1k", 8 * 1024 * 1024) in case_map:
        c = case_map[("queue_drain_1k", 8 * 1024 * 1024)]
        ok = c["bytes_memmoved"] >= 30 * 1024 * 1024 * 1024
        checks.append(("queue_drain_1k 8 MiB memmove >= 30 GiB", ok, fmt_bytes(c["bytes_memmoved"])))

    if ("render_split_1row", 4) in case_map:
        c = case_map[("render_split_1row", 4)]
        ok = c.get("rows_skipped") == 0
        checks.append(("render_split_1row (4 panes) baseline rows_skipped == 0", ok, f"rows_skipped={c.get('rows_skipped')}"))

    print("\nPhase 0 Baseline Gate Verification:")
    failures = 0
    for desc, ok, detail in checks:
        status = "PASS" if ok else "FAIL"
        if not ok:
            failures += 1
        print(f"  [{status}] {desc} ({detail})")
    return 1 if failures else 0


def render_diff(
    base: dict[str, Any],
    cand: dict[str, Any],
    phase_filter: str | None,
    markdown: bool,
) -> None:
    b_meta = base.get("metadata", {})
    c_meta = cand.get("metadata", {})
    print_metadata("Baseline ", b_meta)
    print_metadata("Candidate", c_meta)
    for k in ("optimize_mode", "os", "arch", "libthai_available"):
        if b_meta.get(k) != c_meta.get(k):
            print(f"WARNING: metadata mismatch on '{k}': baseline={b_meta.get(k)} vs candidate={c_meta.get(k)}", file=sys.stderr)
    print()

    cand_map = {(c["id"], c["param"]): c for c in cand.get("cases", [])}
    headers = [
        "Phase", "Case", "N", "Base Med", "Cand Med", "Speedup",
        "IQR", "Alloc Δ", "Peak Δ", "Memmove / Skip"
    ]
    rows: list[list[str]] = []
    for b in base.get("cases", []):
        if phase_filter is not None and b.get("phase") != phase_filter:
            continue
        key = (b["id"], b["param"])
        if key not in cand_map:
            continue
        c = cand_map[key]
        b_med = float(b["median_ns"])
        c_med = float(c["median_ns"])
        if c_med > 0 and b_med > 0:
            ratio = b_med / c_med
            if ratio >= 1.0:
                spd = f"{ratio:.2f}× faster"
            else:
                spd = f"{1.0 / ratio:.2f}× slower"
        else:
            spd = "-"

        overlap = "overlap" if iqr_overlap(b, c) else "distinct"

        b_alloc = int(b["alloc_calls"])
        c_alloc = int(c["alloc_calls"])
        if b_alloc == c_alloc:
            alloc_delta = f"{c_alloc} (0%)"
        elif b_alloc > 0:
            pct = ((c_alloc - b_alloc) / b_alloc) * 100.0
            alloc_delta = f"{b_alloc}->{c_alloc} ({pct:+.1f}%)"
        else:
            alloc_delta = f"0->{c_alloc}"

        b_peak = int(b["peak_live_bytes"])
        c_peak = int(c["peak_live_bytes"])
        if b_peak == c_peak:
            peak_delta = "0%"
        elif b_peak > 0:
            pct = ((c_peak - b_peak) / b_peak) * 100.0
            peak_delta = f"{pct:+.1f}%"
        else:
            peak_delta = f"+{fmt_bytes(c_peak)}"

        extra_parts: list[str] = []
        if b["bytes_memmoved"] > 0 or c["bytes_memmoved"] > 0:
            extra_parts.append(f"mm:{fmt_bytes(b['bytes_memmoved'])}->{fmt_bytes(c['bytes_memmoved'])}")
        if b.get("rows_skipped") is not None or c.get("rows_skipped") is not None:
            extra_parts.append(f"skip:{b.get('rows_skipped')}->{c.get('rows_skipped')}/{c.get('total_rows')}")
        rows.append([
            b["phase"],
            b["id"],
            fmt_param(b["param"], b["unit"]),
            fmt_duration_ns(b_med),
            fmt_duration_ns(c_med),
            spd,
            overlap,
            alloc_delta,
            peak_delta,
            " ".join(extra_parts) if extra_parts else "-",
        ])

    print_table(headers, rows, markdown)

    b_scale = compute_scaling_map(base)
    c_scale = compute_scaling_map(cand)
    common_keys = [sk for sk in b_scale if sk in c_scale]
    if common_keys:
        print("\nScaling Exponent Comparison (α):")
        s_headers = ["Case", "Range", "Base α", "Cand α", "Δα"]
        s_rows: list[list[str]] = []
        for scale_key in common_keys:
            cid, fp, tp = scale_key
            if phase_filter is not None and not any(
                c["id"] == cid and c["phase"] == phase_filter for c in base.get("cases", [])
            ):
                continue
            ba = b_scale[scale_key]
            ca = c_scale[scale_key]
            s_rows.append([cid, f"{fp}->{tp}", f"{ba:.2f}", f"{ca:.2f}", f"{ca - ba:+.2f}"])
        if s_rows:
            print_table(s_headers, s_rows, markdown)


def print_table(headers: list[str], rows: list[list[str]], markdown: bool) -> None:
    if not rows:
        print("(no matching cases)")
        return
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], len(cell))

    if markdown:
        print("| " + " | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)) + " |")
        print("| " + " | ".join("-" * widths[i] for i in range(len(headers))) + " |")
        for r in rows:
            print("| " + " | ".join(cell.ljust(widths[i]) for i, cell in enumerate(r)) + " |")
    else:
        fmt = "  ".join(f"{{:<{w}}}" for w in widths)
        print(fmt.format(*headers))
        print("  ".join("-" * w for w in widths))
        for r in rows:
            print(fmt.format(*r))


def render_e2e_summary(data: dict[str, Any], phase_filter: str | None, markdown: bool) -> None:
    meta = data.get("metadata", {})
    print(
        f"E2E Run: binary={meta.get('szn_binary')} {meta.get('os')}-{meta.get('arch')} "
        f"runs={meta.get('runs')} warmup={meta.get('warmup')}"
    )
    print()
    headers = ["Phase", "Case", "Wall Med", "Wall Min..Max", "Server CPU Med", "Extra"]
    rows: list[list[str]] = []
    for c in data.get("cases", []):
        if phase_filter is not None and c.get("phase") != phase_filter:
            continue
        extra = c.get("extra", {})
        extra_str = ", ".join(f"{k}={v}" for k, v in extra.items()) if extra else "-"
        rows.append([
            c["phase"],
            c["id"],
            f"{c['wall_median_ms']:.1f} ms",
            f"{c['wall_min_ms']:.1f}..{c['wall_max_ms']:.1f} ms",
            f"{c['server_cpu_median_ms']:.1f} ms",
            extra_str,
        ])
    print_table(headers, rows, markdown)


def render_e2e_diff(
    base: dict[str, Any], cand: dict[str, Any], phase_filter: str | None, markdown: bool
) -> None:
    print(f"Baseline E2E : {base.get('metadata', {}).get('szn_binary')}")
    print(f"Candidate E2E: {cand.get('metadata', {}).get('szn_binary')}")
    print()
    cand_map = {c["id"]: c for c in cand.get("cases", [])}
    headers = ["Phase", "Case", "Base Wall", "Cand Wall", "Wall Speedup", "Base CPU", "Cand CPU", "CPU Ratio", "Extra"]
    rows: list[list[str]] = []
    for b in base.get("cases", []):
        if phase_filter is not None and b.get("phase") != phase_filter:
            continue
        if b["id"] not in cand_map:
            continue
        c = cand_map[b["id"]]
        bw, cw = float(b["wall_median_ms"]), float(c["wall_median_ms"])
        w_spd = f"{bw / cw:.2f}× faster" if cw > 0 and bw >= cw else (f"{cw / bw:.2f}× slower" if bw > 0 else "-")
        bc, cc = float(b["server_cpu_median_ms"]), float(c["server_cpu_median_ms"])
        c_spd = f"{bc / cc:.2f}× less" if cc > 0 and bc >= cc else (f"{cc / bc:.2f}× more" if bc > 0 else "-")
        bf = b.get("extra", {}).get("median_frames")
        cf = c.get("extra", {}).get("median_frames")
        extra = f"frames:{bf}->{cf}" if bf is not None and cf is not None else "-"
        rows.append([
            b["phase"],
            b["id"],
            f"{bw:.1f} ms",
            f"{cw:.1f} ms",
            w_spd,
            f"{bc:.1f} ms",
            f"{cc:.1f} ms",
            c_spd,
            extra,
        ])
    print_table(headers, rows, markdown)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare szn algorithmic benchmark JSON files.")
    parser.add_argument("files", nargs="+", help="Either <baseline.json> <candidate.json> or --summary <file.json>")
    parser.add_argument("--summary", action="store_true", help="Print single-run summary instead of A/B diff")
    parser.add_argument("--check-baseline", action="store_true", help="Verify Phase 0 quadratic baseline gates")
    parser.add_argument("--phase", choices=["P0", "P1", "P2", "P3"], default=None, help="Filter by phase")
    parser.add_argument("--markdown", action="store_true", help="Render tables in GitHub Markdown format")
    args = parser.parse_args()

    if args.summary or len(args.files) == 1:
        with open(args.files[0], "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("layer") == "e2e":
            render_e2e_summary(data, args.phase, args.markdown)
            return 0
        render_summary(data, args.phase, args.markdown)
        if args.check_baseline:
            return check_baseline_gates(data)
        return 0

    if len(args.files) != 2:
        parser.error("Expected 1 file with --summary, or 2 files (<baseline.json> <candidate.json>)")

    with open(args.files[0], "r", encoding="utf-8") as f:
        base = json.load(f)
    with open(args.files[1], "r", encoding="utf-8") as f:
        cand = json.load(f)

    if base.get("layer") == "e2e" or cand.get("layer") == "e2e":
        render_e2e_diff(base, cand, args.phase, args.markdown)
        return 0

    render_diff(base, cand, args.phase, args.markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
