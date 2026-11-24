#!/usr/bin/env python3
"""Ships each developer environment's platform records to Loki from the host (modules/workers/core.nix's
dev-env-records units). The guest writes them to a spool in its home (pkgs/platform-record/platform_record.py) and cannot reach
Loki itself; the host sets every label: job=platform, kind from the allow-list, host=<prefix>-<name>.

The guest owns everything under its home: no path component is followed through a link, the spool must be a regular
file and only its last MAX_READ bytes are read. Dropped and counted: a line naming a label key (job, kind, host) in
its own fields, a kind off the list, a line over MAX_LINE bytes, a time that is not ISO 8601 with an offset or is
ahead of now. Skipped: older than Loki takes. At most PER_RUN lines go per instance and run.

platform_record.py rewrites the spool (a new inode) on every record, so progress is by content: the hash and time of
the last line handled, kept under --progress (the unit's StateDirectory). Lines after that line go; when it is gone,
lines no older than it.

--metrics (the timer's run) writes, for node-exporter, each instance's lines still waiting after the run and when its
last run got through (Loki took the push, or nothing was waiting), labelled worker alone; --list prints their names.

--usage (nixos-config#494) pushes instead one host-made kind=usage line per instance: its container's cgroup counters
(cpu.stat usage_usec and user_usec, memory.current, memory.stat anon, memory.peak, the container's lifetime
high-water mark, never reset) and the system it runs (SYSTEM_PATH in its nixos-containers conf). No guest file is read,
and kind usage is not on the guests' allow-list, so a guest cannot write one."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

SPOOL = (".local", "state", "platform-records")
NAME = re.compile(r"[a-z][a-z0-9-]{0,10}")
# A guest line ships only if the whole of it parses, and what ships is rebuilt from the parse, never the guest's
# bytes: Loki's logfmt splits at any byte <= 0x20, unquotes and decodes \uXXXX, so a filter over the raw text missed
# forms Loki reads as another field. The grammar is what platform_record.py writes, `<date -Is> <kind>` then
# single-space key=value tokens, values in the characters real records use (paths, shas, drv names, comma lists)
STAMP = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:[+-]\d\d:\d\d|Z)"
# a key may not start with __: Loki keeps those names for its own (__error__, __line__)
KEY = re.compile(r"(?!__)[a-z_][a-z0-9_]*")
VALUE = re.compile(r"[A-Za-z0-9_.,:/-]*")
LINE = re.compile(rf"({STAMP}) ([a-z][a-z-]*) (\S+(?: \S+)*)")
# a stream label's name as a field would read, in Loki, as that label
LABELS = {"job", "kind", "host"}
# fields a consumer attributes a record by: a deploy's node, a deferred or built check's owner
SPEAKS_FOR = ("node", "owner")
DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
# O_NONBLOCK: a FIFO in the spool's place would otherwise hold the open until a writer comes
FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
MAX_LINE = 4096
MAX_READ = 2 * 1024 * 1024
PER_RUN = 500
# modules/homelab/loki.nix: reject_old_samples_max_age 168h, less an hour for a slow run; Loki also refuses lines
# from the future, and one such line would fail the whole push every run
TOO_OLD = 167 * 3600
TOO_NEW = 300
METRICS = {
    "homelab_guest_records_waiting_lines": "Spool lines of a worker's guest past the shipper's progress after its last run",
    "homelab_guest_records_shipped_timestamp_seconds": "When the shipper last got through a worker's waiting lines, 0 never",
}


class Refused(Exception):
    pass


def read_spool(base, name):
    """The spool's complete lines (from its last MAX_READ bytes), [] when there is none."""
    fds = []
    try:
        fd = base
        for part in (name, "home", *SPOOL[:-1]):
            try:
                fd = os.open(part, DIR, dir_fd=fd)
            except FileNotFoundError:
                return []
            except OSError as e:
                raise Refused(f"{part} is a link or not a directory ({e.strerror})") from e
            fds.append(fd)
        try:
            f = os.open(SPOOL[-1], FILE, dir_fd=fd)
        except FileNotFoundError:
            return []
        except OSError as e:
            raise Refused(f"{SPOOL[-1]} is a link or cannot be opened ({e.strerror})") from e
        fds.append(f)
        st = os.fstat(f)
        if not stat.S_ISREG(st.st_mode):
            raise Refused(f"{SPOOL[-1]} is not a regular file")
        start = max(0, st.st_size - MAX_READ)
        data = os.pread(f, MAX_READ, start)
    finally:
        for fd in fds:
            os.close(fd)
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]
    # the last piece is empty or a line still unterminated
    return lines[:-1]


def time_of(raw):
    try:
        t = datetime.fromisoformat(raw.split(b" ", 1)[0].decode("ascii"))
    except (ValueError, UnicodeDecodeError):
        return None
    return t.timestamp() if t.tzinfo is not None else None


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def fleet_name(value, fleet):
    """Does `value` name a fleet host: its hostname, or its flake attribute (lenovo for lenovo-21CB001PMX)?"""
    v = value.lower()
    return bool(v) and any(h == v or h.startswith(v + "-") for h in fleet)


def parse(raw):
    """(stamp, kind, [(key, value)]) when the whole line is the grammar, else the reason it is not."""
    if any(b < 0x20 or b > 0x7E for b in raw):
        return "not printable ASCII"
    text = raw.decode("ascii")
    if "\\" in text or '"' in text:
        return "a backslash or quote"
    m = LINE.fullmatch(text)
    if not m:
        return "not key=value tokens"
    fields, seen = [], set()
    for tok in m.group(3).split(" "):
        key, eq, value = tok.partition("=")
        if not eq or not KEY.fullmatch(key) or not VALUE.fullmatch(value):
            return "not key=value tokens"
        if key in seen:
            return "a duplicate key"
        seen.add(key)
        fields.append((key, value))
    return m.group(1), m.group(2), fields


def judge(raw, kinds, now, fleet=frozenset()):
    """(time, kind, body) to push, the body rebuilt from the parse, or the reason it is not pushed."""
    if len(raw) > MAX_LINE:
        return "oversize"
    parsed = parse(raw)
    if isinstance(parsed, str):
        return parsed
    stamp, kind, fields = parsed
    t = time_of(raw)
    if t is None:
        return "not key=value tokens"
    if t > now + TOO_NEW:
        return "ahead of now"
    if t < now - TOO_OLD:
        return "older than Loki takes"
    if kind not in kinds:
        return "unknown kind"
    if any(k in LABELS for k, _ in fields):
        return "a label key in its fields"
    if any(k in SPEAKS_FOR and fleet_name(v, fleet) for k, v in fields):
        return "names a fleet host in node= or owner="
    return t, kind, " ".join(f"{k}={v}" for k, v in fields)


def pending(lines, progress):
    if not progress:
        return lines
    for i in range(len(lines) - 1, -1, -1):
        if digest(lines[i]) == progress["hash"]:
            return lines[i + 1 :]
    return [l for l in lines if (time_of(l) or 0) >= progress["time"]]


def push(url, streams):
    body = json.dumps({"streams": streams}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10):
            return True
    except urllib.error.HTTPError as e:
        detail = e.read(300).decode("utf-8", "replace").strip()
        print(f"Loki answered {e.code}: {detail}", file=sys.stderr)
        # 400 is Loki refusing some entries and taking the rest: sending them again would fail every run
        return e.code == 400
    except OSError as e:
        print(f"Loki unreachable: {e}", file=sys.stderr)
        return False


def ship(base, name, args, kinds, fleet=frozenset()):
    """(shipped, lines still waiting)."""
    host = f"{args.prefix}-{name}"
    with open(os.path.join(args.progress, f"{name}.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = os.path.join(args.progress, f"{name}.json")
        try:
            with open(state) as f:
                progress = json.load(f)
        except FileNotFoundError:
            progress = None
        lines = read_spool(base, name)
        now = time.time()
        streams, dropped, sent, last, last_time = {}, {}, 0, None, progress["time"] if progress else 0
        todo, handled = pending(lines, progress), 0
        for raw in todo:
            if sent == PER_RUN:
                break
            v = judge(raw, kinds, now, fleet)
            last = raw
            handled += 1
            if isinstance(v, str):
                dropped[v] = dropped.get(v, 0) + 1
                t = time_of(raw)
                if t is not None and t <= now:
                    last_time = max(last_time, t)
                continue
            t, kind, body = v
            last_time = max(last_time, t)
            streams.setdefault(kind, []).append([str(int(t)) + "000000000", body])
            sent += 1
        if last is not None:
            labels = [{"stream": {"job": "platform", "kind": k, "host": host}, "values": v} for k, v in streams.items()]
            if labels and not push(args.url, labels):
                return False, len(todo)
            replace_text(state, json.dumps({"hash": digest(last), "time": last_time}))
            drops = ", ".join(f"{n} {why}" for why, n in sorted(dropped.items()))
            print(f"{name}: {sent} line(s) to Loki as host={host}" + (f"; not sent: {drops}" if drops else ""))
        replace_text(os.path.join(args.progress, f"{name}.shipped"), f"{now}\n")
        return True, len(todo) - handled


def replace_text(path, text):
    tmp = f"{path}.new"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def shipped_at(name, args):
    try:
        with open(os.path.join(args.progress, f"{name}.shipped")) as f:
            return float(f.read())
    except (OSError, ValueError):
        return 0


def write_metrics(path, waiting, args):
    """Every instance shipped or tried this run; one refused (a link, a FIFO) or failing has no series and fails the unit."""
    values = {"homelab_guest_records_waiting_lines": waiting,
              "homelab_guest_records_shipped_timestamp_seconds": {n: shipped_at(n, args) for n in waiting}}
    body = []
    for name, help_ in METRICS.items():
        body += [f"# HELP {name} {help_}", f"# TYPE {name} gauge"]
        body += [f'{name}{{worker="{w}"}} {v}' for w, v in sorted(values[name].items())]
    replace_text(path, "\n".join(body) + "\n")


STORE_PATH = re.compile(r"/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+")


def usage_body(name, args):
    """One kind=usage body for an instance, from host files only. OSError when its cgroup is not there (not running)."""
    d = os.path.join(args.cgroup, f"container@{name}.service")

    def read(f):
        with open(os.path.join(d, f)) as fh:
            return fh.read(65536)

    def table(text):
        return dict(line.split(None, 1) for line in text.splitlines() if " " in line)

    cpu, mem = table(read("cpu.stat")), table(read("memory.stat"))
    toplevel = "unknown"
    try:
        with open(os.path.join(args.containers, f"{name}.conf")) as f:
            for line in f.read(65536).splitlines():
                if line.startswith("SYSTEM_PATH=") and STORE_PATH.fullmatch(line[12:].strip()):
                    toplevel = line[12:].strip()
    except OSError:
        pass
    fields = {"cpu_usec": int(cpu["usage_usec"]), "user_usec": int(cpu["user_usec"]),
              "mem_current": int(read("memory.current")), "mem_anon": int(mem["anon"]),
              "mem_peak": int(read("memory.peak")), "toplevel": toplevel}
    return " ".join(f"{k}={v}" for k, v in fields.items())


def ship_usage(names, args):
    """One push of every running instance's usage line, each in its own host=<prefix>-<name> stream. An instance with no
    cgroup is stopped (paused, or between deploys): skipped and logged, not a failure. A cgroup that is there but
    cannot be read is one."""
    now, streams, ok, stopped = time.time(), [], True, []
    # no slice at all is a wrong path or a host without the environments' slice: every instance would read as stopped
    if not os.path.isdir(args.cgroup):
        print(f"usage: {args.cgroup} is not a directory; nothing read", file=sys.stderr)
        return False
    for name in names:
        if not os.path.isdir(os.path.join(args.cgroup, f"container@{name}.service")):
            stopped.append(name)
            continue
        try:
            body = usage_body(name, args)
        except (OSError, KeyError, ValueError) as e:
            print(f"{name}: no usage ({type(e).__name__}: {e})", file=sys.stderr)
            ok = False
            continue
        streams.append({"stream": {"job": "platform", "kind": "usage", "host": f"{args.prefix}-{name}"},
                        "values": [[str(int(now)) + "000000000", body]]})
    if streams and not push(args.url, streams):
        return False
    print(f"usage: {len(streams)} instance(s) to Loki" + (f"; not running, skipped: {', '.join(stopped)}" if stopped else ""))
    return ok


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--state-dir", required=True, help="the environments' state dir; <name>/home is a guest's home")
    p.add_argument("--progress", default=os.environ.get("STATE_DIRECTORY"), help="where progress is kept")
    p.add_argument("--prefix", required=True)
    p.add_argument("--url", required=True, help="Loki's push URL")
    p.add_argument("--kinds", required=True, help="comma-separated allow-list")
    p.add_argument("--fleet", default="", help="comma-separated fleet hostnames a guest line may not name in node= or owner=")
    p.add_argument("--usage", action="store_true", help="push each instance's cgroup usage, not its spool")
    p.add_argument("--cgroup", default="/sys/fs/cgroup/environments.slice", help="the slice holding container@<name>.service")
    p.add_argument("--containers", default="/etc/nixos-containers", help="where <name>.conf names SYSTEM_PATH")
    p.add_argument("--metrics", help="the node-exporter textfile to write")
    p.add_argument("names", nargs="*")
    if sys.argv[1:] == ["--list"]:
        print("\n".join(METRICS))
        return 0
    args = p.parse_args()
    if not args.progress:
        p.error("--progress or STATE_DIRECTORY is required")
    if args.usage:
        bad = [n for n in args.names if not NAME.fullmatch(n)]
        for n in bad:
            print(f"{n!r}: not an environment name", file=sys.stderr)
        return 0 if ship_usage([n for n in args.names if n not in bad], args) and not bad else 1
    kinds = set(args.kinds.split(","))
    fleet = frozenset(h.lower() for h in args.fleet.split(",") if h)
    base = os.open(args.state_dir, DIR)
    ok, waiting = True, {}
    # finally: a run that dies on one instance still replaces the last run's file, so no stale 0 hides a backlog
    try:
        for name in args.names:
            if not NAME.fullmatch(name):
                print(f"{name!r}: not an environment name", file=sys.stderr)
                ok = False
                continue
            try:
                shipped, waiting[name] = ship(base, name, args, kinds, fleet)
                ok = shipped and ok
            except Refused as e:
                print(f"{name}: not shipped, {e}", file=sys.stderr)
                ok = False
    finally:
        if args.metrics:
            write_metrics(args.metrics, waiting, args)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
