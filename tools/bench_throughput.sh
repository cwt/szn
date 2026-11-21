#!/usr/bin/env bash
# Layer 2 End-to-End PTY/IPC macrobenchmark suite for szn.
#
# Exercises full-stack szn behavior in an isolated socket directory (never
# touching any running user szn session):
#   1. e2e_bulk_2mb / e2e_bulk_10mb : Bulk ANSI/UTF-8/CSI-K streaming into an
#                                     attached 2x2 split-pane session
#   2. e2e_resize_scrollback        : 20 alternating resize IPC packets on a
#                                     2,000-line populated Thai/numeric scrollback
#   3. e2e_copy_mode_20x            : 20 enter/exit copy-mode cycles on 2,000 lines
#   4. e2e_sixel_backpressure       : 4 MiB sixel frame relayed through a rate-limited
#                                     (4 KiB/read) attached client (CPU time)
#   5. e2e_tcgetpgrp_rate           : 10-window session streaming 2 MiB output in win 0
#
# Usage:
#   tools/bench_throughput.sh [--szn ./zig-out/bin/szn] [--output e2e.json] [--runs 5]
set -euo pipefail

SZN_BIN="./zig-out/bin/szn"
OUTPUT_JSON=""
RUNS=5
WARMUP=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --szn) SZN_BIN="$2"; shift 2 ;;
        --output) OUTPUT_JSON="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--szn PATH] [--output JSON] [--runs N] [--warmup N]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

SZN_BIN="$(cd "$(dirname "$SZN_BIN")" && pwd)/$(basename "$SZN_BIN")"
if [[ ! -x "$SZN_BIN" ]]; then
    echo "error: szn binary not found or not executable: $SZN_BIN" >&2
    exit 1
fi

# Use short /tmp path so Unix socket path stays well below macOS 104-byte sun_path limit.
WORK_DIR="$(mktemp -d /tmp/szn-e2e.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$SZN_BIN" "$WORK_DIR" "$RUNS" "$WARMUP" "$OUTPUT_JSON" <<'PYEOF'
import json
import os
import platform
import pty
import select
import signal
import socket
import statistics
import struct
import subprocess
import sys
import time

SZN_BIN = sys.argv[1]
WORK_DIR = sys.argv[2]
RUNS = int(sys.argv[3])
WARMUP = int(sys.argv[4])
OUTPUT_JSON = sys.argv[5]

MSG_IDENTIFY_TERM = 0x01
MSG_COMMAND = 0x04
MSG_RESIZE = 0x05
MSG_DETACH = 0x06
MSG_STDIN_DATA = 0x08
MSG_CELL_SIZE = 0x09
MSG_READY = 0x80
MSG_OUTPUT = 0x81
MSG_EXIT = 0x82
MSG_ERR = 0x83
MSG_REQUEST_CELL_SIZE = 0x84


def pack_pkt(msg_type: int, payload: bytes = b"") -> bytes:
    return struct.pack("<IB", 5 + len(payload), msg_type) + payload


def isolated_env(sock_dir: str) -> dict[str, str]:
    env = os.environ.copy()
    env.pop("XDG_RUNTIME_DIR", None)
    env.pop("SZN", None)
    env.pop("SZN_PANE", None)
    env["TMPDIR"] = sock_dir
    env["TERM"] = "xterm-256color"
    env["SHELL"] = "/bin/sh"
    env["PS1"] = "$ "
    return env


def get_proc_cpu_seconds(pid: int) -> float:
    """Read cumulative user+sys CPU time (seconds) for pid via ps."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "cputime=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not out:
            return 0.0
        # Format on macOS/Linux: [DD-]HH:MM:SS[.cc] or MM:SS.cc
        days = 0
        if "-" in out:
            d_str, out = out.split("-", 1)
            days = int(d_str)
        parts = out.split(":")
        if len(parts) == 3:
            h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
            return days * 86400 + h * 3600 + m * 60 + s
        if len(parts) == 2:
            m, s = int(parts[0]), float(parts[1])
            return days * 86400 + m * 60 + s
        return float(out)
    except Exception:
        return 0.0


def find_server_pid(sock_dir: str) -> int | None:
    """Locate the szn daemon pid listening on sock_dir/szn.sock using lsof or ps."""
    sock_path = os.path.join(sock_dir, "szn.sock")
    try:
        out = subprocess.check_output(
            ["lsof", "-t", sock_path],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        for line in out.splitlines():
            line = line.strip()
            if line.isdigit():
                return int(line)
    except Exception:
        pass
    return None


class IsolatedSzn:
    _seq = 0

    def __init__(self, tag: str):
        IsolatedSzn._seq += 1
        self.sock_dir = os.path.join(WORK_DIR, f"s{IsolatedSzn._seq}")
        os.makedirs(self.sock_dir, exist_ok=True)
        self.env = isolated_env(self.sock_dir)
        self.sock_path = os.path.join(self.sock_dir, "szn.sock")
        self.server_pid: int | None = None

    def cmd(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            [SZN_BIN, *args],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=check,
            timeout=30,
        )

    def start(self, name: str = "bench") -> None:
        self.cmd("new-session", "-d", name)
        deadline = time.monotonic() + 5.0
        while not os.path.exists(self.sock_path) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.server_pid = find_server_pid(self.sock_dir)

    def cmd_ipc(self, command: str) -> None:
        """Send a single MSG_COMMAND directly over the Unix socket (no fork/exec)."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(10.0)
            s.connect(self.sock_path)
            s.sendall(pack_pkt(MSG_COMMAND, command.encode("utf-8")))
            buf = bytearray()
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                while len(buf) >= 5:
                    plen, mtype = struct.unpack("<IB", buf[:5])
                    if len(buf) < plen:
                        break
                    del buf[:plen]
                    if mtype in (MSG_READY, MSG_EXIT, MSG_ERR):
                        return
        finally:
            s.close()

    def connect_display(self, cols: int = 120, rows: int = 40) -> socket.socket:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.sock_path)
        s.sendall(pack_pkt(MSG_IDENTIFY_TERM, b"xterm-256color"))
        s.sendall(pack_pkt(MSG_RESIZE, struct.pack("<II", cols, rows)))
        s.sendall(pack_pkt(MSG_CELL_SIZE, struct.pack("<II", 20, 10)))
        s.setblocking(False)
        return s

    def cleanup(self) -> None:
        try:
            self.cmd("kill-session", check=False)
        except Exception:
            pass
        if self.server_pid:
            try:
                os.kill(self.server_pid, signal.SIGTERM)
                time.sleep(0.05)
                os.kill(self.server_pid, signal.SIGKILL)
            except OSError:
                pass


def wait_for_output_frame(sock: socket.socket, timeout: float = 5.0) -> int:
    """Wait until at least one MSG_OUTPUT packet arrives and return frame count."""
    frames = 0
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while frames == 0 and time.monotonic() < deadline:
        rem = deadline - time.monotonic()
        r, _, _ = select.select([sock], [], [], min(rem, 0.05))
        if not r:
            continue
        try:
            chunk = sock.recv(65536)
        except BlockingIOError:
            continue
        if not chunk:
            break
        buf.extend(chunk)
        while len(buf) >= 5:
            plen, mtype = struct.unpack("<IB", buf[:5])
            if len(buf) < plen:
                break
            if mtype == MSG_OUTPUT:
                frames += 1
            elif mtype == MSG_REQUEST_CELL_SIZE:
                sock.sendall(pack_pkt(MSG_CELL_SIZE, struct.pack("<II", 20, 10)))
            del buf[:plen]
    return frames


def drain_socket_nonblocking(sock: socket.socket, max_wait: float = 0.05) -> tuple[int, int]:
    """Drain packets from display socket; returns (bytes_read, output_frames)."""
    total_bytes = 0
    frames = 0
    buf = bytearray()
    deadline = time.monotonic() + max_wait
    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            break
        r, _, _ = select.select([sock], [], [], min(rem, 0.01))
        if not r:
            if total_bytes > 0:
                break
            continue
        try:
            chunk = sock.recv(65536)
        except BlockingIOError:
            continue
        if not chunk:
            break
        total_bytes += len(chunk)
        buf.extend(chunk)
        while len(buf) >= 5:
            plen, mtype = struct.unpack("<IB", buf[:5])
            if len(buf) < plen:
                break
            if mtype == MSG_OUTPUT:
                frames += 1
            elif mtype == MSG_REQUEST_CELL_SIZE:
                sock.sendall(pack_pkt(MSG_CELL_SIZE, struct.pack("<II", 20, 10)))
            del buf[:plen]
    return total_bytes, frames


def write_payload_file(path: str, total_bytes: int) -> None:
    line = "\x1b[38;5;196m┌────────┐\x1b[0m ภาษาไทยทดสอบ │ line payload \x1b[K\r\n".encode("utf-8")
    reps = (total_bytes + len(line) - 1) // len(line)
    with open(path, "wb") as f:
        chunk = line * min(reps, 4096)
        written = 0
        while written < total_bytes:
            need = min(len(chunk), total_bytes - written)
            f.write(chunk[:need])
            written += need


def bench_bulk_stream(size_bytes: int, split_2x2: bool = True, num_windows: int = 1) -> dict:
    payload_path = os.path.join(WORK_DIR, f"payload_{size_bytes}.bin")
    if not os.path.exists(payload_path):
        write_payload_file(payload_path, size_bytes)

    szn = IsolatedSzn(f"bulk_{size_bytes}")
    try:
        szn.start()
        if split_2x2:
            szn.cmd("split-window", "-h")
            szn.cmd("split-window", "-v")
            szn.cmd("select-pane", "-L")
            szn.cmd("split-window", "-v")
        for w_idx in range(1, num_windows):
            szn.cmd("new-window", f"w{w_idx}")
        if num_windows > 1:
            szn.cmd("select-window", "0")

        disp = szn.connect_display(200, 60)
        try:
            drain_socket_nonblocking(disp, 0.25)
            # Split the marker across two shell variables so PTY command-echo
            # never triggers a false match before `cat` finishes.
            tag = str(time.monotonic_ns())
            marker = f"__E2E_DONE_{tag}__"
            cpu_before = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            t0 = time.monotonic()

            cmd_str = f"M1=__E2E_DO; M2=NE_{tag}__; cat '{payload_path}'; printf '\\n%s%s\\n' \"$M1\" \"$M2\"\r"
            disp.sendall(pack_pkt(MSG_STDIN_DATA, cmd_str.encode("utf-8")))

            frames = 0
            total_rx = 0
            buf = bytearray()
            marker_bytes = marker.encode("utf-8")
            done = False
            deadline = time.monotonic() + 60.0
            while not done and time.monotonic() < deadline:
                r, _, _ = select.select([disp], [], [], 0.05)
                if not r:
                    continue
                try:
                    chunk = disp.recv(65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    break
                total_rx += len(chunk)
                buf.extend(chunk)
                while len(buf) >= 5:
                    plen, mtype = struct.unpack("<IB", buf[:5])
                    if len(buf) < plen:
                        break
                    body = bytes(buf[5:plen])
                    if mtype == MSG_OUTPUT:
                        frames += 1
                        if marker_bytes in body:
                            done = True
                    elif mtype == MSG_REQUEST_CELL_SIZE:
                        disp.sendall(pack_pkt(MSG_CELL_SIZE, struct.pack("<II", 20, 10)))
                    del buf[:plen]

            elapsed = time.monotonic() - t0
            cpu_after = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            if not done:
                raise RuntimeError(f"Timed out waiting for marker in bulk stream ({size_bytes} bytes)")
            return {
                "wall_s": elapsed,
                "server_cpu_s": max(0.0, cpu_after - cpu_before),
                "render_frames": frames,
                "client_rx_bytes": total_rx,
            }
        finally:
            disp.close()
    finally:
        szn.cleanup()


def bench_resize_scrollback() -> dict:
    scroll_path = os.path.join(WORK_DIR, "scroll_2000.txt")
    if not os.path.exists(scroll_path):
        with open(scroll_path, "wb") as f:
            for i in range(2000):
                if i % 5 == 0:
                    line = f"{i:04d} ภาษาไทยทดสอบการตัดคำอัตโนมัติในเทอร์มินัลเพื่อวัดความเร็ว 1234567890.1234567890.1234567890.\n"
                else:
                    line = f"{i:04d} ordinary log line with mixed ASCII tokens and numbers 12345.67890\n"
                f.write(line.encode("utf-8"))

    szn = IsolatedSzn("resize_2000")
    try:
        szn.start()
        disp = szn.connect_display(120, 40)
        try:
            drain_socket_nonblocking(disp, 0.25)
            marker = "__RESIZE_READY__"
            disp.sendall(pack_pkt(MSG_STDIN_DATA, f"M1=__RESIZE_; M2=READY__; cat '{scroll_path}'; printf '\\n%s%s\\n' \"$M1\" \"$M2\"\r".encode("utf-8")))
            # Wait until scrollback is fully populated
            deadline = time.monotonic() + 20.0
            ready = False
            buf = bytearray()
            while not ready and time.monotonic() < deadline:
                r, _, _ = select.select([disp], [], [], 0.05)
                if not r:
                    continue
                chunk = disp.recv(65536)
                if not chunk:
                    break
                buf.extend(chunk)
                if marker.encode() in buf:
                    ready = True
                if len(buf) > 262144:
                    del buf[:-4096]
            if not ready:
                raise RuntimeError("Timed out populating 2000-line scrollback")
            drain_socket_nonblocking(disp, 0.15)

            widths = [60, 100, 40, 120, 50, 110, 45, 95, 65, 120] * 2  # 20 alternating resizes
            cpu_before = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            t0 = time.monotonic()
            frames = 0
            for w in widths:
                disp.sendall(pack_pkt(MSG_RESIZE, struct.pack("<II", w, 40)))
                # Wait for at least one rendered frame response per resize
                step_deadline = time.monotonic() + 5.0
                got_frame = False
                pbuf = bytearray()
                while not got_frame and time.monotonic() < step_deadline:
                    r, _, _ = select.select([disp], [], [], 0.05)
                    if not r:
                        continue
                    chunk = disp.recv(65536)
                    if not chunk:
                        break
                    pbuf.extend(chunk)
                    while len(pbuf) >= 5:
                        plen, mtype = struct.unpack("<IB", pbuf[:5])
                        if len(pbuf) < plen:
                            break
                        if mtype == MSG_OUTPUT:
                            frames += 1
                            got_frame = True
                        del pbuf[:plen]
            elapsed = time.monotonic() - t0
            cpu_after = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            return {
                "wall_s": elapsed,
                "server_cpu_s": max(0.0, cpu_after - cpu_before),
                "render_frames": frames,
            }
        finally:
            disp.close()
    finally:
        szn.cleanup()


def bench_copy_mode_20x() -> dict:
    scroll_path = os.path.join(WORK_DIR, "scroll_unwrapped_2000.txt")
    if not os.path.exists(scroll_path):
        with open(scroll_path, "wb") as f:
            for i in range(2000):
                f.write(f"{i:04d} short unwrapped history line for copy-mode entry benchmark\n".encode("utf-8"))

    szn = IsolatedSzn("copymode_20x")
    try:
        szn.start()
        disp = szn.connect_display(120, 40)
        try:
            drain_socket_nonblocking(disp, 0.25)
            marker = "__COPY_READY__"
            disp.sendall(pack_pkt(MSG_STDIN_DATA, f"M1=__COPY_; M2=READY__; cat '{scroll_path}'; printf '\\n%s%s\\n' \"$M1\" \"$M2\"\r".encode("utf-8")))
            deadline = time.monotonic() + 20.0
            buf = bytearray()
            ready = False
            while not ready and time.monotonic() < deadline:
                r, _, _ = select.select([disp], [], [], 0.05)
                if not r:
                    continue
                chunk = disp.recv(65536)
                if not chunk:
                    break
                buf.extend(chunk)
                if marker.encode() in buf:
                    ready = True
                if len(buf) > 262144:
                    del buf[:-4096]
            if not ready:
                raise RuntimeError("Timed out populating copy-mode history")
            drain_socket_nonblocking(disp, 0.15)

            cpu_before = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            t0 = time.monotonic()
            for _ in range(20):
                szn.cmd_ipc("copy-mode")
                # Wait for the copy-mode render frame, then exit immediately via 'q'
                wait_for_output_frame(disp)
                disp.sendall(pack_pkt(MSG_STDIN_DATA, b"q"))
                wait_for_output_frame(disp)
            elapsed = time.monotonic() - t0
            cpu_after = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            return {
                "wall_s": elapsed,
                "server_cpu_s": max(0.0, cpu_after - cpu_before),
            }
        finally:
            disp.close()
    finally:
        szn.cleanup()


def bench_sixel_backpressure() -> dict:
    sixel_path = os.path.join(WORK_DIR, "sixel_4mb.bin")
    if not os.path.exists(sixel_path):
        # Valid 4 MiB sixel DCS payload (100x60 px raster + 4 MiB band data + ST)
        header = b'\x1bPq"1;1;100;60#0;2;100;0;0'
        footer = b"\x1b\\"
        body_len = 4 * 1024 * 1024 - len(header) - len(footer)
        row = b"#0" + b"~" * 98 + b"-"
        with open(sixel_path, "wb") as f:
            f.write(header)
            written = 0
            while written < body_len:
                take = min(len(row), body_len - written)
                f.write(row[:take])
                written += take
            f.write(footer)

    szn = IsolatedSzn("sixel_bp")
    try:
        szn.start()
        disp = szn.connect_display(120, 40)
        try:
            # Shrink socket receive buffer to force partial writes & server out_buf queuing
            try:
                disp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
            except OSError:
                pass
            drain_socket_nonblocking(disp, 0.2)

            marker = "__SIXEL_DONE__"
            cpu_before = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            t0 = time.monotonic()
            disp.sendall(pack_pkt(MSG_STDIN_DATA, f"M1=__SIXEL_; M2=DONE__; cat '{sixel_path}'; printf '\\n%s%s\\n' \"$M1\" \"$M2\"\r".encode("utf-8")))

            # Rate-limited reader: 4 KiB per read with 0.2 ms pacing so server hits EAGAIN
            total_rx = 0
            saw_sixel = False
            saw_marker = False
            tail = bytearray()
            deadline = time.monotonic() + 60.0
            while not saw_marker and time.monotonic() < deadline:
                r, _, _ = select.select([disp], [], [], 0.05)
                if not r:
                    continue
                try:
                    chunk = disp.recv(4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    break
                total_rx += len(chunk)
                tail.extend(chunk)
                if not saw_sixel and b"\x1bPq" in tail:
                    saw_sixel = True
                if marker.encode() in tail:
                    saw_marker = True
                if len(tail) > 16384:
                    del tail[:-256]
                time.sleep(0.0002)

            elapsed = time.monotonic() - t0
            cpu_after = get_proc_cpu_seconds(szn.server_pid) if szn.server_pid else 0.0
            return {
                "wall_s": elapsed,
                "server_cpu_s": max(0.0, cpu_after - cpu_before),
                "client_rx_bytes": total_rx,
                "saw_sixel": saw_sixel,
                "completed": saw_marker,
            }
        finally:
            disp.close()
    finally:
        szn.cleanup()


def run_suite(name: str, phase: str, fn) -> dict:
    for _ in range(WARMUP):
        fn()
    samples = []
    for _ in range(RUNS):
        samples.append(fn())
    walls = sorted(s["wall_s"] for s in samples)
    cpus = sorted(s["server_cpu_s"] for s in samples)
    med_wall = statistics.median(walls)
    med_cpu = statistics.median(cpus)
    extra = {}
    if "render_frames" in samples[0]:
        extra["median_frames"] = statistics.median(s["render_frames"] for s in samples)
    if "client_rx_bytes" in samples[0]:
        extra["median_rx_bytes"] = statistics.median(s["client_rx_bytes"] for s in samples)
    print(
        f"  [{phase}] {name:<24} wall_med={med_wall*1000:8.1f} ms  server_cpu_med={med_cpu*1000:7.1f} ms  {extra}",
        file=sys.stderr,
        flush=True,
    )
    return {
        "id": name,
        "phase": phase,
        "runs": RUNS,
        "wall_median_ms": med_wall * 1000.0,
        "wall_min_ms": walls[0] * 1000.0,
        "wall_max_ms": walls[-1] * 1000.0,
        "server_cpu_median_ms": med_cpu * 1000.0,
        "extra": extra,
        "samples": samples,
    }


def main() -> None:
    print(f"szn E2E macrobenchmark suite | binary={SZN_BIN} | runs={RUNS} warmup={WARMUP}", file=sys.stderr)
    results = [
        run_suite("e2e_bulk_2mb", "P2", lambda: bench_bulk_stream(2 * 1024 * 1024, split_2x2=True)),
        run_suite("e2e_bulk_10mb", "P2", lambda: bench_bulk_stream(10 * 1024 * 1024, split_2x2=True)),
        run_suite("e2e_tcgetpgrp_rate", "P2", lambda: bench_bulk_stream(2 * 1024 * 1024, split_2x2=False, num_windows=10)),
        run_suite("e2e_resize_scrollback", "P0", bench_resize_scrollback),
        run_suite("e2e_copy_mode_20x", "P0", bench_copy_mode_20x),
        run_suite("e2e_sixel_backpressure", "P1", bench_sixel_backpressure),
    ]

    report = {
        "schema_version": 1,
        "layer": "e2e",
        "metadata": {
            "szn_binary": SZN_BIN,
            "os": platform.system().lower(),
            "arch": platform.machine(),
            "runs": RUNS,
            "warmup": WARMUP,
            "timestamp_unix": int(time.time()),
        },
        "cases": results,
    }

    payload = json.dumps(report, indent=2) + "\n"
    if OUTPUT_JSON:
        with open(OUTPUT_JSON, "w", encoding="utf-8") as f:
            f.write(payload)
        print(f"Wrote E2E benchmark JSON to {OUTPUT_JSON}", file=sys.stderr)
    else:
        sys.stdout.write(payload)


if __name__ == "__main__":
    main()
PYEOF
