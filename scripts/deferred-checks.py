"""Whether a head may merge as far as deferred checks go: for each check a gate left to its owning host on HEAD
(result=deferred gate-step records, from the flake check or a gate step through scripts/gate_defer.py), does the owner
have a record for that check's derivation: built or present, or expected-fail for a seeded check that must fail? The
derivation, not the head: an owner run of another drv (a dirty checkout) does not count, and the same drv run on an
earlier head does (the check did not change). Read-only: it queries the existing platform records (Loki's
{job="platform"} stream, filtered in LogQL, newest first), or reads a spool file (a host's local copy, or a test).
Usage: deferred-checks.py HEAD [--days N] [--limit N] [--loki URL | --spool FILE...]
An owner record from Loki counts only if its stream's host label is that owner (the owner= field is the writer's own
claim); a spool is one host's local copy and carries no label.
Exit 0: a passing gate on HEAD is recorded and every check its deferred_checks list names is covered (or it names none).
1: a check waits for its owner. 2: the records cannot say: no passing gate record for HEAD, a listed check without its
deferral record, a query that hit its limit, an unreachable Loki, or a malformed HEAD."""
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
COVERING = re.compile(r"result=(built|present|expected-fail)( |$)")


class Unreadable(Exception):
    pass


def fields(line):
    """A logfmt record as platform-record.sh writes it (key=value, values without spaces)."""
    return {k: v.strip('"') for k, v in PAIR.findall(line)}


class Records:
    def __init__(self, args):
        self.args = args
        self.spool = None
        if args.spool:
            self.spool = []
            for p in args.spool:
                for line in pathlib.Path(p).read_text().splitlines():
                    parts = line.split(" ", 2)
                    if len(parts) == 3:
                        self.spool.append((parts[1], parts[2]))

    def find(self, kind, needles, covering=False):
        """The records of KIND whose text holds every needle (and a covering result), newest first, as dicts."""
        if self.spool is not None:
            lines = [l for k, l in reversed(self.spool) if k == kind and all(n in l for n in needles)]
        else:
            q = f'{{job="platform",kind="{kind}"}}' + "".join(f' |= "{n}"' for n in needles)
            if covering:
                q += ' |~ "result=(built|present|expected-fail)( |$)"'
            end = time.time_ns()
            query = urllib.parse.urlencode({"query": q, "start": end - self.args.days * 86400 * 10**9, "end": end,
                                            "limit": self.args.limit, "direction": "backward"})
            try:
                with urllib.request.urlopen(f"{self.args.loki}/loki/api/v1/query_range?{query}", timeout=60) as r:
                    body = json.load(r)
                values = [(int(ts), v, s["stream"].get("host")) for s in body["data"]["result"] for ts, v in s["values"]]
            except (OSError, ValueError, KeyError) as e:
                raise Unreadable(f"Loki query {q!r} failed: {e}") from e
            if len(values) >= self.args.limit:
                raise Unreadable(f"Loki query {q!r} hit its limit of {self.args.limit}: records may be missing")
            lines = [(v, h) for _, v, h in sorted(values, reverse=True)]
        if self.spool is not None:
            lines = [(l, None) for l in lines]
        out = [dict(fields(l), _host=h) for l, h in lines if not covering or COVERING.search(l)]
        # a needle is a substring: keep only records whose fields match it exactly
        exact = [n.split("=", 1) for n in needles if "=" in n]
        return [r for r in out if all(r.get(k) == v for k, v in exact)]


def verdict(records, head):
    """([(owner, check, how)] covered, [(owner, check, drv)] waiting), or Unreadable."""
    gates = records.find("gate", [f"head={head}", "result=pass"])
    if not gates:
        raise Unreadable(f"no passing gate record for {head[:12]}: its gate has not passed, or its records are not in the window")
    listed = {tuple(item.split(":", 1)) for g in gates for item in g.get("deferred_checks", "").split(",") if ":" in item}
    found = {}
    for r in records.find("gate-step", ["result=deferred", f"head={head}"]):
        if r.get("owner") and r.get("check"):
            found.setdefault((r["owner"], r["check"]), r.get("drv", ""))
    missing = sorted(listed - set(found))
    if missing:
        raise Unreadable(f"the gate on {head[:12]} lists {', '.join(':'.join(m) for m in missing)} as deferred, without its deferral record")
    covered, waiting = [], []
    for (owner, check), drv in sorted(found.items()):
        if (owner, check) not in listed:
            continue
        if not drv:
            waiting.append((owner, check, "?"))
            continue
        done = [r for r in records.find("gate-step", [f"owner={owner}", f"check={check}", f"drv={drv}"], covering=True)
                if r["_host"] in (None, owner)]
        if done:
            r = done[0]
            how = "on this head" if r.get("head") == head else f"same drv on {r.get('head', '?')[:12]}"
            covered.append((owner, check, f"{r.get('result')} {how}"))
        else:
            waiting.append((owner, check, drv))
    return covered, waiting


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("head")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--limit", type=int, default=5000)
    ap.add_argument("--loki", default=LOKI)
    ap.add_argument("--spool", nargs="+")
    a = ap.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", a.head):
        print("deferred-checks: HEAD must be a full 40-character sha (the records' head=)", file=sys.stderr)
        sys.exit(2)
    try:
        covered, waiting = verdict(Records(a), a.head)
    except Unreadable as e:
        print(f"deferred-checks: cannot say: {e}", file=sys.stderr)
        sys.exit(2)
    for owner, check, how in covered:
        print(f"ok       {owner}:{check} ({how})")
    for owner, check, drv in waiting:
        print(f"waiting  {owner}:{check}: no built, present or expected-fail record from {owner} for drv {drv}")
    if not covered and not waiting:
        print(f"deferred-checks: the passing gate on {a.head[:12]} deferred nothing")
    sys.exit(1 if waiting else 0)


if __name__ == "__main__":
    main()
