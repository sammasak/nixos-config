"""Check minutes and run counts for goals.md's Check tuning table, read from the gate-step records
({job="platform",kind="gate-step"}: logfmt `gate=... step=... check=... seconds=... result=... sha=...`, written by
pkgs/platform-record/platform_record.py from the full gate, the push hook and scripts/pool_merge_check.py). Read-only.
Usage: check-tuning.py --records FILE | [--loki URL] [--since 7d]
--records reads one record per line (a Loki line as `logcli -o raw` prints it, or a spool line `STAMP KIND fields`, of
which only gate-step lines count: the others are counted as other kinds); --loki (default $LOKI_ADDR) queries Loki
one day at a time, newest first, back to exactly --since. Prints one markdown row per (gate, step, check): runs, mean
and worst minutes, the mean minutes waited for a work lock, fails (result=fail). Minutes are seconds=, the run alone:
a step that waits for a lock (the push eval, the probe, pool-merge-*) records that wait apart as wait_seconds=, which
the wait column averages over the runs that carry a number ("-" when none does; unknown is not one). A record of a
check that did not run (result=skipped, deferred, dry or cached, the last a step an eval record let skip:
scripts/eval_record.py; written with seconds=0) is counted as not run, and one without step or a whole number of
seconds as skipped; a failed run
recorded with seconds=0 (the flake check's exit trap, its time unmeasured) counts as a run and a fail but has no
minutes. None is read as a 0-second run. Exit 0 with the table; 2 when no run is recorded, the records cannot be read,
or a Loki day hit its limit."""
import argparse
import http.client
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
NOT_RUN = {"skipped", "deferred", "dry", "cached"}


@dataclass(frozen=True)
class Record:
    gate: str
    step: str
    check: str
    seconds: int
    result: str
    wait: int | None


@dataclass
class Row:
    seconds: list[int] = field(default_factory=list)
    waits: list[int] = field(default_factory=list)
    runs: int = 0
    fails: int = 0


def parse(line: str) -> Record | None:
    """A record, or None when it has no step or its seconds is not a whole number (missing included)."""
    fields = {k: v for k, _, v in (kv.partition("=") for kv in line.split() if "=" in kv)}
    step, seconds = fields.get("step", ""), fields.get("seconds", "")
    if not step or not SECONDS.fullmatch(seconds):
        return None
    wait = fields.get("wait_seconds", "")
    return Record(fields.get("gate") or "-", step, fields.get("check") or "-", int(seconds),
                  fields.get("result", ""), int(wait) if SECONDS.fullmatch(wait) else None)


def other_kind(line: str) -> bool:
    """A spool line (`STAMP KIND fields`, STAMP an ISO time) of a kind other than gate-step; a Loki line starts with a
    field."""
    words = line.split(maxsplit=2)
    return len(words) > 1 and SPOOL_STAMP.match(words[0]) is not None and words[1] != "gate-step"


def cell(text: str) -> str:
    return text.replace("|", "\\|")


@dataclass
class Counts:
    read: int = 0
    not_run: int = 0
    skipped: int = 0
    other: int = 0

    def summary(self) -> str:
        return (f"{self.read} records read, {self.not_run} not run (skipped, deferred, dry or cached), {self.skipped} skipped "
                f"(no step, or no whole seconds), {self.other} of other kinds")


def table(lines: Iterable[str]) -> tuple[list[str], Counts]:
    """The markdown rows, sorted by gate, step and check, and what was read, not run, skipped and of other kinds."""
    rows: dict[tuple[str, str, str], Row] = {}
    n = Counts()
    for line in lines:
        if not line.strip():
            continue
        if other_kind(line):
            n.other += 1
            continue
        rec = parse(line)
        if rec is None:
            n.skipped += 1
            continue
        if rec.result in NOT_RUN:
            n.not_run += 1
            continue
        n.read += 1
        row = rows.setdefault((rec.gate, rec.step, rec.check), Row())
        row.runs += 1
        row.fails += rec.result == "fail"
        if rec.seconds or rec.result != "fail":
            row.seconds.append(rec.seconds)
        if rec.wait is not None:
            row.waits.append(rec.wait)
    out = ["| gate | step | check | runs | mean min | worst min | mean wait min | fails |",
           "|---|---|---|---|---|---|---|---|"]
    for (gate, step, check), row in sorted(rows.items()):
        mean, worst = ((f"{sum(row.seconds) / len(row.seconds) / 60:.1f}", f"{max(row.seconds) / 60:.1f}")
                       if row.seconds else ("-", "-"))
        wait = f"{sum(row.waits) / len(row.waits) / 60:.1f}" if row.waits else "-"
        out.append(f"| {cell(gate)} | {cell(step)} | {cell(check)} | {row.runs} | {mean} | {worst} | {wait} "
                   f"| {row.fails} |")
    return out, n


def span(since: str) -> int:
    """7d or 36h in seconds, more than none."""
    m = re.fullmatch(r"([1-9][0-9]*)([dh])", since)
    if not m:
        raise argparse.ArgumentTypeError(f"--since {since!r}: want Nd or Nh, N at least 1")
    return int(m.group(1)) * (86400 if m.group(2) == "d" else 3600)


def loki_lines(loki: str, seconds: int) -> list[str]:
    """Every gate-step line of the last `seconds`, one query per day (a two-week query times out on the Pi)."""
    end = time.time()
    lines: list[str] = []
    for day in range(-(-seconds // 86400)):
        hi = end - day * 86400
        params = {"query": QUERY, "start": int(max(hi - 86400, end - seconds) * 1e9), "end": int(hi * 1e9),
                  "limit": LIMIT, "direction": "backward"}
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
    ap.add_argument("--since", type=span)
    args = ap.parse_args()
    if args.records and args.since:
        ap.error("--since reads Loki: a --records file is read whole")
    try:
        if args.records:
            lines = args.records.read_text().splitlines()
        elif args.loki:
            if urllib.parse.urlsplit(args.loki).password is not None:
                print("check-tuning: the Loki URL carries a password; give one without", file=sys.stderr)
                return 2
            lines = loki_lines(args.loki.rstrip("/"), args.since or span("7d"))
        else:
            print("check-tuning: no --records and no --loki or LOKI_ADDR", file=sys.stderr)
            return 2
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, RuntimeError) as e:
        print(f"check-tuning: cannot read the records: {e}", file=sys.stderr)
        return 2
    rows, n = table(lines)
    print("\n".join(rows))
    print(f"\n{n.summary()}")
    return 0 if n.read else 2


if __name__ == "__main__":
    sys.exit(main())
