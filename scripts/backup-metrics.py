#!/usr/bin/env python3
"""Persist successful backup completion metadata; expose no backup contents or paths."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time

VALIDATIONS = {"archive_list", "scratch_restore"}


def atomic_write(path, text, mode):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
            temporary = stream.name
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def valid_unit(unit):
    if not re.fullmatch(r"[a-z][a-z0-9-]*", unit):
        raise ValueError("invalid backup unit")
    return unit


def record(unit, directory):
    valid_unit(unit)
    result = subprocess.run(
        ["systemctl", "show", unit + ".service",
         "--property=ExecMainCode,ExecMainStatus,ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic"],
        check=True, capture_output=True, text=True, timeout=5,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    start = int(fields["ExecMainStartTimestampMonotonic"]) / 1e6
    end = int(fields["ExecMainExitTimestampMonotonic"]) / 1e6
    monotonic_now = time.monotonic()
    if (fields["ExecMainCode"] != "1" or fields["ExecMainStatus"] != "0"
            or not 0 < start <= end <= monotonic_now):
        raise ValueError("backup main process has not completed successfully")
    metadata = {"version": 1, "unit": unit,
                "completed_at": time.time() - (monotonic_now - end), "duration_seconds": end - start}
    atomic_write(directory / "success.json", json.dumps(metadata) + "\n", 0o600)


def collect(jobs, state_root, output):
    now = time.time()
    lines = [
        "# HELP homelab_backup_metadata_available Valid successful-completion metadata exists (not backup health).",
        "# TYPE homelab_backup_metadata_available gauge",
        "# HELP homelab_backup_last_success_timestamp_seconds Last successful main-process completion; absent until measured.",
        "# TYPE homelab_backup_last_success_timestamp_seconds gauge",
        "# HELP homelab_backup_last_success_duration_seconds Duration of the last successful main process.",
        "# TYPE homelab_backup_last_success_duration_seconds gauge",
        "# HELP homelab_backup_collector_last_success_timestamp_seconds Last completed metadata scan.",
        "# TYPE homelab_backup_collector_last_success_timestamp_seconds gauge",
    ]
    for unit, validation in sorted(jobs.items()):
        valid_unit(unit)
        if validation not in VALIDATIONS:
            raise ValueError("invalid validation class")
        labels = f'{{backup="{unit}",validation="{validation}"}}'
        try:
            path = state_root / unit / "success.json"
            # Metadata is tiny; do not read an arbitrary-sized damaged file.
            descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            with os.fdopen(descriptor) as stream:
                status = os.fstat(stream.fileno())
                if not stat.S_ISREG(status.st_mode) or status.st_size > 4096:
                    raise ValueError("metadata must be a small regular file")
                metadata = json.loads(stream.read(4097))
            timestamp, duration = metadata["completed_at"], metadata["duration_seconds"]
            if (metadata["version"] != 1 or metadata["unit"] != unit
                    or type(timestamp) not in (int, float) or type(duration) not in (int, float)
                    or not math.isfinite(timestamp) or not math.isfinite(duration)
                    or not 0 < timestamp <= now + 60 or duration < 0):
                raise ValueError("invalid completion metadata")
        except (OSError, ValueError, TypeError, KeyError, OverflowError):
            lines.append(f"homelab_backup_metadata_available{labels} 0")
            continue
        lines.extend([
            f"homelab_backup_metadata_available{labels} 1",
            f"homelab_backup_last_success_timestamp_seconds{labels} {timestamp}",
            f"homelab_backup_last_success_duration_seconds{labels} {duration}",
        ])
    lines.append(f"homelab_backup_collector_last_success_timestamp_seconds {now}")
    atomic_write(output, "\n".join(lines) + "\n", 0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    writer = commands.add_parser("record")
    writer.add_argument("unit")
    writer.add_argument("directory", type=Path)
    reader = commands.add_parser("collect")
    reader.add_argument("jobs", type=Path)
    reader.add_argument("--state-root", type=Path, default=Path("/var/lib/backup-metrics"))
    reader.add_argument("--output", type=Path, default=Path("/run/node-exporter-textfile/backup.prom"))
    args = parser.parse_args()
    if args.command == "record":
        record(args.unit, args.directory)
    else:
        collect(json.loads(args.jobs.read_text()), args.state_root, args.output)


if __name__ == "__main__":
    main()
