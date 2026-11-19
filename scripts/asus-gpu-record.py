#!/usr/bin/env python3
"""Record local GPU readings with bounded queries and measured sample times."""
import argparse
import csv
from datetime import datetime, timezone
import json
import subprocess
import sys
import time

FIELDS = (
    "index", "uuid", "power.draw", "power.limit", "enforced.power.limit",
    "temperature.gpu", "fan.speed", "memory.used", "memory.total",
    "clocks_throttle_reasons.hw_thermal_slowdown",
    "clocks_throttle_reasons.sw_thermal_slowdown",
)


def record(samples, output):
    if not 1 <= samples <= 3600:
        raise ValueError("samples must be between 1 and 3600")
    for sequence in range(samples):
        started = time.monotonic()
        utc = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=" + ",".join(FIELDS),
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, check=True, timeout=3,
        )
        finished = time.monotonic()
        rows = list(csv.reader(result.stdout.splitlines(), skipinitialspace=True))
        if not rows or any(len(row) != len(FIELDS) for row in rows):
            raise ValueError("missing or malformed GPU readings")
        # Preserve unsupported fields as evidence; never turn N/A into zero.
        output.write(json.dumps({
            "sequence": sequence, "utc_started": utc,
            "monotonic_started_s": started, "monotonic_finished_s": finished,
            "gpus": [dict(zip(FIELDS, row)) for row in rows],
        }) + "\n")
        output.flush()
        if sequence + 1 < samples:
            time.sleep(max(0, 1 - (time.monotonic() - started)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=60,
                        help="1 to 3600 samples, approximately one per second")
    args = parser.parse_args()
    try:
        record(args.samples, sys.stdout)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"GPU recording incomplete: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
