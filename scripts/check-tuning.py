"""Check minutes and run counts for goals.md's Check tuning table, read from the gate-step records
({job="platform",kind="gate-step"}: logfmt `gate=... step=... check=... seconds=... result=... sha=...`, written by
pkgs/platform-record/platform_record.py from the full gate, the push hook and scripts/pool_merge_check.py). Read-only.
Usage: check-tuning.py --records FILE | [--loki URL] [--since 7d]
--records reads one record per line (a Loki line, or a spool line `STAMP KIND fields`, of which only gate-step lines
count); --loki (default $LOKI_ADDR) queries Loki one day at a time, newest first. Prints one markdown row per (gate,
step, check): runs, mean and worst minutes, fails (result=fail). A record of a check that did not run (result=skipped,
deferred or dry, written with seconds=0) is counted as not run, and one without step or a whole number of seconds as
skipped: neither is read as a 0-second run. Exit 0 with the table; 2 when no record could be read, or a Loki day hit
its limit."""
import argparse
import json
import os
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
from collections.abc import Iterable
from dataclasses import dataclass, field

QUERY = '{job="platform",kind="gate-step"}'
LIMIT = 5000
SECONDS = re.compile(r"[0-9]+")
SPOOL_STAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T")
NOT_RUN = {"skipped", "deferred", "dry"}


@dataclass(frozen=True)
class Record:
    gate: str
    step: str
    check: str
    seconds: int
    result: str


@dataclass
class Row:
    seconds: list[int] = field(default_factory=list)
    fails: int = 0


def parse(line: str) -> Record | None:
    """A record, or None when it has no step or its seconds is not a whole number (missing included)."""
    fields = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
    step, seconds = fields.get("step", ""), fields.get("seconds", "")
    if not step or not SECONDS.fullmatch(seconds):
        return None
    return Record(fields.get("gate") or "-", step, fields.get("check") or "-", int(seconds),
                  fields.get("result", ""))


def other_kind(line: str) -> bool:
    """A spool line (`STAMP KIND fields`, STAMP an ISO time) of a kind other than gate-step; a Loki line starts with a
    field."""
    words = line.split(maxsplit=2)
    return len(words) > 1 and SPOOL_STAMP.match(words[0]) is not None and words[1] != "gate-step"


def table(lines: Iterable[str]) -> tuple[list[str], int, int, int]:
    """The markdown rows, sorted by gate, step and check; the records read; those not run; the lines skipped."""
    rows: dict[tuple[str, str, str], Row] = {}
    read = not_run = skipped = 0
    for line in lines:
        if not line.strip() or other_kind(line):
            continue
        rec = parse(line)
        if rec is None:
            skipped += 1
            continue
        if rec.result in NOT_RUN:
            not_run += 1
            continue
        read += 1
        row = rows.setdefault((rec.gate, rec.step, rec.check), Row())
        row.seconds.append(rec.seconds)
        row.fails += rec.result == "fail"
    out = ["| gate | step | check | runs | mean min | worst min | fails |", "|---|---|---|---|---|---|---|"]
    for (gate, step, check), row in sorted(rows.items()):
        mean = sum(row.seconds) / len(row.seconds) / 60
        out.append(f"| {gate} | {step} | {check} | {len(row.seconds)} | {mean:.1f} | {max(row.seconds) / 60:.1f} "
                   f"| {row.fails} |")
    return out, read, not_run, skipped


def days(since: str) -> int:
    """7d or 36h as whole days, at least one."""
    m = re.fullmatch(r"([0-9]+)([dh])", since)
    if not m:
        raise argparse.ArgumentTypeError(f"--since {since!r}: want Nd or Nh")
    n = int(m.group(1))
    return max(1, n if m.group(2) == "d" else -(-n // 24))


def loki_lines(loki: str, ndays: int) -> list[str]:
    """Every gate-step line of the last ndays, one query per day (a two-week query times out on the Pi)."""
    end = time.time()
    lines: list[str] = []
    for day in range(ndays):
        hi = end - day * 86400
        params = {"query": QUERY, "start": int((hi - 86400) * 1e9), "end": int(hi * 1e9), "limit": LIMIT,
                  "direction": "backward"}
        with urllib.request.urlopen(f"{loki}/loki/api/v1/query_range?{urllib.parse.urlencode(params)}",
                                    timeout=60) as r:
            got = [line for s in json.load(r)["data"]["result"] for _, line in s["values"]]
        if len(got) >= LIMIT:
            raise RuntimeError(f"day {day} hit the {LIMIT}-line limit: its counts would be short")
        lines += got
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--records", type=pathlib.Path)
    src.add_argument("--loki", default=os.environ.get("LOKI_ADDR"))
    ap.add_argument("--since", type=days)
    args = ap.parse_args()
    if args.records and args.since:
        ap.error("--since reads Loki: a --records file is read whole")
    try:
        if args.records:
            lines = args.records.read_text().splitlines()
        elif args.loki:
            lines = loki_lines(args.loki.rstrip("/"), args.since or days("7d"))
        else:
            print("check-tuning: no --records and no --loki or LOKI_ADDR", file=sys.stderr)
            return 2
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        print(f"check-tuning: cannot read the records: {e}", file=sys.stderr)
        return 2
    rows, read, not_run, skipped = table(lines)
    print("\n".join(rows))
    print(f"\n{read} records read, {not_run} not run (skipped, deferred or dry), {skipped} skipped (no step, or no "
          "whole seconds)")
    return 0 if read else 2


if __name__ == "__main__":
    sys.exit(main())
