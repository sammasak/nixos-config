"""Whether a head may merge as far as deferred checks go: for each check a gate left to its owning host on HEAD
(result=deferred gate-step records, from the flake check or a gate step through scripts/gate_defer.py), is there an
owner record for it: built or present on HEAD itself, or for the same check derivation on any head (the check did not
change, so the owner's earlier run still covers it)? Read-only: it reads the existing platform records (Loki's
{job="platform"} stream, or a spool file for a host's local copy or a test), nothing else.
Usage: deferred-checks.py HEAD [--days N] [--loki URL | --spool FILE...]
Exit 0 when nothing is outstanding (also when nothing was deferred), 1 when a check still waits for its owner, 2 when
the records cannot be read."""
import argparse
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request

LOKI = "http://192.168.10.137:3100"  # sam.fleet.loki (modules/core/fleet.nix), as scripts/platform-record.sh
PAIR = re.compile(r'(\w+)=("[^"]*"|\S*)')


def fields(line):
    """A logfmt record as platform-record.sh writes it (key=value, values without spaces)."""
    return {k: v.strip('"') for k, v in PAIR.findall(line)}


def from_loki(url, days):
    """Every gate-step record of the last DAYS days, oldest first."""
    end = time.time_ns()
    query = urllib.parse.urlencode({"query": '{job="platform",kind="gate-step"}', "start": end - days * 86400 * 10**9,
                                    "end": end, "limit": 5000, "direction": "forward"})
    with urllib.request.urlopen(f"{url}/loki/api/v1/query_range?{query}", timeout=20) as r:
        body = json.load(r)
    lines = [(int(ts), v, s["stream"].get("host", "")) for s in body["data"]["result"] for ts, v in s["values"]]
    return [dict(fields(v), _host=h) for _, v, h in sorted(lines)]


def from_spool(paths):
    """A spool file's gate-step lines: "<date> gate-step <record>"."""
    out = []
    for p in paths:
        for line in pathlib.Path(p).read_text().splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[1] == "gate-step":
                out.append(fields(parts[2]))
    return out


def outstanding(records, head):
    """[(owner, check, drv)] deferred on HEAD that no owner record covers, and the covered ones with what covers them."""
    deferred = {(r["owner"], r["check"], r.get("drv", "")) for r in records
                if r.get("result") == "deferred" and r.get("head") == head and r.get("owner") and r.get("check")}
    done = [r for r in records if r.get("result") in ("built", "present")]
    waiting, covered = [], []
    for owner, check, drv in sorted(deferred):
        by_head = [r for r in done if r.get("owner") == owner and r.get("check") == check and r.get("head") == head]
        by_drv = [r for r in done if r.get("owner") == owner and drv and r.get("drv") == drv]
        if by_head or by_drv:
            covered.append((owner, check, "on this head" if by_head else f"same drv on {by_drv[-1].get('head', '?')[:12]}"))
        else:
            waiting.append((owner, check, drv))
    return waiting, covered


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("head")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--loki", default=LOKI)
    ap.add_argument("--spool", nargs="+")
    a = ap.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", a.head):
        sys.exit("deferred-checks: HEAD must be a full 40-character sha (the records' head=)")
    try:
        records = from_spool(a.spool) if a.spool else from_loki(a.loki, a.days)
    except (OSError, ValueError, KeyError) as e:
        print(f"deferred-checks: cannot read the records: {e}", file=sys.stderr)
        sys.exit(2)
    waiting, covered = outstanding(records, a.head)
    for owner, check, how in covered:
        print(f"ok       {owner}:{check} ({how})")
    for owner, check, drv in waiting:
        print(f"waiting  {owner}:{check}: no built or present record from {owner} for this head or drv {drv or '?'}")
    if not waiting and not covered:
        print(f"deferred-checks: nothing was deferred on {a.head[:12]} in the records read")
    sys.exit(1 if waiting else 0)


if __name__ == "__main__":
    main()
