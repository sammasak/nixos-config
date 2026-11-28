#!/usr/bin/env python3
"""The Shunt collector (scripts/shunt-metrics.py) on fixture hook logs. A window across UTC midnight: every hook's
results, a result outside its set (other), another hook, records just inside and outside the window and in the future,
a malformed, a non-object, a bad timestamp, an overlong and an unterminated last line, two identical lines; the
exported file is GOLDEN. No session id, path, excerpt or unknown result in the textfile. A missing log is idle: no
event series, its files counted missing. A link or FIFO day file is refused, an oversized one skipped, records past
RECORDS_MAX counted over_cap. A failed run writes collector_failed 1 and keeps its previous success and last-record
timestamps; a run with no record carries the last-record ones over. `--list` is METRICS; seeded: a name outside it is
refused. A 64 MiB day file stays under 3/4 of the unit's MemoryMax, a guest's of distinct records too. A guest (--worker): its series carry worker and
shunt, a link on its log path is refused, bad argv exits 2; with Shunt off it still exports its Bash calls and zero sums.
Its trashed homes (a slot's earlier turns): two inside the window add to the live one, one trashed before it and one of
another worker are not read, a record in both a live and a trashed home counts once, a linked trashed home or .trash
is refused, one past TRASH_MAX is over_cap; a total worker byte budget prioritizes the live/current files and is not extended
by file growth; a missing log directory or day file is counted, not a failed run.
The wiring, from the probe: imported on the devTools hosts with node-exporter, enabled on lenovo and acer; on lenovo the
unit reads the hook log read-only with --shunt on and node-exporter the dir; on acer the host says off and each guest's
unit passes its own declared switch, on for pool1 alone (its Read hook registered), off for the other slots; enabled off devTools, it
fails evaluation.

Usage: test-shunt-metrics.py [SCRIPT] (a mutated copy for a seed)."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
from typing import Any

import gate_probe
from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "scripts/shunt-metrics.py"
spec = importlib.util.spec_from_file_location("shunt_metrics", SCRIPT)
assert spec and spec.loader
sm: Any = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

NOW = 1795413600.0  # 2026-11-23T06:00:00Z
SINCE = NOW - 86400
SECRETS = ("SESSION-SECRET", "/home/u/SECRET-PATH", "EXCERPT-SECRET", "weird-RESULT")
GOLDEN = """\
# HELP shunt_events Shunt hook decisions, by hook and result. A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.
# TYPE shunt_events gauge
shunt_events{hook="bulk-read",result="ok",shunt="on"} 1
shunt_events{hook="bulk-read",result="timeout",shunt="on"} 1
shunt_events{hook="shunt-bash",result="compound",shunt="on"} 1
shunt_events{hook="shunt-bash",result="targeted",shunt="on"} 1
shunt_events{hook="shunt-read",result="allow",shunt="on"} 1
shunt_events{hook="shunt-read",result="bypass",shunt="on"} 1
shunt_events{hook="shunt-read",result="mode",shunt="on"} 1
shunt_events{hook="shunt-read",result="other",shunt="on"} 1
shunt_events{hook="shunt-read",result="redirect",shunt="on"} 2
shunt_events{hook="shunt-spill",result="background",shunt="on"} 1
shunt_events{hook="shunt-spill",result="small",shunt="on"} 2
shunt_events{hook="shunt-spill",result="spilled",shunt="on"} 1
# HELP shunt_read_tokens Tokens the read hooks estimated: seen (every decision), returned (all but redirects) and bypassed (re-reads let through after a redirect, a saving undone; absent until one happens). A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.
# TYPE shunt_read_tokens gauge
shunt_read_tokens{hook="shunt-bash",kind="returned",shunt="on"} 300
shunt_read_tokens{hook="shunt-bash",kind="seen",shunt="on"} 300
shunt_read_tokens{hook="shunt-read",kind="bypassed",shunt="on"} 9000
shunt_read_tokens{hook="shunt-read",kind="returned",shunt="on"} 9500
shunt_read_tokens{hook="shunt-read",kind="seen",shunt="on"} 27500
# HELP shunt_spill_chars Bash output chars: seen (every spill decision) and returned (the excerpt of a spilled output, the whole of any other). A 24 h rolling sum, refreshed every 15 min; for a longer period read it at 24 h steps, do not sum_over_time.
# TYPE shunt_spill_chars gauge
shunt_spill_chars{kind="seen",shunt="on"} 20200
shunt_spill_chars{kind="returned",shunt="on"} 4200
# HELP shunt_bulk_read_tokens Tokens bulk-read's child model reported (input, output, cache_read, cache_creation), summed over the window's delegations; a record without usage adds none. A 24 h rolling sum, refreshed every 15 min.
# TYPE shunt_bulk_read_tokens gauge
shunt_bulk_read_tokens{kind="input",shunt="on"} 5
shunt_bulk_read_tokens{kind="output",shunt="on"} 40
shunt_bulk_read_tokens{kind="cache_read",shunt="on"} 1000
shunt_bulk_read_tokens{kind="cache_creation",shunt="on"} 200
# HELP shunt_bulk_read_cost_usd The cost bulk-read's child model reported, summed over the window's delegations. A 24 h rolling sum, refreshed every 15 min.
# TYPE shunt_bulk_read_cost_usd gauge
shunt_bulk_read_cost_usd{shunt="on"} 0.0125
# HELP shunt_bash_calls validate-bash records in the window: the agent's Bash calls, logged with Shunt on or off. A 24 h rolling sum, refreshed every 15 min.
# TYPE shunt_bash_calls gauge
shunt_bash_calls{shunt="on"} 2
# HELP shunt_hook_duration_ms A Shunt hook's own run time in the window, by quantile.
# TYPE shunt_hook_duration_ms gauge
shunt_hook_duration_ms{hook="bulk-read",quantile="0.5",shunt="on"} 15000
shunt_hook_duration_ms{hook="bulk-read",quantile="0.95",shunt="on"} 19500
shunt_hook_duration_ms{hook="shunt-bash",quantile="0.5",shunt="on"} 25
shunt_hook_duration_ms{hook="shunt-bash",quantile="0.95",shunt="on"} 29.5
shunt_hook_duration_ms{hook="shunt-read",quantile="0.5",shunt="on"} 17.5
shunt_hook_duration_ms{hook="shunt-read",quantile="0.95",shunt="on"} 45
shunt_hook_duration_ms{hook="shunt-spill",quantile="0.5",shunt="on"} 10
shunt_hook_duration_ms{hook="shunt-spill",quantile="0.95",shunt="on"} 35.5
# HELP shunt_hook_time_ms A hook's run time summed over the window: the Shunt hooks, and validate-bash, which runs with Shunt on or off, so ms per Bash call compares the two. A 24 h rolling sum, refreshed every 15 min.
# TYPE shunt_hook_time_ms gauge
shunt_hook_time_ms{hook="bulk-read",shunt="on"} 30000
shunt_hook_time_ms{hook="shunt-bash",shunt="on"} 50
shunt_hook_time_ms{hook="shunt-read",shunt="on"} 130
shunt_hook_time_ms{hook="shunt-spill",shunt="on"} 65
shunt_hook_time_ms{hook="validate-bash",shunt="on"} 6
# HELP shunt_last_record_timestamp_seconds Unix time of the hook's newest record, carried over while the window holds none.
# TYPE shunt_last_record_timestamp_seconds gauge
shunt_last_record_timestamp_seconds{hook="bulk-read",shunt="on"} 1795410000
shunt_last_record_timestamp_seconds{hook="shunt-bash",shunt="on"} 1795410000
shunt_last_record_timestamp_seconds{hook="shunt-read",shunt="on"} 1795413600
shunt_last_record_timestamp_seconds{hook="shunt-spill",shunt="on"} 1795410000
# HELP shunt_bash_last_call_timestamp_seconds Unix time of the newest validate-bash record (the agent's last Bash call), carried over while the window holds none.
# TYPE shunt_bash_last_call_timestamp_seconds gauge
shunt_bash_last_call_timestamp_seconds{shunt="on"} 1795411800
# HELP shunt_collector_lines Hook log lines in the window's files: shunt (a counted record), other (another hook or outside the window), malformed, overlong, partial (an unterminated last line), over_cap (past the Shunt record limit or a guest's Shunt/Bash key limit) or duplicate (a guest's record already counted from another of its homes).
# TYPE shunt_collector_lines gauge
shunt_collector_lines{shunt="on",status="shunt"} 14
shunt_collector_lines{shunt="on",status="other"} 4
shunt_collector_lines{shunt="on",status="malformed"} 3
shunt_collector_lines{shunt="on",status="overlong"} 1
shunt_collector_lines{shunt="on",status="partial"} 1
shunt_collector_lines{shunt="on",status="over_cap"} 0
shunt_collector_lines{shunt="on",status="duplicate"} 0
# HELP shunt_collector_files The window's day files: read, missing, refused (a link or not a regular file), too_large; for guests also stale (archived mtime before window) or over_cap (omitted or incomplete due to shared scan budgets).
# TYPE shunt_collector_files gauge
shunt_collector_files{shunt="on",status="read"} 2
shunt_collector_files{shunt="on",status="missing"} 0
shunt_collector_files{shunt="on",status="refused"} 0
shunt_collector_files{shunt="on",status="too_large"} 0
# HELP shunt_collector_success_timestamp_seconds Unix time the collector last read the log without error.
# TYPE shunt_collector_success_timestamp_seconds gauge
shunt_collector_success_timestamp_seconds{shunt="on"} 1795413600
# HELP shunt_collector_failed 1 when this run failed (an error or the run deadline), else 0.
# TYPE shunt_collector_failed gauge
shunt_collector_failed{shunt="on"} 0
"""


def iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def rec(hook: str, result: str, at: float, duration: int, **extra: object) -> str:
    return json.dumps({"ts": iso(at), "hook": hook, "session": "SESSION-SECRET", "duration_ms": duration,
                       "result": result, **extra})


def read(result: str, tokens: int, duration: int, at: float = NOW - 3600, hook: str = "shunt-read") -> str:
    return rec(hook, result, at, duration, bytes=tokens * 3, lines=100, tokens=tokens, threshold=8000, returned=100,
               file="/home/u/SECRET-PATH")


def spill(result: str, chars: int, excerpt: int, duration: int) -> str:
    return rec("shunt-spill", result, NOW - 3600, duration, chars=chars, lines=10, excerpt_chars=excerpt,
               secret=False, excerpt="EXCERPT-SECRET")


def fixture(log: pathlib.Path) -> None:
    """Yesterday's file holds the window's first second and the second before it; today's the rest."""
    log.mkdir(parents=True, exist_ok=True)
    (log / "2026-11-22.jsonl").write_text("\n".join([
        read("allow", 1, 1, at=SINCE - 1),
        read("redirect", 9000, 10, at=SINCE),
    ]) + "\n")
    dup = spill("small", 100, 0, 10)
    (log / "2026-11-23.jsonl").write_text("\n".join([
        read("redirect", 9000, 20),
        read("bypass", 9000, 30),
        read("allow", 500, 15),
        read("mode", 0, 5),
        read("weird-RESULT", 0, 50, at=NOW),
        read("compound", 0, 20, hook="shunt-bash"),
        read("targeted", 300, 30, hook="shunt-bash"),
        spill("spilled", 20000, 4000, 40),
        dup,
        dup,
        spill("background", 0, 0, 5),
        rec("bulk-read", "ok", NOW - 3600, 10000, event="delegated", model="haiku", input_tokens=5, output_tokens=40,
            cache_read_input_tokens=1000, cache_creation_input_tokens=200, cost_usd=0.0125),
        rec("bulk-read", "timeout", NOW - 3600, 20000, cost_usd=None, input_tokens=None),
        rec("validate-bash", "allowed", NOW - 3600, 3),
        rec("validate-bash", "allowed", NOW - 1800, 3, command="/home/u/SECRET-PATH"),
        read("allow", 1, 1, at=NOW + 1),
        "not json {",
        "[1, 2]",
        json.dumps({"ts": "yesterday", "hook": "shunt-read", "result": "allow"}),
        '{"pad": "' + "x" * sm.LINE_MAX + '"}',
        read("allow", 7, 1)[:40],
    ]))


def run(*argv: str, shunt: str = "on") -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), "--shunt", shunt, *argv], capture_output=True, text=True,
                          check=False)


with tempfile.TemporaryDirectory() as tmp:
    log = pathlib.Path(tmp, "claude-hooks")
    fixture(log)
    t = sm.scan([str(log)], SINCE, NOW, time.monotonic() + 60)
    text = sm.render(t, NOW, {}, shunt="on").text()
    check(text == GOLDEN, "the fixture's textfile is GOLDEN" + ("" if text == GOLDEN else f":\n{text}"))
    check(not any(s in text for s in SECRETS), "no session id, path, excerpt or unknown result in the textfile")
    labels = set(re.findall(r'(\w+)="([^"]*)"', text))
    allowed = {("hook", h) for h in [*sm.RESULTS, sm.BASH_HOOK]} | {("result", r) for rs in sm.RESULTS.values() for r in rs | {"other"}}
    allowed |= {("kind", k) for k in ("seen", "returned", "bypassed")} | {("quantile", str(q)) for q in sm.QUANTILES}
    allowed |= {("status", s) for s in sm.LINE_STATUS + sm.FILE_STATUS} | {("kind", k) for k in sm.CHILD_TOKENS}
    allowed |= {("shunt", "on")}
    check(labels <= allowed, f"every label is from a fixed set {sorted(labels - allowed)}")

    # end to end, as the unit runs it: a missing log is idle, not zero events
    out = pathlib.Path(tmp, "shunt.prom")
    r = run("--out", str(out), "--log-dir", str(pathlib.Path(tmp, "none")))
    idle = out.read_text()
    check(r.returncode == 0 and "shunt_events" not in idle and 'shunt_collector_failed{shunt="on"} 0' in idle
          and re.search(r'shunt_collector_files\{shunt="on",status="missing"\} [12]\n', idle) is not None
          and 'shunt_spill_chars{kind="seen",shunt="on"} 0\n' in idle and 'shunt_bash_calls{shunt="on"} 0\n' in idle
          and re.search(r'^shunt_collector_success_timestamp_seconds\{shunt="on"\} \d', idle, re.MULTILINE) is not None,
          f"a missing log writes no event series, its sums 0, its files missing and a success timestamp (exit {r.returncode})")

    # a record today: the run reads the real day files
    live = pathlib.Path(tmp, "live")
    live.mkdir()
    (live / time.strftime("%Y-%m-%d.jsonl", time.gmtime())).write_text(read("redirect", 9000, 5, at=time.time()) + "\n")
    r = run("--out", str(out), "--log-dir", str(live))
    got = out.read_text()
    check('shunt_events{hook="shunt-read",result="redirect",shunt="on"} 1\n' in got,
          f"a run on today's file counts its record (exit {r.returncode}, stderr {r.stderr[-200:]!r})")
    ts = float(re.search(r'shunt_last_record_timestamp_seconds\{hook="shunt-read",shunt="on"\} (\S+)', got)[1])  # type: ignore[index]

    # no record in the window: the last-record timestamp carries over
    (live / time.strftime("%Y-%m-%d.jsonl", time.gmtime())).write_text("")
    run("--out", str(out), "--log-dir", str(live))
    got = out.read_text()
    check(f'shunt_last_record_timestamp_seconds{{hook="shunt-read",shunt="on"}} {ts:.15g}\n' in got and "shunt_events" not in got,
          "a run with no record carries the hook's last-record timestamp over and writes no events")
    ok = float(re.search(r'^shunt_collector_success_timestamp_seconds\{shunt="on"\} (\S+)$', got, re.MULTILINE)[1])  # type: ignore[index]

    # a failed run keeps the previous success and last-record timestamps
    real = sm.scan
    sm.scan = lambda *a: (_ for _ in ()).throw(TimeoutError("run deadline reached"))
    try:
        with contextlib.redirect_stderr(io.StringIO()) as err:
            sm.main(["--out", str(out), "--shunt", "on", "--log-dir", str(live)])
    finally:
        sm.scan = real
    check(err.getvalue() == "shunt-metrics: the scan failed, only the previous timestamps are kept: TimeoutError\n",
          "the failed run says so on stderr, captured: the gate's log shows no injected fault")
    got = out.read_text()
    check('shunt_collector_failed{shunt="on"} 1\n' in got
          and f'shunt_collector_success_timestamp_seconds{{shunt="on"}} {ok:.15g}\n' in got
          and f'shunt_last_record_timestamp_seconds{{hook="shunt-read",shunt="on"}} {ts:.15g}\n' in got
          and "shunt_collector_lines" not in got,
          "a failed run writes failed 1, keeps the previous success and last-record timestamps, and no counts")

    # a corrupt previous textfile is no previous one: the run succeeds and writes fresh timestamps
    out.write_text("shunt_collector_success_timestamp_seconds 12x\n"
                   'shunt_last_record_timestamp_seconds{hook="shunt-read"} not-a-number\n')
    check(sm.previous(str(out)) == (None, {}), "previous() reads a corrupt textfile as no previous one")
    r = run("--out", str(out), "--log-dir", str(live))
    got = out.read_text()
    check(r.returncode == 0 and 'shunt_collector_failed{shunt="on"} 0\n' in got and "not-a-number" not in got
          and re.search(r'^shunt_collector_success_timestamp_seconds\{shunt="on"\} \d', got, re.MULTILINE) is not None,
          f"a run after a corrupt textfile succeeds and rewrites it (exit {r.returncode}, stderr {r.stderr[-200:]!r})")

    # a duration that is not a non-negative int counts the decision but adds no duration sample
    bad = pathlib.Path(tmp, "bad-durations")
    bad.mkdir()
    (bad / "2026-11-23.jsonl").write_text("\n".join([
        rec("shunt-bash", "compound", NOW - 60, -5),
        rec("shunt-bash", "compound", NOW - 60, True),
        json.dumps({"ts": iso(NOW - 60), "hook": "shunt-bash", "result": "compound", "duration_ms": "12"}),
        json.dumps({"ts": iso(NOW - 60), "hook": "shunt-bash", "result": "compound"}),
        rec("shunt-read", "allow", NOW - 60, 7, tokens=1),
        rec("shunt-read", "allow", NOW - 60, 10**400, tokens=10**400),
        rec("shunt-read", "allow", NOW - 60, False),
    ]) + "\n")
    t = sm.scan([str(bad)], SINCE, NOW, time.monotonic() + 60)
    check(t.events.get(("shunt-bash", "compound")) == 4 and "shunt-bash" not in t.durations
          and t.durations.get("shunt-read") == [7] and t.tokens.get(("shunt-read", "seen")) == 1,
          f"negative, boolean, string, missing and oversized durations and sizes add nothing, their decisions still count"
          f" {t.durations} {t.tokens}")
    huge = pathlib.Path(tmp, "huge")
    huge.mkdir()
    (huge / time.strftime("%Y-%m-%d.jsonl", time.gmtime())).write_text(
        rec("bulk-read", "ok", time.time() - 60, 10**400, input_tokens=10**400) + "\n")
    r = run("--out", str(pathlib.Path(tmp, "huge.prom")), "--log-dir", str(huge))
    got = pathlib.Path(tmp, "huge.prom").read_text() if r.returncode == 0 else ""
    check('shunt_events{hook="bulk-read",result="ok",shunt="on"} 1\n' in got
          and 'shunt_bulk_read_tokens{kind="input",shunt="on"} 0\n' in got,
          f"a 400-digit int in a record counts its decision and adds nothing (exit {r.returncode}, {r.stderr[-200:]!r})")

    # day files that are a link, a FIFO or too large are not read; records past RECORDS_MAX are over_cap
    odd = pathlib.Path(tmp, "odd")
    odd.mkdir()
    (odd / "2026-11-22.jsonl").symlink_to(log / "2026-11-23.jsonl")
    os.mkfifo(odd / "2026-11-23.jsonl")
    t = sm.scan([str(odd)], SINCE, NOW, time.monotonic() + 60)
    check(t.files["refused"] == 2 and t.kept == 0, f"a link and a FIFO day file are refused unread {t.files}")
    caps = sm.FILE_MAX, sm.RECORDS_MAX
    sm.FILE_MAX, sm.RECORDS_MAX = (log / "2026-11-22.jsonl").stat().st_size, 3
    try:
        t = sm.scan([str(log)], SINCE, NOW, time.monotonic() + 60)
    finally:
        sm.FILE_MAX, sm.RECORDS_MAX = caps
    check(t.files == {"read": 1, "missing": 0, "refused": 0, "too_large": 1} and t.kept == 1
          and t.lines["over_cap"] == 0, f"a day file over FILE_MAX is skipped and counted too_large {t.files}")
    sm.RECORDS_MAX = 3
    try:
        t = sm.scan([str(log)], SINCE, NOW, time.monotonic() + 60)
    finally:
        sm.RECORDS_MAX = caps[1]
    check(t.kept == 3 and t.lines["over_cap"] == 11, f"records past RECORDS_MAX are counted over_cap {t.lines}")

    # a guest's log, by its declared name: worker and shunt from argv on every series
    state = pathlib.Path(tmp, "workers")
    today = time.strftime("%Y-%m-%d.jsonl", time.gmtime())
    for w, records in (("a1", [rec("shunt-spill", "small", time.time() - 60, 4, chars=10, excerpt_chars=0)]),
                       ("herman", [])):
        g = state / w / "home/.local/state/claude-hooks"
        g.mkdir(parents=True)
        bash = [rec("validate-bash", "allowed", time.time() - 60 * i, 2) for i in range(1, 4)]
        (g / today).write_text("\n".join(records + bash) + "\n")
    gout = pathlib.Path(tmp, "guest.prom")
    r = run("--out", str(gout), "--state-dir", str(state), "--worker", "a1")
    got = gout.read_text()
    series = [line for line in got.splitlines() if not line.startswith("#")]
    check(r.returncode == 0 and 'shunt_events{hook="shunt-spill",result="small",shunt="on",worker="a1"} 1\n' in got
          and all('shunt="on"' in line and 'worker="a1"}' in line for line in series),
          f"a guest's series carry shunt and its worker (exit {r.returncode}, stderr {r.stderr[-200:]!r})")

    # Shunt off still exports: the Bash calls, zero sums and the collector's health, labelled off; no event series
    r = run("--out", str(gout), "--state-dir", str(state), "--worker", "herman", shunt="off")
    got = gout.read_text()
    check('shunt_hook_time_ms{hook="validate-bash",shunt="off",worker="herman"} 6\n' in got,
          "the off side's validate-bash time is written, the control the on side's Shunt time per Bash call compares to")
    check(r.returncode == 0 and 'shunt_bash_calls{shunt="off",worker="herman"} 3\n' in got
          and 'shunt_spill_chars{kind="seen",shunt="off",worker="herman"} 0\n' in got
          and 'shunt_read_tokens{hook="shunt-read",kind="seen",shunt="off",worker="herman"} 0\n' in got
          and 'shunt_bulk_read_cost_usd{shunt="off",worker="herman"} 0\n' in got
          and 'shunt_collector_failed{shunt="off",worker="herman"} 0\n' in got
          and "shunt_bash_last_call_timestamp_seconds{" in got and "shunt_events" not in got,
          f"an off worker exports its Bash calls, zero sums and health, labelled off (exit {r.returncode})")

    # the guest controls its home: a link for it, or anywhere below, is refused and nothing behind it read
    (state / "l1").mkdir()
    (state / "l1/home").symlink_to(state / "herman/home")
    (state / "l2/home").mkdir(parents=True)
    (state / "l2/home/.local").symlink_to(state / "herman/home/.local")
    for w in ("l1", "l2"):
        r = run("--out", str(gout), "--state-dir", str(state), "--worker", w)
        got = gout.read_text()
        check(r.returncode == 0 and f'shunt_bash_calls{{shunt="on",worker="{w}"}} 0\n' in got
              and re.search(rf'shunt_collector_files\{{shunt="on",status="refused",worker="{w}"\}} [12]\n', got) is not None,
              f"{w}: a link on the guest's log path is refused unread (exit {r.returncode})")
    # a slot's trashed homes: <state>/.trash/<name>-YYYYMMDD-HHMMSS, local time, one per earlier turn
    def stamp_name(w: str, at: float) -> str:
        return f"{w}-{time.strftime('%Y%m%d-%H%M%S', time.localtime(at))}"

    def hooks(root: pathlib.Path, *records: str) -> pathlib.Path:
        g = root / "home/.local/state/claude-hooks"
        g.mkdir(parents=True)
        (g / today).write_text("".join(r + "\n" for r in records))
        return g

    pool = pathlib.Path(tmp, "pool")
    trash = pool / ".trash"
    trash.mkdir(parents=True)
    t0 = time.time()
    shared = rec("shunt-spill", "spilled", t0 - 7200, 4, chars=1000, excerpt_chars=100)
    hooks(pool / "p1", rec("shunt-spill", "spilled", t0 - 60, 4, chars=100, excerpt_chars=10), shared,
          rec("validate-bash", "allowed", t0 - 60, 2))
    hooks(trash / stamp_name("p1", t0 - 3600), shared, rec("validate-bash", "allowed", t0 - 3700, 2),
          rec("validate-bash", "allowed", t0 - 3700, 2))
    hooks(trash / stamp_name("p1", t0 - 7200), rec("shunt-spill", "spilled", t0 - 7300, 4, chars=10, excerpt_chars=1),
          rec("validate-bash", "allowed", t0 - 7300, 2))
    # trashed a day and a half ago, though its file was written in the window: its turn ended before it
    old = hooks(trash / stamp_name("p1", t0 - 36 * 3600), rec("validate-bash", "allowed", t0 - 120, 2))
    hooks(trash / stamp_name("p1-x", t0 - 600), rec("validate-bash", "allowed", t0 - 600, 2))
    hooks(trash / "home-cache", rec("validate-bash", "allowed", t0 - 600, 2))
    pout = pathlib.Path(tmp, "pool.prom")

    def pool_run() -> str:
        r = run("--out", str(pout), "--state-dir", str(pool), "--worker", "p1")
        return pout.read_text() if r.returncode == 0 else f"exit {r.returncode}, stderr {r.stderr[-200:]!r}"

    def pool_check(got: str, want: list[str], why: str) -> None:
        missing = [w for w in want if w not in got]
        check(not missing and 'shunt_collector_failed{shunt="on",worker="p1"} 0\n' in got,
              why + (f": no {missing} in\n{got}" if missing else ""))

    pool_check(pool_run(), ['shunt_events{hook="shunt-spill",result="spilled",shunt="on",worker="p1"} 3\n',
                            'shunt_spill_chars{kind="seen",shunt="on",worker="p1"} 1110\n',
                            'shunt_bash_calls{shunt="on",worker="p1"} 4\n',
                            'shunt_collector_homes{shunt="on",status="read",worker="p1"} 3\n',
                            'shunt_collector_lines{shunt="on",status="duplicate",worker="p1"} 1\n'],
               "a live and two trashed homes in the window sum, the record in two counts once, identical lines in one"
               " home count apart, one trashed before the window and another worker's are not read")

    # a trashed day file last written before the window is not read, though its name is a window day
    stale = trash / stamp_name("p1", t0 - 60)
    hooks(stale, rec("validate-bash", "allowed", t0 - 30, 2))
    os.utime(stale / "home/.local/state/claude-hooks" / today, (t0 - 30 * 3600, t0 - 30 * 3600))
    pool_check(pool_run(), ['shunt_bash_calls{shunt="on",worker="p1"} 4\n',
                            'shunt_collector_homes{shunt="on",status="read",worker="p1"} 4\n',
                            'shunt_collector_files{shunt="on",status="stale",worker="p1"} 1\n'],
               "a trashed day file written before the window is skipped and counted stale")

    # links: a trashed home that is one is refused, nothing behind it read; a .trash that is one, none of its homes
    (trash / stamp_name("p1", t0 - 120)).symlink_to(old.parents[2])
    pool_check(pool_run(), ['shunt_bash_calls{shunt="on",worker="p1"} 4\n',
                            'shunt_collector_homes{shunt="on",status="refused",worker="p1"} 1\n'],
               "a linked trashed home is refused unread")
    linked = pathlib.Path(tmp, "linked")
    hooks(linked / "p1", rec("validate-bash", "allowed", t0 - 60, 2))
    (linked / ".trash").symlink_to(trash)
    r = run("--out", str(pout), "--state-dir", str(linked), "--worker", "p1")
    got = pout.read_text()
    check(r.returncode == 0 and 'shunt_bash_calls{shunt="on",worker="p1"} 1\n' in got
          and 'shunt_collector_homes{shunt="on",status="refused",worker="p1"} 1\n' in got,
          f"a linked .trash is refused, the live home still read (exit {r.returncode})")

    # TRASH_MAX: the newest are read, the rest counted
    cap = sm.TRASH_MAX
    sm.TRASH_MAX = 1
    try:
        tt = sm.scan_worker(str(pool), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
    finally:
        sm.TRASH_MAX = cap
    check(tt.homes == {"read": 2, "missing": 0, "refused": 0, "over_cap": 3} and tt.bash_calls == 1,
          f"past TRASH_MAX the newest trashed home is read and the rest counted over_cap {tt.homes}")

    # a trashed home the sweep deletes between the listing and its read: missing, the run still succeeds
    real_listdir = sm.os.listdir
    gone = stamp_name("p1", t0 - 90)
    sm.os.listdir = lambda fd: [*real_listdir(fd), gone]
    try:
        tt = sm.scan_worker(str(pool), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
    finally:
        sm.os.listdir = real_listdir
    check(tt.homes is not None and tt.homes["missing"] == 1 and tt.bash_calls == 4,
          f"a trashed home deleted mid-read is missing, not an error {tt.homes}")

    # Host scans do not deduplicate across worker homes. Avoid parsing every timestamp twice.
    host_logs = hooks(pathlib.Path(tmp, "host-stamp"), rec("validate-bash", "allowed", t0 - 60, 2))
    original_stamp = sm.stamp
    stamp_calls = []

    def counted_stamp(value):
        stamp_calls.append(value)
        return original_stamp(value)

    sm.stamp = counted_stamp
    try:
        host = sm.scan([str(host_logs)], t0 - 86400, t0 + 60, time.monotonic() + 60)
    finally:
        sm.stamp = original_stamp
    check(host.bash_calls == 1 and len(stamp_calls) == 1,
          f"host timestamp parsed once per record, got {len(stamp_calls)} calls")

    # One worker-wide byte budget: a retained turn cannot multiply the maximum scan input. Live is first,
    # followed by the most recently trashed home; an older file that won't fit is reported, not parsed.
    bounded = pathlib.Path(tmp, "bounded")
    active = hooks(bounded / "p1", rec("validate-bash", "allowed", t0 - 60, 2))
    newest = hooks(bounded / ".trash" / stamp_name("p1", t0 - 120), rec("validate-bash", "allowed", t0 - 180, 3))
    hooks(bounded / ".trash" / stamp_name("p1", t0 - 240), rec("validate-bash", "allowed", t0 - 300, 5))
    cap_bytes = getattr(sm, "WORKER_BYTES_MAX", sm.FILE_MAX)
    sm.WORKER_BYTES_MAX = (active / today).stat().st_size + (newest / today).stat().st_size
    try:
        tt = sm.scan_worker(str(bounded), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
        check(tt.bash_calls == 2 and tt.hook_ms["validate-bash"] == 5 and tt.files.get("over_cap") == 1,
              f"worker byte budget keeps live/newest, reports omitted file {tt.files}")
        # Even if appending after fstat, a worker reads only the file's admitted snapshot.
        original_fstat = sm.os.fstat
        file_stat = (active / today).stat()

        def growing(fd: int):
            st = original_fstat(fd)
            if st.st_ino == file_stat.st_ino and st.st_dev == file_stat.st_dev:
                with open(active / today, "a") as f:
                    f.write(rec("validate-bash", "allowed", t0 - 30, 99) + "\n")
            return st

        sm.os.fstat = growing
        try:
            tt = sm.scan_worker(str(bounded), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
        finally:
            sm.os.fstat = original_fstat
        check(tt.bash_calls == 2 and tt.hook_ms["validate-bash"] == 5 and tt.files.get("over_cap") == 1,
              f"file growth after fstat cannot bypass admitted bytes {tt.files}")
    finally:
        sm.WORKER_BYTES_MAX = cap_bytes

    # Tiny malformed lines cannot consume unbounded JSON decoding work within the byte budget.
    chunks = pathlib.Path(tmp, "chunks")
    hooks(chunks / "p1", rec("validate-bash", "allowed", t0 - 60, 2), "", "", "")
    hooks(chunks / ".trash" / stamp_name("p1", t0 - 120), rec("validate-bash", "allowed", t0 - 180, 3))
    chunk_cap = getattr(sm, "WORKER_CHUNKS_MAX", 200_000)
    sm.WORKER_CHUNKS_MAX = 2
    try:
        tt = sm.scan_worker(str(chunks), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
    finally:
        sm.WORKER_CHUNKS_MAX = chunk_cap
    check(tt.bash_calls == 1 and tt.lines["malformed"] == 1 and tt.files.get("over_cap") == 2,
          f"readline budget exposes partial and omitted files while retaining live counts {tt.files}")

    # Unknown and malformed hooks do not use the guest's limited keys or displace real activity.
    ignored = pathlib.Path(tmp, "ignored")
    hooks(ignored / "p1", rec("unknown-hook", "allow", t0 - 90, 1),
          json.dumps({"ts": iso(t0 - 80), "hook": 7}), rec("validate-bash", "allowed", t0 - 60, 2))
    key_cap = sm.KEYS_MAX
    sm.KEYS_MAX = 1
    try:
        tt = sm.scan_worker(str(ignored), "p1", t0 - 86400, t0 + 60, time.monotonic() + 60)
    finally:
        sm.KEYS_MAX = key_cap
    check(tt.bash_calls == 1 and tt.lines["malformed"] == 1 and tt.lines["over_cap"] == 0,
          f"only counted hooks consume the key budget {tt.lines}")

    # Trash time slack is inclusive; malformed local-time names and times outside the slack are excluded.
    check(sm.trashed([stamp_name("p1", t0 - 86400 - 1800), stamp_name("p1", t0 - 86400 - 3601),
                      "p1-20261399-250000"], "p1", t0 - 86400) == [stamp_name("p1", t0 - 86400 - 1800)],
          "trash window slack and malformed timestamp")

    for argv, why in ((["--worker", "a1"], "--worker without --state-dir"),
                      (["--state-dir", str(state), "--worker", "../a1"], "a worker name outside the instance names"),
                      (["--state-dir", "workers", "--worker", "a1"], "a relative --state-dir")):
        r = run("--out", str(gout), *argv)
        check(r.returncode == 2, f"{why} is refused (exit {r.returncode})")
    r = subprocess.run([sys.executable, "-I", str(SCRIPT), "--out", str(gout)], capture_output=True, text=True,
                       check=False)
    check(r.returncode == 2, f"a run without --shunt is refused (exit {r.returncode})")

r = run("--list")
check(r.stdout.split() == list(sm.METRICS), "--list prints METRICS")
try:
    sm.Out().add("shunt_unknown", 1)
    check(False, "seeded: a metric name outside METRICS is refused")
except AssertionError:
    check(True, "seeded: a metric name outside METRICS is refused")

# memory: a 64 MiB day file of records, past RECORDS_MAX, in a fresh interpreter
module = (ROOT / "modules/homelab/shunt-metrics.nix").read_text()
memory_max = int(re.search(r'MemoryMax = "(\d+)M"', module)[1]) * 1024  # type: ignore[index]
with tempfile.TemporaryDirectory() as tmp:
    day = pathlib.Path(tmp, time.strftime("%Y-%m-%d.jsonl", time.gmtime()))
    line = (spill("small", 100, 0, 7).replace(iso(NOW - 3600), iso(time.time() - 60)) + "\n").encode()
    with open(day, "wb") as f:
        f.write(line * (sm.FILE_MAX // len(line)))
    code = ("import re, runpy, sys\nsys.argv = ['shunt-metrics.py', *sys.argv[1:]]\ntry:\n"
            f"    runpy.run_path({str(SCRIPT)!r}, run_name='__main__')\nexcept SystemExit:\n    pass\n"
            "print(re.search(r'VmHWM:\\s+(\\d+)', open('/proc/self/status').read()).group(1))")
    r = subprocess.run([sys.executable, "-I", "-c", code, "--out", f"{tmp}/m.prom", "--shunt", "on", "--log-dir", tmp],
                       capture_output=True, text=True, check=False)
    kb = int(r.stdout.split()[-1]) if r.returncode == 0 and r.stdout.split() else None
    capped = 'status="over_cap"} 0' not in pathlib.Path(tmp, "m.prom").read_text()
    check(kb is not None and kb < memory_max * 3 // 4 and capped,
          f"a 64 MiB day file peaks at {kb} kB, under 3/4 of the unit's MemoryMax ({memory_max} kB), past RECORDS_MAX")

    # a guest's, every line distinct so each is a key to count once across its homes: past KEYS_MAX
    g = pathlib.Path(tmp, "st/w1/home/.local/state/claude-hooks")
    g.mkdir(parents=True)
    day.unlink()
    with open(g / day.name, "wb") as f:
        size, i = 0, 0
        while size + len(line) + 8 <= sm.FILE_MAX:
            size += f.write(line.replace(b'"lines": 10', b'"lines": %d' % i))
            i += 1
    r = subprocess.run([sys.executable, "-I", "-c", code, "--out", f"{tmp}/w.prom", "--shunt", "on", "--state-dir",
                        f"{tmp}/st", "--worker", "w1"], capture_output=True, text=True, check=False)
    kb = int(r.stdout.split()[-1]) if r.returncode == 0 and r.stdout.split() else None
    got = pathlib.Path(tmp, "w.prom").read_text()
    capped = f'shunt_collector_lines{{shunt="on",status="shunt",worker="w1"}} {sm.KEYS_MAX}\n' in got
    check(kb is not None and kb < memory_max * 3 // 4 and capped,
          f"a guest's 64 MiB day file of distinct records peaks at {kb} kB, under 3/4 of MemoryMax, past KEYS_MAX")

# the wiring
p = gate_probe.section("shunt-metrics")
imported = sorted(h for h, i in p["imported"].items() if i)
check(imported == ["acer-swift", "asus-b460m", "lenovo", "msi-ms7758"], f"imported on the devTools hosts {imported}")
on_hosts = sorted(h for h, e in p["enabled"].items() if e)
check(on_hosts == ["acer-swift", "lenovo"], f"enabled on lenovo and acer {on_hosts}")
on, off, user = p["on"], p["off"], p["username"]
d = "--collector.textfile.directory=/var/lib/shunt-metrics"
check(d in on["flags"] and d not in off["flags"] and off["service"] is None and off["timer"] is None,
      "on lenovo node-exporter reads the dir; off (msi), no unit, timer or flag")
svc = on["service"] or {}
logdir = f"/home/{user}/.local/state/claude-hooks"
check(svc.get("User") == user and svc.get("ProtectHome") == "tmpfs" and svc.get("BindReadOnlyPaths") == [f"-{logdir}"]
      and svc.get("PrivateNetwork") is True and f"--log-dir {logdir}" in svc.get("ExecStart", "")
      and "-shunt-metrics.py --out /var/lib/shunt-metrics/shunt.prom --shunt on " in svc.get("ExecStart", ""),
      f"the unit runs as {user}, offline, with the hook log alone bound in read-only {svc.get('ExecStart')}")
check(f"d /var/lib/shunt-metrics 0755 {user} - -" in on["tmpfiles"] and on["failing"] == [],
      f"the dir exists before the first run, and lenovo evaluates clean (its memory budget included) {on['failing']}")
check((on["timer"] or {}).get("OnCalendar") == "*:07/15", f"every 15 minutes {on['timer']}")
check(any("homelab.shuntMetrics" in m for m in p["offDevTools"]), "enabled off devTools, it fails evaluation")

# acer: the host off, and the A/B, Shunt on for pool1 alone, each guest's unit passing its own declared switch
acer = p["acer"]
guests = acer["guests"]
check("--shunt off " in (acer["service"] or {}).get("ExecStart", "") and acer["failing"] == [],
      f"acer's own collector says off, and acer evaluates clean {acer['failing']}")
check({n: (g["declared"], g["readHook"]) for n, g in guests.items()} == {"pool1": (True, True), "pool2": (False, False), "pool3": (False, False), "pool4": (False, False)},
      f"Shunt is declared on, and its Read hook registered, for pool1 alone {guests}")
for n, g in guests.items():
    want = f"--out /var/lib/shunt-metrics-guests/shunt-guest-{n}.prom --shunt {'on' if g['declared'] else 'off'} " \
           f"--state-dir {acer['stateDir']} --worker {n}"
    check(want in (g["exec"] or "") and (g["timer"] or {}).get("OnCalendar") == "*:07/15",
          f"{n}'s unit reads its own home with its own switch every 15 minutes {g['exec']}")
d = "--collector.textfile.directory=/var/lib/shunt-metrics-guests"
check(d in acer["flags"] and d not in on["flags"] and "d /var/lib/shunt-metrics-guests 0755 root root m:2d" in acer["tmpfiles"],
      "node-exporter reads the guests' dir on acer, which exists before the first run and ages out removed instances")
finish()
