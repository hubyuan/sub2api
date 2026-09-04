#!/usr/bin/env python3
"""Sample Docker CPU, memory, and PID usage and emit reproducible JSON."""

import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import threading
import time


UNIT_BYTES = {
    "B": 1,
    "KB": 1000,
    "MB": 1000**2,
    "GB": 1000**3,
    "KIB": 1024,
    "MIB": 1024**2,
    "GIB": 1024**3,
}


def parse_bytes(value: str) -> int:
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]+)\s*", value)
    if not match:
        raise ValueError(f"unsupported Docker memory value: {value!r}")
    unit = match.group(2).upper()
    return round(float(match.group(1)) * UNIT_BYTES[unit])


def sample(container: str) -> dict[str, float | int]:
    result = subprocess.run(
        [
            "docker",
            "stats",
            "--no-stream",
            "--format",
            "{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}",
            container,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    cpu, memory, pids = result.stdout.strip().split("\t")
    return {
        "elapsed_seconds": 0.0,
        "cpu_percent": float(cpu.rstrip("%")),
        "memory_bytes": parse_bytes(memory.split("/", 1)[0]),
        "pids": int(pids),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--duration", type=float, default=0.0)
    args = parser.parse_args()

    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stopped.set())
    signal.signal(signal.SIGINT, lambda _signum, _frame: stopped.set())
    started = time.monotonic()
    samples: list[dict[str, float | int]] = []

    while not stopped.is_set():
        try:
            current = sample(args.container)
            current["elapsed_seconds"] = round(time.monotonic() - started, 3)
            samples.append(current)
        except (subprocess.CalledProcessError, ValueError):
            pass
        if args.duration and time.monotonic() - started >= args.duration:
            break
        stopped.wait(args.interval)

    if not samples:
        raise SystemExit(f"no Docker resource samples captured for {args.container}")
    summary = {
        "container": args.container,
        "sample_count": len(samples),
        "cpu_peak_percent": max(item["cpu_percent"] for item in samples),
        "memory_peak_bytes": max(item["memory_bytes"] for item in samples),
        "pids_peak": max(item["pids"] for item in samples),
        "samples": samples,
    }
    args.output.write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
