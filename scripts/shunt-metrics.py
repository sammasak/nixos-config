#!/usr/bin/env python3
"""Shunt metrics: what the skills repo's Shunt hooks (shunt-read, shunt-bash, shunt-spill) and the bulk-read
delegation they redirect to decided in the last 24 h, from the owner's Claude Code hook log
($XDG_STATE_HOME/claude-hooks/<UTC date>.jsonl, which the skills repo's hooks/lib/log.sh appends), as one
Prometheus textfile. Counts and sums only: no session id, path, command or excerpt leaves the process; the only labels
are hook and result from fixed sets (a result outside its hook's set is "other"), kind, quantile and status.

The sizes are the hooks' own: shunt-read and shunt-bash estimate the tokens a read would put in context (0 for a
decision made before it measured, such as mode or source), shunt-spill counts the output's chars and the excerpt's.
"Returned" is what the session got: a redirected read returns nothing, a spilled output its excerpt. That is a
context-volume proxy, not billed tokens, and a bypass (the same file read again after its redirect) undoes the
saving its redirect showed, so it is reported apart.

A day with no Shunt record writes no event series, only the collector's line and file counts: idle is a known
count of lines, not a fabricated zero. The newest record's timestamp per hook carries over from the previous file
when the window holds none, so a hook that stopped logging shows its age. A run that fails writes
shunt_collector_failed 1 and keeps the previous success and last-record timestamps. Exits 0 whenever it could write
the file. Identical lines are not merged: two decisions in the same second can log the same line.

Usage: shunt-metrics.py --out FILE [--log-dir DIR] [--hours 24]
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
    "shunt_hook_duration_ms": "A Shunt hook's own run time in the window, by quantile.",
    "shunt_last_record_timestamp_seconds": "Unix time of the hook's newest record, carried over while the window holds none.",
    "shunt_collector_lines": "Hook log lines in the window's files: shunt (a counted record), other (another hook or outside the window), malformed, overlong, partial (an unterminated last line) or over_cap.",
    "shunt_collector_files": "The window's day files: read, missing, refused (a link or not a regular file) or too_large.",
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
LINE_STATUS = ("shunt", "other", "malformed", "overlong", "partial", "over_cap")
FILE_STATUS = ("read", "missing", "refused", "too_large")
QUANTILES = (0.5, 0.95)
# a busy day logs some 500 records of about 200 bytes; these keep a run well inside the unit's MemoryMax
LINE_MAX = 64 * 1024
FILE_MAX = 64 * 1024 * 1024
RECORDS_MAX = 200_000
DEADLINE_SECONDS = 60  # the unit's TimeoutStartSec is above this
TS_RE = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")


class Out:
    def __init__(self) -> None:
        self.lines: dict[str, list[str]] = {}

    def add(self, name: str, value: float, **labels: str) -> None:
        assert name in METRICS, f"{name} is not in METRICS"
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
    durations: dict[str, list[int]] = field(default_factory=dict)
    last: dict[str, float] = field(default_factory=dict)
    lines: dict[str, int] = field(default_factory=lambda: dict.fromkeys(LINE_STATUS, 0))
    files: dict[str, int] = field(default_factory=lambda: dict.fromkeys(FILE_STATUS, 0))
    kept: int = 0


def quantile(xs: list[int], q: float) -> float:
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def count(rec: dict[str, object], key: str) -> int:
    """A size field as the hooks write it, a non-negative int; anything else counts 0."""
    v = rec.get(key)
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


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
    if hook not in RESULTS or not since <= ts <= now:
        return "other"
    if t.kept >= RECORDS_MAX:
        return "over_cap"
    t.kept += 1
    raw = rec.get("result")
    result = raw if isinstance(raw, str) and raw in RESULTS[hook] else "other"
    t.events[hook, result] = t.events.get((hook, result), 0) + 1
    d = rec.get("duration_ms")
    if isinstance(d, int) and not isinstance(d, bool) and d >= 0:
        t.durations.setdefault(hook, []).append(d)
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
    return "shunt"


def day_files(log_dir: str, since: float, now: float) -> list[str]:
    """The day files the window spans, oldest first: the hooks name each by its UTC date."""
    days, day = [], int(since // 86400)
    while day <= now // 86400:
        days.append(os.path.join(log_dir, time.strftime("%Y-%m-%d.jsonl", time.gmtime(day * 86400))))
        day += 1
    return days


def lines_of(path: str, t: Tally, deadline: float) -> Iterator[bytes]:
    """The file's whole lines, never through a link or from anything but a regular file (O_NONBLOCK: a FIFO cannot
    hold the open); a line over LINE_MAX and an unterminated last line are counted, not returned."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
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
        if st.st_size > FILE_MAX:
            t.files["too_large"] += 1
            return
        t.files["read"] += 1
        overlong = False
        while raw := fh.readline(LINE_MAX):
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


def scan(log_dir: str, since: float, now: float, deadline: float) -> Tally:
    t = Tally()
    for path in day_files(log_dir, since, now):
        for raw in lines_of(path, t, deadline):
            try:
                rec = json.loads(raw)
            except (ValueError, RecursionError):
                t.lines["malformed"] += 1
                continue
            t.lines[add_record(t, rec, since, now)] += 1
    return t


def previous(path: str) -> tuple[float | None, dict[str, float]]:
    """The last file's success timestamp and newest-record timestamps by hook."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None, {}
    ok = re.search(r"^shunt_collector_success_timestamp_seconds (\S+)$", text, re.MULTILINE)
    # a corrupt file is no previous one: raising here would fail every later run
    try:
        last = {m[1]: float(m[2]) for m in re.finditer(
            r'^shunt_last_record_timestamp_seconds\{hook="([a-z-]+)"\} (\S+)$', text, re.MULTILINE) if m[1] in RESULTS}
        return (float(ok[1]) if ok else None), last
    except ValueError:
        return None, {}


def render(t: Tally | None, success: float | None, last: dict[str, float]) -> Out:
    """The textfile for a run's tally, or for a failed run (None) the previous timestamps alone."""
    out = Out()
    if t is not None:
        for (hook, result), n in sorted(t.events.items()):
            out.add("shunt_events", n, hook=hook, result=result)
        for (hook, kind), n in sorted(t.tokens.items()):
            out.add("shunt_read_tokens", n, hook=hook, kind=kind)
        if any(hook == "shunt-spill" for hook, _ in t.events):
            for kind, n in t.chars.items():
                out.add("shunt_spill_chars", n, kind=kind)
        for hook, ds in sorted(t.durations.items()):
            for q in QUANTILES:
                out.add("shunt_hook_duration_ms", quantile(ds, q), hook=hook, quantile=str(q))
        last = {**last, **{h: max(ts, last.get(h, ts)) for h, ts in t.last.items()}}
    for hook, ts in sorted(last.items()):
        out.add("shunt_last_record_timestamp_seconds", ts, hook=hook)
    if t is not None:
        for status, n in t.lines.items():
            out.add("shunt_collector_lines", n, status=status)
        for status, n in t.files.items():
            out.add("shunt_collector_files", n, status=status)
    if success is not None:
        out.add("shunt_collector_success_timestamp_seconds", success)
    out.add("shunt_collector_failed", 1 if t is None else 0)
    return out


def default_log_dir() -> str:
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "claude-hooks")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--list", action="store_true")
    p.add_argument("--out")
    p.add_argument("--log-dir", default=default_log_dir())
    p.add_argument("--hours", type=float, default=24)
    a = p.parse_args(argv)
    if a.list:
        print("\n".join(METRICS))
        return 0
    if not a.out:
        p.error("--out is required")
    now = time.time()
    success, last = previous(a.out)
    t: Tally | None
    try:
        t = scan(a.log_dir, now - a.hours * 3600, now, time.monotonic() + DEADLINE_SECONDS)
        success = now
    # any error, an unexpected log shape included, costs this run its update and nothing else
    except Exception as e:  # noqa: BLE001
        print(f"shunt-metrics: the scan failed, only the previous timestamps are kept: {type(e).__name__}",
              file=sys.stderr)
        t = None
    tmp = f"{a.out}.tmp"
    with open(tmp, "w") as f:
        f.write(render(t, success, last).text())
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
