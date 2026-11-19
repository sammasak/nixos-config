#!/usr/bin/env python3
"""Read-only ASUS evidence collection, never a wake or an inference command."""
from datetime import datetime, timezone
import subprocess

# Owner boundary: 20 November 2026, 09:00 Europe/Stockholm (CET).
NOT_BEFORE = datetime(2026, 11, 20, 8, tzinfo=timezone.utc)
REMOTE_SCRIPT = """set -euo pipefail
date -u
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,power.draw,power.limit,enforced.power.limit,temperature.gpu,fan.speed,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv
systemctl --failed --no-pager
systemctl is-active ollama prometheus-nvidia-gpu-exporter
curl --fail --silent --show-error --max-time 5 http://192.168.10.113:11434/api/version
curl --fail --silent --show-error --max-time 5 http://192.168.10.113:11434/api/ps
"""


def collect(now: datetime) -> subprocess.CompletedProcess[str]:
    if now < NOT_BEFORE:
        raise ValueError("No ASUS connection or wake before 2026-11-20 09:00 Europe/Stockholm")
    # The remote default shell is Fish; explicitly run Bash for the strict read-only script.
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "asus-b460m",
         "/run/current-system/sw/bin/bash -s"],
        input=REMOTE_SCRIPT, text=True, check=True, timeout=30,
    )


def main() -> int:
    try:
        collect(datetime.now(timezone.utc))
    except ValueError as error:
        print(f"REFUSED: {error}")
        return 3
    except (subprocess.SubprocessError, OSError) as error:
        print(f"Preflight incomplete: {type(error).__name__}")
        return 1
    print("Read-only collection complete. Inspect limits, thermal flags and failed units before testing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
