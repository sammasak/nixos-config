"""Whether a head may merge as far as deferred checks go: for each check a gate left to its owning host on HEAD
(result=deferred gate-step records, from the flake check or a gate step through scripts/gate_defer.py), does the owner
have a record for that check's derivation: built, present or fetched (a valid output of that drv exists on the
owner), or expected-fail for a seeded check that must fail? dry (not built) and fail never count. The
derivation, not the head: an owner run of another drv (a dirty checkout) does not count, and the same drv run on an
earlier head does (the check did not change). Read-only: it queries the existing platform records (Loki's
{job="platform"} stream, filtered in LogQL, newest first), or reads a spool file (a host's local copy, or a test).
Usage: deferred-checks.py HEAD [--days N] [--limit N] [--loki URL | --spool FILE...]
An owner record from Loki counts only if its stream's host label is that owner (the owner= field is the writer's own
claim; a record without the label does not count); a spool is one host's local copy and carries no label.
The gate record must come from a fleet host's own stream: a gate run in a worker guest (stream host <host>-<guest>) is
reported and not counted. The fleet's host names are the keys of the hosts table in modules/core/fleet.nix (sam.fleet.hosts,
networking.hostName, which platform-record.sh labels its stream with), read from the file's text: no evaluation here;
scripts/test-fleet-contract.py holds the parse to the evaluated sam.fleet.hosts.
Exit 0: a passing gate on a clean checkout of HEAD is recorded and every check its deferred_checks list names is
covered (or it names none). 1: a check waits for its owner. 2: the records cannot say: no such gate record, a listed
check without its deferral record, a query that hit its limit, an unreachable Loki, or a malformed HEAD."""
import argparse
import json
import os
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent


def default_loki():
    """PLATFORM_LOKI_URL, else scripts/platform-record.sh's own default: the one place outside fleet.nix that may
    name Loki's address (scripts/test-fleet-contract.py holds it to the evaluated sam.fleet.loki.url)."""
    if os.environ.get("PLATFORM_LOKI_URL"):
        return os.environ["PLATFORM_LOKI_URL"]
    m = re.search(r"\$\{PLATFORM_LOKI_URL:-(https?://[^}]+)\}", (ROOT / "scripts/platform-record.sh").read_text())
    if not m:
        raise Unreadable("scripts/platform-record.sh has no ${PLATFORM_LOKI_URL:-…} default to read Loki's address from")
    return m[1]
PAIR = re.compile(r'(\w+)=("[^"]*"|\S*)')
COVERING = re.compile(r"result=(built|present|fetched|expected-fail)( |$)")


class Unreadable(Exception):
    pass


def fleet_hosts(root=ROOT):
    """The keys of fleet.nix's `hosts = { ... };` table, without evaluating it: `name.address = …;` or `name = {` at the
    table's own indentation."""
    text = (pathlib.Path(root) / "modules/core/fleet.nix").read_text()
    table = re.search(r"\n  hosts = \{\n(.*?)\n  \};\n", text, re.S)
    if not table:
        raise Unreadable("modules/core/fleet.nix has no `  hosts = {` table to read the fleet's host names from")
    names = set(re.findall(r"^    ([A-Za-z0-9-]+)(?:\.address)? = ", table[1], re.M))
    if not names:
        raise Unreadable("modules/core/fleet.nix's hosts table names no host")
    return names


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
                q += ' |~ "result=(built|present|fetched|expected-fail)( |$)"'
            end = time.time_ns()
            query = urllib.parse.urlencode({"query": q, "start": end - self.args.days * 86400 * 10**9, "end": end,
                                            "limit": self.args.limit, "direction": "backward"})
            try:
                with urllib.request.urlopen(f"{self.args.loki}/loki/api/v1/query_range?{query}", timeout=60) as r:
                    body = json.load(r)
                values = [(int(ts), v, s["stream"].get("host", "")) for s in body["data"]["result"] for ts, v in s["values"]]
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
    # checkout=clean: a manual gate on a dirty checkout built the edited checks, not HEAD's
    gates = records.find("gate", [f"head={head}", "result=pass", "checkout=clean"])
    fleet = fleet_hosts()
    for g in gates:
        if g["_host"] is not None and g["_host"] not in fleet:
            print(f"gate ran in {g['_host'] or 'a stream without a host label'}: not counted (not a fleet host's own stream)")
    gates = [g for g in gates if g["_host"] is None or g["_host"] in fleet]
    if not gates:
        raise Unreadable(f"no passing gate record on a clean checkout of {head[:12]} from a fleet host: its gate has not "
                         "passed, ran only on a dirty checkout or in a guest, or its records are not in the window")
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
    ap.add_argument("--loki", help="Loki's base URL (default: PLATFORM_LOKI_URL, else platform-record.sh's default)")
    ap.add_argument("--spool", nargs="+")
    a = ap.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", a.head):
        print("deferred-checks: HEAD must be a full 40-character sha (the records' head=)", file=sys.stderr)
        sys.exit(2)
    try:
        if not a.spool and not a.loki:
            a.loki = default_loki()
        covered, waiting = verdict(Records(a), a.head)
    except (Unreadable, OSError) as e:
        # a missing spool or platform-record.sh is "cannot say" (2), never "waiting" (1)
        print(f"deferred-checks: cannot say: {e}", file=sys.stderr)
        sys.exit(2)
    for owner, check, how in covered:
        print(f"ok       {owner}:{check} ({how})")
    for owner, check, drv in waiting:
        print(f"waiting  {owner}:{check}: no built, present, fetched or expected-fail record from {owner} for drv {drv}")
    if not covered and not waiting:
        print(f"deferred-checks: the passing gate on {a.head[:12]} deferred nothing")
    sys.exit(1 if waiting else 0)


if __name__ == "__main__":
    main()
