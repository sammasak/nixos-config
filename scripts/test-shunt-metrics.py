#!/usr/bin/env python3
"""The Shunt collector (scripts/shunt-metrics.py) on fixture hook logs. A window across UTC midnight: every hook's
results, a result outside its set (other), another hook, records just inside and outside the window and in the future,
a malformed, a non-object, a bad timestamp, an overlong and an unterminated last line, two identical lines; the
exported file is GOLDEN. No session id, path, excerpt or unknown result in the textfile. A missing log is idle: no
event series, its files counted missing. A link or FIFO day file is refused, an oversized one skipped, records past
RECORDS_MAX counted over_cap. A failed run writes collector_failed 1 and keeps its previous success and last-record
timestamps; a run with no record carries the last-record ones over. `--list` is METRICS; seeded: a name outside it is
refused. A 64 MiB day file stays under 3/4 of the unit's MemoryMax. The wiring, from the probe: imported on the devTools
hosts with node-exporter, enabled on none; enabled, the unit reads the hook log read-only and node-exporter the dir;
enabled off devTools, it fails evaluation.

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
# HELP shunt_events Shunt hook decisions in the window, by hook and result.
# TYPE shunt_events gauge
shunt_events{hook="bulk-read",result="ok"} 1
shunt_events{hook="bulk-read",result="timeout"} 1
shunt_events{hook="shunt-bash",result="compound"} 1
shunt_events{hook="shunt-bash",result="targeted"} 1
shunt_events{hook="shunt-read",result="allow"} 1
shunt_events{hook="shunt-read",result="bypass"} 1
shunt_events{hook="shunt-read",result="mode"} 1
shunt_events{hook="shunt-read",result="other"} 1
shunt_events{hook="shunt-read",result="redirect"} 2
shunt_events{hook="shunt-spill",result="background"} 1
shunt_events{hook="shunt-spill",result="small"} 2
shunt_events{hook="shunt-spill",result="spilled"} 1
# HELP shunt_read_tokens Tokens the read hooks estimated in the window: seen (every decision), returned (all but redirects) and bypassed (re-reads let through after a redirect, a saving undone).
# TYPE shunt_read_tokens gauge
shunt_read_tokens{hook="shunt-bash",kind="returned"} 300
shunt_read_tokens{hook="shunt-bash",kind="seen"} 300
shunt_read_tokens{hook="shunt-read",kind="bypassed"} 9000
shunt_read_tokens{hook="shunt-read",kind="returned"} 9500
shunt_read_tokens{hook="shunt-read",kind="seen"} 27500
# HELP shunt_spill_chars Bash output chars in the window: seen (every spill decision) and returned (the excerpt of a spilled output, the whole of any other).
# TYPE shunt_spill_chars gauge
shunt_spill_chars{kind="seen"} 20200
shunt_spill_chars{kind="returned"} 4200
# HELP shunt_hook_duration_ms A Shunt hook's own run time in the window, by quantile.
# TYPE shunt_hook_duration_ms gauge
shunt_hook_duration_ms{hook="bulk-read",quantile="0.5"} 15000
shunt_hook_duration_ms{hook="bulk-read",quantile="0.95"} 19500
shunt_hook_duration_ms{hook="shunt-bash",quantile="0.5"} 25
shunt_hook_duration_ms{hook="shunt-bash",quantile="0.95"} 29.5
shunt_hook_duration_ms{hook="shunt-read",quantile="0.5"} 17.5
shunt_hook_duration_ms{hook="shunt-read",quantile="0.95"} 45
shunt_hook_duration_ms{hook="shunt-spill",quantile="0.5"} 10
shunt_hook_duration_ms{hook="shunt-spill",quantile="0.95"} 35.5
# HELP shunt_last_record_timestamp_seconds Unix time of the hook's newest record, carried over while the window holds none.
# TYPE shunt_last_record_timestamp_seconds gauge
shunt_last_record_timestamp_seconds{hook="bulk-read"} 1795410000
shunt_last_record_timestamp_seconds{hook="shunt-bash"} 1795410000
shunt_last_record_timestamp_seconds{hook="shunt-read"} 1795413600
shunt_last_record_timestamp_seconds{hook="shunt-spill"} 1795410000
# HELP shunt_collector_lines Hook log lines in the window's files: shunt (a counted record), other (another hook or outside the window), malformed, overlong, partial (an unterminated last line) or over_cap.
# TYPE shunt_collector_lines gauge
shunt_collector_lines{status="shunt"} 14
shunt_collector_lines{status="other"} 3
shunt_collector_lines{status="malformed"} 3
shunt_collector_lines{status="overlong"} 1
shunt_collector_lines{status="partial"} 1
shunt_collector_lines{status="over_cap"} 0
# HELP shunt_collector_files The window's day files: read, missing, refused (a link or not a regular file) or too_large.
# TYPE shunt_collector_files gauge
shunt_collector_files{status="read"} 2
shunt_collector_files{status="missing"} 0
shunt_collector_files{status="refused"} 0
shunt_collector_files{status="too_large"} 0
# HELP shunt_collector_success_timestamp_seconds Unix time the collector last read the log without error.
# TYPE shunt_collector_success_timestamp_seconds gauge
shunt_collector_success_timestamp_seconds 1795413600
# HELP shunt_collector_failed 1 when this run failed (an error or the run deadline), else 0.
# TYPE shunt_collector_failed gauge
shunt_collector_failed 0
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
        rec("bulk-read", "ok", NOW - 3600, 10000, event="delegated", model="haiku", input_tokens=5),
        rec("bulk-read", "timeout", NOW - 3600, 20000),
        rec("validate-bash", "allowed", NOW - 3600, 3),
        read("allow", 1, 1, at=NOW + 1),
        "not json {",
        "[1, 2]",
        json.dumps({"ts": "yesterday", "hook": "shunt-read", "result": "allow"}),
        '{"pad": "' + "x" * sm.LINE_MAX + '"}',
        read("allow", 7, 1)[:40],
    ]))


def run(*argv: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *argv], capture_output=True, text=True, check=False)


with tempfile.TemporaryDirectory() as tmp:
    log = pathlib.Path(tmp, "claude-hooks")
    fixture(log)
    t = sm.scan(str(log), SINCE, NOW, time.monotonic() + 60)
    text = sm.render(t, NOW, {}).text()
    check(text == GOLDEN, "the fixture's textfile is GOLDEN" + ("" if text == GOLDEN else f":\n{text}"))
    check(not any(s in text for s in SECRETS), "no session id, path, excerpt or unknown result in the textfile")
    labels = set(re.findall(r'(\w+)="([^"]*)"', text))
    allowed = {("hook", h) for h in sm.RESULTS} | {("result", r) for rs in sm.RESULTS.values() for r in rs | {"other"}}
    allowed |= {("kind", k) for k in ("seen", "returned", "bypassed")} | {("quantile", str(q)) for q in sm.QUANTILES}
    allowed |= {("status", s) for s in sm.LINE_STATUS + sm.FILE_STATUS}
    check(labels <= allowed, f"every label is from a fixed set {sorted(labels - allowed)}")

    # end to end, as the unit runs it: a missing log is idle, not zero events
    out = pathlib.Path(tmp, "shunt.prom")
    r = run("--out", str(out), "--log-dir", str(pathlib.Path(tmp, "none")))
    idle = out.read_text()
    check(r.returncode == 0 and "shunt_events" not in idle and "shunt_collector_failed 0" in idle
          and re.search(r'shunt_collector_files\{status="missing"\} [12]\n', idle) is not None
          and re.search(r"^shunt_collector_success_timestamp_seconds \d", idle, re.MULTILINE) is not None,
          f"a missing log writes no event series, its files missing and a success timestamp (exit {r.returncode})")

    # a record today: the run reads the real day files
    live = pathlib.Path(tmp, "live")
    live.mkdir()
    (live / time.strftime("%Y-%m-%d.jsonl", time.gmtime())).write_text(read("redirect", 9000, 5, at=time.time()) + "\n")
    r = run("--out", str(out), "--log-dir", str(live))
    got = out.read_text()
    check('shunt_events{hook="shunt-read",result="redirect"} 1\n' in got,
          f"a run on today's file counts its record (exit {r.returncode}, stderr {r.stderr[-200:]!r})")
    ts = float(re.search(r'shunt_last_record_timestamp_seconds\{hook="shunt-read"\} (\S+)', got)[1])  # type: ignore[index]

    # no record in the window: the last-record timestamp carries over
    (live / time.strftime("%Y-%m-%d.jsonl", time.gmtime())).write_text("")
    run("--out", str(out), "--log-dir", str(live))
    got = out.read_text()
    check(f'shunt_last_record_timestamp_seconds{{hook="shunt-read"}} {ts:.15g}\n' in got and "shunt_events" not in got,
          "a run with no record carries the hook's last-record timestamp over and writes no events")
    ok = float(re.search(r"^shunt_collector_success_timestamp_seconds (\S+)$", got, re.MULTILINE)[1])  # type: ignore[index]

    # a failed run keeps the previous success and last-record timestamps
    real = sm.scan
    sm.scan = lambda *a: (_ for _ in ()).throw(TimeoutError("run deadline reached"))
    try:
        sm.main(["--out", str(out), "--log-dir", str(live)])
    finally:
        sm.scan = real
    got = out.read_text()
    check("shunt_collector_failed 1\n" in got and f"shunt_collector_success_timestamp_seconds {ok:.15g}\n" in got
          and f'shunt_last_record_timestamp_seconds{{hook="shunt-read"}} {ts:.15g}\n' in got
          and "shunt_collector_lines" not in got,
          "a failed run writes failed 1, keeps the previous success and last-record timestamps, and no counts")

    # day files that are a link, a FIFO or too large are not read; records past RECORDS_MAX are over_cap
    odd = pathlib.Path(tmp, "odd")
    odd.mkdir()
    (odd / "2026-11-22.jsonl").symlink_to(log / "2026-11-23.jsonl")
    os.mkfifo(odd / "2026-11-23.jsonl")
    t = sm.scan(str(odd), SINCE, NOW, time.monotonic() + 60)
    check(t.files["refused"] == 2 and t.kept == 0, f"a link and a FIFO day file are refused unread {t.files}")
    caps = sm.FILE_MAX, sm.RECORDS_MAX
    sm.FILE_MAX, sm.RECORDS_MAX = (log / "2026-11-22.jsonl").stat().st_size, 3
    try:
        t = sm.scan(str(log), SINCE, NOW, time.monotonic() + 60)
    finally:
        sm.FILE_MAX, sm.RECORDS_MAX = caps
    check(t.files == {"read": 1, "missing": 0, "refused": 0, "too_large": 1} and t.kept == 1
          and t.lines["over_cap"] == 0, f"a day file over FILE_MAX is skipped and counted too_large {t.files}")
    sm.RECORDS_MAX = 3
    try:
        t = sm.scan(str(log), SINCE, NOW, time.monotonic() + 60)
    finally:
        sm.RECORDS_MAX = caps[1]
    check(t.kept == 3 and t.lines["over_cap"] == 11, f"records past RECORDS_MAX are counted over_cap {t.lines}")

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
    r = subprocess.run([sys.executable, "-I", "-c", code, "--out", f"{tmp}/m.prom", "--log-dir", tmp],
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
check(on_hosts == [], f"enabled on no host yet {on_hosts}")
on, off, user = p["on"], p["off"], p["username"]
d = "--collector.textfile.directory=/var/lib/shunt-metrics"
check(d in on["flags"] and d not in off["flags"] and off["service"] is None and off["timer"] is None,
      "enabled, node-exporter reads the dir; off, no unit, timer or flag")
svc = on["service"] or {}
logdir = f"/home/{user}/.local/state/claude-hooks"
check(svc.get("User") == user and svc.get("ProtectHome") == "tmpfs" and svc.get("BindReadOnlyPaths") == [f"-{logdir}"]
      and svc.get("PrivateNetwork") is True and f"--log-dir {logdir}" in svc.get("ExecStart", "")
      and "-shunt-metrics.py --out /var/lib/shunt-metrics/shunt.prom" in svc.get("ExecStart", ""),
      f"the unit runs as {user}, offline, with the hook log alone bound in read-only {svc.get('ExecStart')}")
check(f"d /var/lib/shunt-metrics 0755 {user} - -" in on["tmpfiles"] and on["failing"] == [],
      f"the dir exists before the first run, and enabled it evaluates clean {on['failing']}")
check((on["timer"] or {}).get("OnCalendar") == "*:07/15", f"every 15 minutes {on['timer']}")
check(any("homelab.shuntMetrics" in m for m in p["offDevTools"]), "enabled off devTools, it fails evaluation")
finish()
