#!/usr/bin/env python3
"""One platform record (Grafana "Platform health"): a logfmt line to Loki's {job="platform"} stream, kept 720h
(loki.nix), and to a local spool. Kinds and their fields come from metrics/records.json.

Usage: platform-record KIND key=value...    record one line
       platform-record --status             print the retry backlog and the rejection counts as JSON

An unknown kind, an unknown field or a token that is not key=value exits 2 when PLATFORM_RECORD_STRICT=1 (tests and
gates). Otherwise it is reported on stderr and counted: the record is kept for a bad field or an unreadable schema and
dropped for an unknown kind, and the caller still exits 0, since a record is evidence and never breaks a deploy. A push
Loki did not take is kept in the retry spool and shipped on the next run. Labels are job, kind and this host only;
callers put no path or secret in a value. The line is the arguments joined by one space, as given
(scripts/test-platform-records.py)."""

import contextlib
import fcntl
import json
import os
import pathlib
import re
import sys
import time
import urllib.request
from collections.abc import Iterator
from datetime import datetime

# sam.fleet.loki.url (modules/core/fleet.nix): the Justfile runs this without Nix; scripts/test-fleet-contract.py
# holds the literal to the evaluated value
LOKI_DEFAULT = "http://192.168.10.137:3100"
SPOOL_LINES = 2000
RETRY_ENTRIES = 2000
DOWN_SECONDS = 300
FIELD = re.compile(r"([a-z_][a-z0-9_]*)=(.*)", re.DOTALL)

Entry = dict[str, str]


def warn(msg: str) -> None:
    print(f"platform-record: {msg}", file=sys.stderr)


def schema_path() -> pathlib.Path | None:
    """PLATFORM_RECORD_SCHEMA, else the package's copy, else the repo's metrics/records.json."""
    env = os.environ.get("PLATFORM_RECORD_SCHEMA")
    if env:
        return pathlib.Path(env)
    here = pathlib.Path(__file__).resolve()
    for p in (here.parents[1] / "share/platform-record/records.json", here.parents[2] / "metrics/records.json"):
        if p.is_file():
            return p
    return None


def load_kinds() -> dict[str, set[str]] | None:
    p = schema_path()
    try:
        kinds = json.loads(p.read_text())["kinds"] if p else None
        return {k: set(v["fields"]) for k, v in kinds.items()} if isinstance(kinds, dict) else None
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def problems(kind: str, args: list[str], kinds: dict[str, set[str]] | None) -> tuple[str | None, list[str]]:
    """(why the kind is refused, or None; why each field is wrong)"""
    if kinds is None:
        return None, ["no readable metrics/records.json, kind and fields unchecked"]
    if kind not in kinds:
        return f"unknown kind '{kind}'", []
    bad = []
    for a in args:
        m = FIELD.fullmatch(a)
        if not m:
            bad.append(f"'{a}' is not key=value")
        elif m[1] not in kinds[kind]:
            bad.append(f"unknown field '{m[1]}' for {kind}")
    return None, bad


@contextlib.contextmanager
def locked(spool: pathlib.Path) -> Iterator[None]:
    """One writer at a time for the spool, the retry spool and the counts."""
    with open(spool.with_name(spool.name + ".lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def replace(path: pathlib.Path, text: str) -> None:
    """A new file renamed over the old one (scripts/guest-records.py follows the spool by content, not inode)."""
    tmp = path.with_name(f"{path.name}.{os.getpid()}")
    tmp.write_text(text)
    tmp.replace(path)


def count(spool: pathlib.Path, **inc: int) -> None:
    p = spool.with_name(spool.name + ".counts")
    try:
        counts = json.loads(p.read_text()) if p.exists() else {}
    except ValueError:
        counts = {"unreadable_counts_reset": 1}
    for k, v in inc.items():
        counts[k] = counts.get(k, 0) + v
    replace(p, json.dumps(counts, sort_keys=True) + "\n")


def read_retry(spool: pathlib.Path) -> list[Entry]:
    p = spool.with_name(spool.name + ".retry")
    if not p.exists():
        return []
    entries = []
    for line in p.read_text().splitlines():
        with contextlib.suppress(ValueError):
            e = json.loads(line)
            if isinstance(e, dict) and all(isinstance(e.get(k), str) for k in ("ts", "kind", "host", "line")):
                entries.append({k: e[k] for k in ("ts", "kind", "host", "line")})
    return entries


def write_retry(spool: pathlib.Path, entries: list[Entry]) -> None:
    p = spool.with_name(spool.name + ".retry")
    if not entries:
        p.unlink(missing_ok=True)
        return
    dropped = len(entries) - RETRY_ENTRIES
    if dropped > 0:
        count(spool, retry_dropped=dropped)
        entries = entries[dropped:]
    replace(p, "".join(json.dumps(e, sort_keys=True) + "\n" for e in entries))


def push(url: str, entries: list[Entry]) -> bool:
    streams: dict[tuple[str, str], list[list[str]]] = {}
    for e in sorted(entries, key=lambda e: int(e["ts"])):
        streams.setdefault((e["kind"], e["host"]), []).append([e["ts"], e["line"]])
    body = {"streams": [{"stream": dict(job="platform", kind=k, host=h), "values": v} for (k, h), v in streams.items()]}
    req = urllib.request.Request(f"{url}/loki/api/v1/push", data=json.dumps(body, separators=(",", ":")).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            code: int = r.status
            return 200 <= code < 300
    except (OSError, ValueError):
        return False


def status(spool: pathlib.Path) -> int:
    p = spool.with_name(spool.name + ".counts")
    try:
        counts = json.loads(p.read_text()) if p.exists() else {}
    except ValueError:
        counts = {"unreadable": 1}
    print(json.dumps({"spool": str(spool), "retry_pending": len(read_retry(spool)), "counts": counts}, sort_keys=True))
    return 0


def main(argv: list[str]) -> int:
    xdg = os.environ.get("XDG_STATE_HOME") or f"{os.environ.get('HOME', '/')}/.local/state"
    spool = pathlib.Path(os.environ.get("PLATFORM_RECORD_SPOOL") or f"{xdg}/platform-records")
    if argv == ["--status"]:
        return status(spool)
    if not argv:
        warn("usage: platform-record KIND key=value... | --status")
        return 2
    kind, args = argv[0], argv[1:]
    strict = os.environ.get("PLATFORM_RECORD_STRICT") == "1"
    refused, bad = problems(kind, args, load_kinds())
    if strict and (refused or bad):
        warn("; ".join(([refused] if refused else []) + bad) + " (PLATFORM_RECORD_STRICT=1: nothing recorded)")
        return 2
    try:
        spool.parent.mkdir(parents=True, exist_ok=True)
        with locked(spool):
            if refused:
                warn(f"{refused}, nothing recorded")
                count(spool, unknown_kind=1)
                return 0
            for b in bad:
                warn(f"{b}; recorded anyway")
            if bad:
                count(spool, invalid_fields=len(bad))
            line = " ".join(args)
            old = spool.read_text().splitlines(keepends=True) if spool.exists() else []
            stamp = datetime.now().astimezone().isoformat(timespec="seconds")
            replace(spool, "".join((old + [f"{stamp} {kind} {line}\n"])[-SPOOL_LINES:]))
            entries = read_retry(spool) + [{"ts": str(time.time_ns()), "kind": kind, "host": os.uname().nodename,
                                            "line": line}]
            # a Loki that did not answer in the last 5 min is not tried again: a gate writes dozens of records, and a
            # dropped connection (a dev-environment guest, black-pi down) would otherwise cost each one its timeout
            down = spool.with_name(spool.name + ".loki-down")
            if down.exists() and time.time() - down.stat().st_mtime < DOWN_SECONDS:
                write_retry(spool, entries)
                warn(f"Loki was unreachable within 5 min; the {kind} record is only in {spool} "
                     f"({len(entries)} waiting to retry)")
                return 0
            if push(os.environ.get("PLATFORM_LOKI_URL") or LOKI_DEFAULT, entries):
                down.unlink(missing_ok=True)
                write_retry(spool, [])
                if len(entries) > 1:
                    count(spool, retried=len(entries) - 1)
            else:
                down.touch()
                write_retry(spool, entries)
                count(spool, push_failed=1)
                warn(f"Loki did not take the {kind} record; it is in {spool} ({len(entries)} waiting to retry)")
    except OSError as e:
        warn(f"the {kind} record could not be kept ({e})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
