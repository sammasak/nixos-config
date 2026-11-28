#!/usr/bin/env python3
"""Shunt metrics: what the skills repo's Shunt hooks (shunt-read, shunt-bash, shunt-spill) and the bulk-read
delegation they redirect to decided in the last 24 h, from the owner's Claude Code hook log
($XDG_STATE_HOME/claude-hooks/<UTC date>.jsonl, which the skills repo's hooks/lib/log.sh appends), as one
Prometheus textfile. Counts and sums only: no session id, path, command or excerpt leaves the process; the only labels
are hook and result from fixed sets (a result outside its hook's set is "other"), kind, quantile and status, and on
every series shunt (on or off, the declared sam.claude.bulkReader.enable from the host's argv) and, for a guest, worker.

The sizes are the hooks' own: shunt-read and shunt-bash estimate the tokens a read would put in context (0 for a
decision made before it measured, such as mode or source), shunt-spill counts the output's chars and the excerpt's.
"Returned" is what the session got: a redirected read returns nothing, a spilled output its excerpt. That is a
context-volume proxy, not billed tokens, and a bypass (the same file read again after its redirect) undoes the
saving its redirect showed, so it is reported apart. bulk-read's child tokens and cost are what its records report.
validate-bash logs every Bash call, Shunt on or off: its count and newest timestamp are the activity both compare by.

A day with no Shunt record writes no event series, only the sums (0) and the collector's line and file counts: idle
is a known count of lines, not a fabricated zero per result. The newest record's timestamp per hook carries over from the previous file
when the window holds none, so a hook that stopped logging shows its age. A run that fails writes
shunt_collector_failed 1 and keeps the previous success and last-record timestamps. Exits 0 whenever it could write
the file. Identical lines are not merged: two decisions in the same second can log the same line.

With --worker, a dev-environment guest's log instead, `<state-dir>/<name>/home/.local/state/claude-hooks`, which the
guest controls: no directory on that path and no day file is opened through a link. A pool slot's home is reset every
task turn and moved to `<state-dir>/.trash/<name>-YYYYMMDD-HHMMSS` (local time; modules/workers/core.nix), so the
window also covers the trashed homes named so whose trash time is inside it (an hour's slack for a clock change),
newest first and at most TRASH_MAX of them per run (shunt_collector_homes over_cap counts the rest), under the same
link, day-file and size rules. The live home comes first, then archived homes; within each, newest day first. A shared
WORKER_BYTES_MAX snapshot budget and WORKER_CHUNKS_MAX readline budget cover all day files. A file too big for the
remaining byte budget is skipped; a file cut short by the chunk budget is incomplete. Both count as over_cap.
A trashed day file last written before the window is stale. Nonzero cap counts mean incomplete coverage.
One record found in two homes counts once: across homes a record (its line as the hook wrote it, the timestamp among
its fields) counts as often as the home holding it most often, so identical lines within one home still count apart;
a copy is a duplicate line, and a new in-window Shunt or Bash key past KEYS_MAX is over_cap. A missing log directory
counts as a missing home; missing day files after a successful directory open count as missing files.

Usage: shunt-metrics.py --out FILE --shunt on|off [--log-dir DIR] [--hours 24]
       shunt-metrics.py --out FILE --shunt on|off --state-dir DIR --worker NAME [--hours 24]
       shunt-metrics.py --list   (the metric names it can emit, one per line)"""
import argparse
import json
import os
import re
import stat
import sys
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timezone

METRICS = {
    "shunt_events": "Shunt hook decisions, by hook and result. A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.",
    "shunt_read_tokens": "Tokens the read hooks estimated: seen (every decision), returned (all but redirects) and bypassed (re-reads let through after a redirect, a saving undone; absent until one happens). A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.",
    "shunt_spill_chars": "Bash output chars: seen (every spill decision) and returned (the excerpt of a spilled output, the whole of any other). A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.",
    "shunt_bulk_read_tokens": "Tokens bulk-read's child model reported (input, output, cache_read, cache_creation), summed over the window's delegations; a record without usage adds none. A 24 h rolling sum, refreshed every 15 min.",
    "shunt_bulk_read_cost_usd": "The cost bulk-read's child model reported, summed over the window's delegations. A 24 h rolling sum, refreshed every 15 min.",
    "shunt_bash_calls": "validate-bash records in the window: the agent's Bash calls, logged with Shunt on or off. A 24 h rolling sum, refreshed every 15 min.",
    "shunt_bash_last_call_timestamp_seconds": "Unix time of the newest validate-bash record (the agent's last Bash call), carried over while the window holds none.",
    "shunt_hook_duration_ms": "A Shunt hook's own run time in the window, by quantile.",
    "shunt_hook_time_ms": "A hook's run time summed over the window: the Shunt hooks, and validate-bash, which runs with Shunt on or off, so ms per Bash call compares the two. A 24 h rolling sum, refreshed every 15 min.",
    "shunt_last_record_timestamp_seconds": "Unix time of the hook's newest record, carried over while the window holds none.",
    "shunt_collector_lines": "Hook log lines in the window's files: shunt (a counted record), other (another hook or outside the window), malformed, overlong, partial (an unterminated last line), over_cap (past the Shunt record limit or a guest's Shunt/Bash key limit) or duplicate (a guest's record already counted from another of its homes).",
    "shunt_collector_files": "The window's day files: read, missing, refused (a link or not a regular file), too_large; for guests also stale (archived mtime before window) or over_cap (omitted or incomplete due to shared scan budgets).",
    "shunt_collector_homes": "A guest's live and in-window trashed homes: read (log directory opened), missing (no log directory), refused (unsafe path) or over_cap (past TRASH_MAX).",
    "shunt_collector_success_timestamp_seconds": "Unix time the collector last read the log without error.",
    "shunt_collector_failed": "1 when this run failed (an error or the run deadline), else 0.",
}
GATES = frozenset({"bypass", "nostate", "redirect", "mode", "subagent", "allow", "targeted", "private", "secret",
                   "sensitive", "unparsed"})
# the results the skills pin's Shunt hooks and its bulk-read script log
RESULTS = {
    "shunt-read": GATES | {"explicit", "instructions", "nontext", "source"},
    "shunt-bash": GATES | {"compound", "follow"},
    "shunt-spill": frozenset({"spilled", "small", "background", "disabled", "error", "interrupted", "printer",
                              "subagent"}),
    "bulk-read": frozenset({"ok", "auth", "budget", "empty", "error", "invalid", "model_unavailable", "non_json",
                            "output_limit", "private", "rate_limited", "secret", "sensitive", "timeout"}),
}
READ_HOOKS = ("shunt-read", "shunt-bash")
# bulk-read.sh's usage fields, by kind
CHILD_TOKENS = {"input": "input_tokens", "output": "output_tokens", "cache_read": "cache_read_input_tokens",
                "cache_creation": "cache_creation_input_tokens"}
BASH_HOOK = "validate-bash"
LINE_STATUS = ("shunt", "other", "malformed", "overlong", "partial", "over_cap", "duplicate")
FILE_STATUS = ("read", "missing", "refused", "too_large")
HOME_STATUS = ("read", "missing", "refused", "over_cap")
QUANTILES = (0.5, 0.95)
# a busy day logs some 500 records of about 200 bytes; these keep a run well inside the unit's MemoryMax
LINE_MAX = 64 * 1024
FILE_MAX = 64 * 1024 * 1024
# Keep the total input of a worker scan to one maximum-sized day file, not TRASH_MAX times FILE_MAX.
WORKER_BYTES_MAX = FILE_MAX
# Bytes alone do not bound JSON decode attempts on files full of very short/malformed lines.
WORKER_CHUNKS_MAX = 200_000
RECORDS_MAX = 200_000
# a guest's in-window records remembered to count each once across its homes, some 100 turns of 500; past it a record
# is over_cap
KEYS_MAX = 50_000
# a slot's turns in 24 h: 36 on acer's pool1 on 26 Nov, under 120 on any slot
TRASH_MAX = 200
# a trash name is local time: a clock change moves it by up to an hour
TRASH_SLACK = 3600
# a guest writes its own log: a larger int would overflow the float the textfile prints and fail every run for 24 h
INT_MAX = 2**53
DEADLINE_SECONDS = 60  # the unit's TimeoutStartSec is above this
TS_RE = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
WORKER_RE = re.compile(r"[a-z][a-z0-9-]{0,10}")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Out:
    def __init__(self, **labels: str) -> None:
        self.lines: dict[str, list[str]] = {}
        self.labels = labels

    def add(self, name: str, value: float, **labels: str) -> None:
        assert name in METRICS, f"{name} is not in METRICS"
        labels = {**self.labels, **labels}
        lab = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        self.lines.setdefault(name, []).append(f"{name}{{{lab}}} {value:.15g}" if lab else f"{name} {value:.15g}")

    def text(self) -> str:
        body = []
        for name, rows in self.lines.items():
            body += [f"# HELP {name} {METRICS[name]}", f"# TYPE {name} gauge", *rows]
        return "\n".join(body) + "\n"


@dataclass
class Tally:
    events: dict[tuple[str, str], int] = field(default_factory=dict)
    tokens: dict[tuple[str, str], int] = field(default_factory=dict)
    chars: dict[str, int] = field(default_factory=lambda: {"seen": 0, "returned": 0})
    child_tokens: dict[str, int] = field(default_factory=lambda: dict.fromkeys(CHILD_TOKENS, 0))
    cost: float = 0.0
    bash_calls: int = 0
    durations: dict[str, list[int]] = field(default_factory=dict)
    hook_ms: dict[str, int] = field(default_factory=lambda: {BASH_HOOK: 0})
    last: dict[str, float] = field(default_factory=dict)
    lines: dict[str, int] = field(default_factory=lambda: dict.fromkeys(LINE_STATUS, 0))
    files: dict[str, int] = field(default_factory=lambda: dict.fromkeys(FILE_STATUS, 0))
    homes: dict[str, int] | None = None
    kept: int = 0
    remaining_bytes: int | None = None  # only worker scans; charged from fstat before reading any line
    remaining_chunks: int | None = None  # readline calls that return nonempty data


def quantile(xs: list[int], q: float) -> float:
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def count(rec: dict[str, object], key: str) -> int:
    """A size field as the hooks write it, a non-negative int up to INT_MAX; anything else counts 0."""
    v = rec.get(key)
    return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= INT_MAX else 0


def stamp(v: object) -> float | None:
    if not isinstance(v, str) or not TS_RE.fullmatch(v):
        return None
    try:
        return datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def add_record(t: Tally, rec: object, since: float, now: float) -> str:
    """One parsed line into `t`; returns its line status."""
    if not isinstance(rec, dict):
        return "malformed"
    hook, ts = rec.get("hook"), stamp(rec.get("ts"))
    if not isinstance(hook, str) or ts is None:
        return "malformed"
    if not since <= ts <= now:
        return "other"
    d = rec.get("duration_ms")
    ms = d if isinstance(d, int) and not isinstance(d, bool) and 0 <= d <= INT_MAX else None
    if hook == BASH_HOOK:
        t.bash_calls += 1
        t.hook_ms[hook] += ms or 0
        t.last[hook] = max(t.last.get(hook, ts), ts)
        return "other"
    if hook not in RESULTS:
        return "other"
    if t.kept >= RECORDS_MAX:
        return "over_cap"
    t.kept += 1
    raw = rec.get("result")
    result = raw if isinstance(raw, str) and raw in RESULTS[hook] else "other"
    t.events[hook, result] = t.events.get((hook, result), 0) + 1
    if ms is not None:
        t.durations.setdefault(hook, []).append(ms)
        t.hook_ms[hook] = t.hook_ms.get(hook, 0) + ms
    t.last[hook] = max(t.last.get(hook, ts), ts)
    if hook in READ_HOOKS:
        tok = count(rec, "tokens")
        for kind, on in (("seen", True), ("returned", result != "redirect"), ("bypassed", result == "bypass")):
            if on:
                t.tokens[hook, kind] = t.tokens.get((hook, kind), 0) + tok
    elif hook == "shunt-spill":
        chars = count(rec, "chars")
        t.chars["seen"] += chars
        t.chars["returned"] += count(rec, "excerpt_chars") if result == "spilled" else chars
    elif hook == "bulk-read":
        for kind, key in CHILD_TOKENS.items():
            t.child_tokens[kind] += count(rec, key)
        cost = rec.get("cost_usd")
        if isinstance(cost, (int, float)) and not isinstance(cost, bool) and 0 <= cost < 1e6:
            t.cost += cost
    return "shunt"


def day_files(since: float, now: float) -> list[str]:
    """The day files the window spans, oldest first: the hooks name each by its UTC date."""
    days, day = [], int(since // 86400)
    while day <= now // 86400:
        days.append(time.strftime("%Y-%m-%d.jsonl", time.gmtime(day * 86400)))
        day += 1
    return days


def open_log_dir(parts: list[str], base: int | None = None) -> int | None:
    """The log directory's fd, each component opened from its parent's (the first from `base` when given) with
    O_NOFOLLOW; None when one below the first is missing. A link or non-directory on the path raises OSError."""
    fd = os.open(parts[0], DIR_FLAGS, dir_fd=base)
    try:
        for part in parts[1:]:
            nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
    except FileNotFoundError:
        os.close(fd)
        return None
    except BaseException:
        os.close(fd)
        raise
    return fd


def lines_of(name: str, dir_fd: int | None, t: Tally, deadline: float, written_since: float | None = None
             ) -> Iterator[bytes]:
    """The file's whole lines, never through a link or from anything but a regular file (O_NONBLOCK: a FIFO cannot
    hold the open); a line over LINE_MAX and an unterminated last line are counted, not returned. A file last
    modified before `written_since` is stale. Worker scans charge the file's snapshot size before reading; don't
    parse data appended after fstat, or a growing guest file could bypass the shared budget."""
    if dir_fd is None:
        t.files["missing"] += 1
        return
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dir_fd)
    except FileNotFoundError:
        t.files["missing"] += 1
        return
    except OSError:
        t.files["refused"] += 1
        return
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            t.files["refused"] += 1
            return
        if written_since is not None and st.st_mtime < written_since:
            t.files["stale"] += 1
            return
        if st.st_size > FILE_MAX:
            t.files["too_large"] += 1
            return
        left = None
        if t.remaining_bytes is not None:
            if st.st_size > t.remaining_bytes or (st.st_size and t.remaining_chunks == 0):
                t.files["over_cap"] += 1
                return
            t.remaining_bytes -= st.st_size
            left = st.st_size
        t.files["read"] += 1
        overlong = False
        while left is None or left > 0:
            if t.remaining_chunks == 0:
                # A partially read file is not complete. Retain the useful observations and expose the cap.
                t.files["read"] -= 1
                t.files["over_cap"] += 1
                return
            raw = fh.readline(LINE_MAX if left is None else min(LINE_MAX, left))
            if not raw:
                break
            if left is not None:
                left -= len(raw)
            if t.remaining_chunks is not None:
                t.remaining_chunks -= 1
            if time.monotonic() > deadline:
                raise TimeoutError("run deadline reached")
            if not raw.endswith(b"\n"):
                if len(raw) == LINE_MAX:
                    overlong = True
                    continue
                # the end of the file: a hook still writing its line, or the tail of an overlong one
                t.lines["overlong" if overlong else "partial"] += 1
                overlong = False
                continue
            if overlong:
                overlong = False
                t.lines["overlong"] += 1
                continue
            yield raw
        if overlong:
            t.lines["overlong"] += 1


def read_dir(t: Tally, dir_fd: int | None, since: float, now: float, deadline: float,
             seen: dict[int, int] | None = None, written_since: float | None = None) -> None:
    """The window's records in one log directory into `t`. With `seen` (a record's key to the most times one home
    held it so far), a record no more frequent here than in an earlier home is a duplicate."""
    mine: dict[int, int] = {}
    days = day_files(since, now)
    for name in reversed(days) if seen is not None else days:
        for raw in lines_of(name, dir_fd, t, deadline, written_since):
            try:
                rec = json.loads(raw)
                key = None
                if seen is not None and isinstance(rec, dict):
                    hook = rec.get("hook")
                    counted = isinstance(hook, str) and (hook == BASH_HOOK or hook in RESULTS)
                    ts = stamp(rec.get("ts")) if counted else None
                    if ts is not None and since <= ts <= now:
                        key = hash(raw)
            except (ValueError, RecursionError):
                t.lines["malformed"] += 1
                continue
            if seen is not None and key is not None:
                if key not in seen and len(seen) >= KEYS_MAX:
                    t.lines["over_cap"] += 1
                    continue
                n = mine[key] = mine.get(key, 0) + 1
                if n <= seen.get(key, 0):
                    t.lines["duplicate"] += 1
                    continue
                seen[key] = n
            t.lines[add_record(t, rec, since, now)] += 1


def scan(log_dir: list[str], since: float, now: float, deadline: float) -> Tally:
    """The window's records under the directory `log_dir` names (its path components, the first absolute)."""
    t = Tally()
    try:
        dir_fd = open_log_dir(log_dir)
    except FileNotFoundError:
        dir_fd = None
    except OSError:
        # a link or non-directory on the path: every day file refused unread
        t.files["refused"] += len(day_files(since, now))
        return t
    try:
        read_dir(t, dir_fd, since, now, deadline)
    finally:
        if dir_fd is not None:
            os.close(dir_fd)
    return t


def trashed(names: list[str], worker: str, since: float) -> list[str]:
    """The worker's trashed homes among `names` whose trash time is inside the window, newest first."""
    pat = re.compile(re.escape(worker) + r"-(\d{8}-\d{6})")
    homes = []
    for name in names:
        if not (m := pat.fullmatch(name)):
            continue
        try:
            at = time.mktime(time.strptime(m[1], "%Y%m%d-%H%M%S"))
        except (ValueError, OverflowError):
            continue
        if at >= since - TRASH_SLACK:
            homes.append((m[1], name))
    return [name for _, name in sorted(homes, reverse=True)]


def scan_worker(state_dir: str, worker: str, since: float, now: float, deadline: float) -> Tally:
    """The guest's live home and its trashed homes inside the window, each record counted once."""
    homes = dict.fromkeys(HOME_STATUS, 0)
    t = Tally(homes=homes, remaining_bytes=WORKER_BYTES_MAX, remaining_chunks=WORKER_CHUNKS_MAX)
    t.files.update(stale=0, over_cap=0)
    seen: dict[int, int] = {}
    log = ["home", ".local", "state", "claude-hooks"]

    def home(parts: list[str], base: int | None, written_since: float | None) -> None:
        try:
            fd = open_log_dir(parts, base)
        except FileNotFoundError:
            fd = None
        except OSError:
            homes["refused"] += 1
            t.files["refused"] += len(day_files(since, now))
            return
        homes["read" if fd is not None else "missing"] += 1
        try:
            read_dir(t, fd, since, now, deadline, seen, written_since)
        finally:
            if fd is not None:
                os.close(fd)

    home([state_dir, worker, *log], None, None)
    try:
        state = os.open(state_dir, DIR_FLAGS)
    except OSError:
        return t
    try:
        trash = os.open(".trash", DIR_FLAGS, dir_fd=state)
    except FileNotFoundError:
        return t
    except OSError:
        # a .trash that is a link: none of its homes read
        homes["refused"] += 1
        return t
    finally:
        os.close(state)
    try:
        names = trashed(os.listdir(trash), worker, since)
        homes["over_cap"] += max(0, len(names) - TRASH_MAX)
        for name in names[:TRASH_MAX]:
            home([name, *log], trash, since)
    finally:
        os.close(trash)
    return t


def previous(path: str) -> tuple[float | None, dict[str, float]]:
    """The last file's success timestamp and newest-record timestamps by hook."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None, {}
    ok = re.search(r"^shunt_collector_success_timestamp_seconds(?:\{[^}]*\})? (\S+)$", text, re.MULTILINE)
    bash = re.search(r"^shunt_bash_last_call_timestamp_seconds(?:\{[^}]*\})? (\S+)$", text, re.MULTILINE)
    # a corrupt file is no previous one: raising here would fail every later run
    try:
        last = {m[1]: float(m[2]) for m in re.finditer(
            r'^shunt_last_record_timestamp_seconds\{hook="([a-z-]+)"[^}]*\} (\S+)$', text, re.MULTILINE)
            if m[1] in RESULTS}
        if bash:
            last[BASH_HOOK] = float(bash[1])
        return (float(ok[1]) if ok else None), last
    except ValueError:
        return None, {}


def render(t: Tally | None, success: float | None, last: dict[str, float], **labels: str) -> Out:
    """The textfile for a run's tally, or for a failed run (None) the previous timestamps alone; `labels` on every
    series."""
    out = Out(**labels)
    if t is not None:
        for (hook, result), n in sorted(t.events.items()):
            out.add("shunt_events", n, hook=hook, result=result)
        tokens = {**{(h, k): 0 for h in READ_HOOKS for k in ("seen", "returned")}, **t.tokens}
        for (hook, kind), n in sorted(tokens.items()):
            out.add("shunt_read_tokens", n, hook=hook, kind=kind)
        for kind, n in t.chars.items():
            out.add("shunt_spill_chars", n, kind=kind)
        for kind, n in t.child_tokens.items():
            out.add("shunt_bulk_read_tokens", n, kind=kind)
        out.add("shunt_bulk_read_cost_usd", round(t.cost, 6))
        out.add("shunt_bash_calls", t.bash_calls)
        for hook, ds in sorted(t.durations.items()):
            for q in QUANTILES:
                out.add("shunt_hook_duration_ms", quantile(ds, q), hook=hook, quantile=str(q))
        for hook, ms in sorted(t.hook_ms.items()):
            out.add("shunt_hook_time_ms", ms, hook=hook)
        last = {**last, **{h: max(ts, last.get(h, ts)) for h, ts in t.last.items()}}
    for hook, ts in sorted(last.items()):
        if hook == BASH_HOOK:
            out.add("shunt_bash_last_call_timestamp_seconds", ts)
        else:
            out.add("shunt_last_record_timestamp_seconds", ts, hook=hook)
    if t is not None:
        for status, n in t.lines.items():
            out.add("shunt_collector_lines", n, status=status)
        for status, n in t.files.items():
            out.add("shunt_collector_files", n, status=status)
        for status, n in (t.homes or {}).items():
            out.add("shunt_collector_homes", n, status=status)
    if success is not None:
        out.add("shunt_collector_success_timestamp_seconds", success)
    out.add("shunt_collector_failed", 1 if t is None else 0)
    return out


def default_log_dir() -> str:
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "claude-hooks")


def worker_name(s: str) -> str:
    if not WORKER_RE.fullmatch(s):
        raise argparse.ArgumentTypeError(f"{s!r} is not an instance name ([a-z][a-z0-9-]{{0,10}})")
    return s


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--list", action="store_true")
    p.add_argument("--out")
    p.add_argument("--shunt", choices=("on", "off"), help="the declared sam.claude.bulkReader.enable of the log's agent")
    p.add_argument("--log-dir", default=default_log_dir())
    p.add_argument("--state-dir", help="the dev environments' state dir: <state-dir>/<worker>/home is a guest's home")
    p.add_argument("--worker", type=worker_name, help="a declared instance")
    p.add_argument("--hours", type=float, default=24)
    a = p.parse_args(argv)
    if a.list:
        print("\n".join(METRICS))
        return 0
    if not (a.out and a.shunt):
        p.error("--out and --shunt are required")
    if bool(a.worker) != bool(a.state_dir) or (a.state_dir and not os.path.isabs(a.state_dir)):
        p.error("--worker needs an absolute --state-dir, and --state-dir a --worker")
    labels = {"shunt": a.shunt, **({"worker": a.worker} if a.worker else {})}
    now = time.time()
    success, last = previous(a.out)
    t: Tally | None
    try:
        since, deadline = now - a.hours * 3600, time.monotonic() + DEADLINE_SECONDS
        t = (scan_worker(a.state_dir, a.worker, since, now, deadline) if a.worker
             else scan([os.path.abspath(a.log_dir)], since, now, deadline))
        success = now
    # any error, an unexpected log shape included, costs this run its update and nothing else
    except Exception as e:  # noqa: BLE001
        print(f"shunt-metrics: the scan failed, only the previous timestamps are kept: {type(e).__name__}",
              file=sys.stderr)
        t = None
    tmp = f"{a.out}.tmp"
    with open(tmp, "w") as f:
        f.write(render(t, success, last, **labels).text())
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
