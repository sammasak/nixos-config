#!/usr/bin/env python3
"""Read-only ASUS evidence collection, never a wake or an inference command."""

import argparse
from datetime import datetime, timezone
import subprocess

REMOTE_SCRIPT = """set -euo pipefail
date -u
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,power.draw,power.limit,enforced.power.limit,temperature.gpu,fan.speed,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv
systemctl --failed --no-pager
systemctl is-active ollama prometheus-nvidia-gpu-exporter
curl --fail --silent --show-error --max-time 5 http://ollama-asus.fleet.sammasak.dev:11434/api/version
curl --fail --silent --show-error --max-time 5 http://ollama-asus.fleet.sammasak.dev:11434/api/ps
"""


def parse_not_before(value: str) -> datetime:
    try:
        boundary = datetime.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "use an ISO 8601 timestamp with a timezone"
        ) from error
    if boundary.utcoffset() is None:
        raise argparse.ArgumentTypeError("the timestamp must include a timezone")
    return boundary.astimezone(timezone.utc)


def collect(now: datetime, not_before: datetime) -> subprocess.CompletedProcess[str]:
    if now.utcoffset() is None or not_before.utcoffset() is None:
        raise ValueError("the current time and owner boundary must include timezones")
    if now < not_before:
        raise ValueError(f"No ASUS connection before {not_before.isoformat()}")
    # The remote default shell is Fish; explicitly run Bash for the strict read-only script.
    return subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            "asus-b460m",
            "/run/current-system/sw/bin/bash -s",
        ],
        input=REMOTE_SCRIPT,
        text=True,
        check=True,
        timeout=30,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--not-before",
        required=True,
        type=parse_not_before,
        help="owner-approved earliest time, with an explicit date and timezone",
    )
    args = parser.parse_args()
    try:
        collect(datetime.now(timezone.utc), args.not_before)
    except ValueError as error:
        print(f"REFUSED: {error}")
        return 3
    except (subprocess.SubprocessError, OSError) as error:
        print(f"Preflight incomplete: {type(error).__name__}")
        return 1
    print(
        "Read-only collection complete. Inspect limits, thermal flags and failed units before testing."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
