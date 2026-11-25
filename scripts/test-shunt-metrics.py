#!/usr/bin/env python3
"""The Shunt collector (scripts/shunt-metrics.py) on fixture hook logs. A window across UTC midnight: every hook's
results, a result outside its set (other), another hook, records just inside and outside the window and in the future,
a malformed, a non-object, a bad timestamp, an overlong and an unterminated last line, two identical lines; the
exported file is GOLDEN. No session id, path, excerpt or unknown result in the textfile. A missing log is idle: no
event series, its files counted missing. A link or FIFO day file is refused, an oversized one skipped, records past
RECORDS_MAX counted over_cap. A failed run writes collector_failed 1 and keeps its previous success and last-record
timestamps; a run with no record carries the last-record ones over. `--list` is METRICS; seeded: a name outside it is
refused. A 64 MiB day file stays under 3/4 of the unit's MemoryMax. A guest (--worker): its series carry worker and
shunt, a link on its log path is refused, bad argv exits 2; with Shunt off it still exports its Bash calls and zero sums.
The wiring, from the probe: imported on the devTools hosts with node-exporter, enabled on lenovo and acer; on lenovo the
unit reads the hook log read-only with --shunt on and node-exporter the dir; on acer the host says off and each guest's
unit passes its own declared switch, on for pool1 alone (its Read hook registered), off for the other slots; enabled off devTools, it
fails evaluation.

Usage: test-shunt-metrics.py [SCRIPT] (a mutated copy for a seed)."""
import importlib.util
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
# HELP shunt_collector_lines Hook log lines in the window's files: shunt (a counted record), other (another hook or outside the window), malformed, overlong, partial (an unterminated last line) or over_cap.
# TYPE shunt_collector_lines gauge
shunt_collector_lines{shunt="on",status="shunt"} 14
shunt_collector_lines{shunt="on",status="other"} 4
shunt_collector_lines{shunt="on",status="malformed"} 3
shunt_collector_lines{shunt="on",status="overlong"} 1
shunt_collector_lines{shunt="on",status="partial"} 1
shunt_collector_lines{shunt="on",status="over_cap"} 0
# HELP shunt_collector_files The window's day files: read, missing, refused (a link or not a regular file) or too_large.
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
        sm.main(["--out", str(out), "--shunt", "on", "--log-dir", str(live)])
    finally:
        sm.scan = real
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
check({n: (g["declared"], g["readHook"]) for n, g in guests.items()} == {"pool1": (True, True), "pool2": (False, False), "pool3": (False, False)},
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
