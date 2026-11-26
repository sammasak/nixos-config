#!/usr/bin/env python3
"""The Platform health records (pkgs/platform-record, nixos-config#467) against metrics/records.json: the dashboard
queries only kinds and fields the schema lists and shows every kind it should, each caller writes a known kind with
known fields, the writer's line equals the shell writer's it replaced (scripts/fixtures/platform-record-parity.json),
labels a push with job, kind and host alone, keeps a spool line, never fails its caller outside strict mode, refuses a
bad record under PLATFORM_RECORD_STRICT=1, and ships a failed push on the next run."""
import http.server
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
WRITER = ROOT / "pkgs/platform-record/platform_record.py"
SCHEMA = json.loads((ROOT / "metrics/records.json").read_text())["kinds"]
DASHBOARDS = {d: ROOT / f"modules/homelab/monitoring/dashboards/{d}.json" for d in ("platform-health", "pi-agents")}
PARITY = json.loads((ROOT / "scripts/fixtures/platform-record-parity.json").read_text())["cases"]
CALLERS = ["devenv.nix", "Justfile", "scripts/system-checks.sh", "modules/programs/cli/coordinator-wakeup.nix",
           "modules/workers/core.nix", "modules/workers/execution-pool.nix"]
STREAM = {"job", "kind", "host"}

fields = {k: set(v["fields"]) | set(v.get("optional", [])) for k, v in SCHEMA.items()}
required = {k: set(v["fields"]) for k, v in SCHEMA.items()}
check({"review", "research", "offload", "local-lane", "usage", "release", "bench", "lock"} <= set(SCHEMA) and len(SCHEMA) == 16,
      f"the schema lists every kind ({sorted(SCHEMA)})")
check(fields["review"] == {"repo", "head", "round", "grade", "reviewer", "author", "seconds", "findings"}
      and fields["research"] == {"issue", "claims_checked", "claims_corrected", "hours", "adopted", "spiked", "rejected"},
      f"review and research carry the plan's fields ({sorted(fields['review'])}, {sorted(fields['research'])})")
check(fields["release"] == {"app", "repo", "rev", "narHash", "outPath", "system", "checks", "target", "run", "ci", "ci_urls"}
      and fields["usage"] == {"cpu_usec", "user_usec", "mem_current", "mem_anon", "mem_peak", "toplevel"},
      f"release and usage carry their writers' fields ({sorted(fields['release'])}, {sorted(fields['usage'])})")
check(all(v["writer"] in ("here", "outside", "host") and isinstance(v["guest"], bool)
          and v.get("panel", "platform-health") in (*DASHBOARDS, False) for v in SCHEMA.values()),
      "every kind says who writes it, whether a guest may ship it and which dashboard shows it")
check(not (ROOT / "scripts/platform-record.sh").exists(), "the shell writer is gone")

# the dashboards: on each, the platform kinds and the fields each query reads
for dash, path in DASHBOARDS.items():
    exprs = [t["expr"] for p in json.loads(path.read_text())["panels"] for t in p.get("targets", [])]
    used: dict[str, set[str]] = {}
    for e in exprs:
        if 'job="platform"' not in e.replace(" ", ""):
            continue
        for k in re.findall(r'kind="([^"]+)"', e):
            after = e.split("| logfmt", 1)[1] if "| logfmt" in e else ""
            names = set(re.findall(r"unwrap (\w+)", after)) | set(re.findall(r"\|\s*(\w+)\s*(?:==|!=|=~|!~|>=|<=|=|>|<)", after))
            names |= {n.strip() for g in re.findall(r"by \(([^)]*)\)", e) for n in g.split(",") if n.strip()}
            used.setdefault(k, set()).update(names - STREAM - {"__error__"})
    shown = {k for k, v in SCHEMA.items() if v.get("panel", "platform-health") == dash}
    check(set(used) <= shown, f"{dash} queries only platform kinds the schema places there (others: {sorted(set(used) - shown)})")
    check(shown <= set(used), f"every kind the schema places on {dash} has a panel there (none: {sorted(shown - set(used))})")
    unknown = {k: sorted(n - fields.get(k, set())) for k, n in used.items() if n - fields.get(k, set())}
    check(not unknown, f"every field a {dash} panel reads is in its kind's schema (unknown: {unknown})")
    if dash == "platform-health":
        check(all('job="platform"' in e for e in exprs if "kind=" in e), "every Loki panel on platform-health selects the platform stream")

# the callers: kind and fields per call, a shell line continued by backslashes read as one
WRITE = re.compile(r"(?:platform_record\.py|getExe (?:record|platformRecord)\}|\$recorder)\"? ([a-z-]+)((?:\\\n|[^\n])*)")
written: dict[str, set[str]] = {}
writers: dict[str, set[str]] = {}
for c in CALLERS:
    for k, rest in WRITE.findall((ROOT / c).read_text()):
        writers.setdefault(k, set()).add(c)
        args = rest.split(";", 1)[0]  # the call ends at the shell's next command
        written.setdefault(k, set()).update(re.findall(r"(?<![\w$])([a-z_][a-z0-9_]*)=", args))
delivery = re.findall(r'"([a-z_]+)=\\\(', (ROOT / "scripts/platform-delivery.jq").read_text())
written.setdefault("delivery", set()).update(delivery)
defer = re.search(r"\[record, \"gate-step\",(.*?)\]", (ROOT / "scripts/gate_defer.py").read_text(), re.S)
gate_defer_fields = set(re.findall(r'f?"([a-z_]+)=', defer.group(1))) if defer else set()
check(len(delivery) == 7 and len(gate_defer_fields) == 8, f"platform-delivery.jq's and gate_defer.py's fields are read ({delivery}, {sorted(gate_defer_fields)})")
written["gate-step"] |= gate_defer_fields
writers.setdefault("gate-step", set()).add("scripts/gate_defer.py")
lane = re.search(r"record\(\{(.*?)\}\)", (ROOT / "scripts/local-lane.py").read_text(), re.S)
written["local-lane"] = set(re.findall(r'"([a-z_]+)":', lane.group(1))) if lane else set()
writers["local-lane"] = {"scripts/local-lane.py"}
here = {k for k, v in SCHEMA.items() if v["writer"] == "here"}
pending = {k for k, v in SCHEMA.items() if v.get("pending")}
check(all(isinstance(SCHEMA[k]["pending"], str) and SCHEMA[k]["pending"].strip() for k in pending),
      f"every pending kind names where its writer comes from ({sorted(pending)})")
check(set(writers) <= set(SCHEMA), f"every caller writes a known kind (unknown: {sorted(set(writers) - set(SCHEMA))})")
check(set(writers) == here - pending, f"every kind the schema says is written here, but not pending, has a writer here ({ {k: sorted(v) for k, v in writers.items()} })")
check(not pending & set(writers), f"a kind marked pending has no caller here yet; drop pending once it has ({sorted(pending & set(writers))})")
unknown = {k: sorted(n - fields.get(k, set())) for k, n in written.items() if n - fields.get(k, set())}
check(not unknown, f"every field a caller writes is in its kind's schema (unknown: {unknown})")
unwritten = {k: sorted(required[k] - n) for k, n in written.items() if k in here - pending and required[k] - n}
check(not unwritten, f"every field of a kind written here is written by some caller (never: {unwritten})")

# the gate record carries its wait for the heavy-work lock apart from its run time (pkgs/heavy-lock exports it); unknown,
# never 0, when no heavy-lock of ours measured it (a flock -o launcher, NIXOS_QA_LOCKED set by another)
qa_gate = [line for line in (ROOT / "devenv.nix").read_text().splitlines()
           if "${lib.getExe record} gate gate=nixos-qa " in line]
check(len(qa_gate) == 1 and 'wait_seconds="\'\'${HEAVY_LOCK_WAIT_SECONDS:-unknown}"' in qa_gate[0],
      f"the nixos:qa gate record has wait_seconds from HEAVY_LOCK_WAIT_SECONDS, unknown by default ({qa_gate})")


class Loki(http.server.BaseHTTPRequestHandler):
    bodies: list = []
    status = 204

    def do_POST(self):
        Loki.bodies.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(Loki.status)
        self.end_headers()

    def log_message(self, *args):
        pass


def env_for(spool, url, strict=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith("PLATFORM_RECORD")}
    env.update(PLATFORM_LOKI_URL=url, PLATFORM_RECORD_SPOOL=str(spool))
    if strict:
        env["PLATFORM_RECORD_STRICT"] = "1"
    return env


def record(spool, url, *argv, strict=False):
    out = subprocess.run([sys.executable, str(WRITER), *argv], env=env_for(spool, url, strict), capture_output=True, text=True)
    return out.returncode, out.stderr


def status(spool, url):
    out = subprocess.run([sys.executable, str(WRITER), "--status"], env=env_for(spool, url), capture_output=True, text=True)
    return json.loads(out.stdout)


def text(p):
    return p.read_text() if p.exists() else ""


server = http.server.HTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

with tempfile.TemporaryDirectory() as tmp:
    spool = pathlib.Path(tmp) / "spool"
    rc, err = record(spool, url, "deploy", "node=acer-swift", "result=ok", "seconds=12")
    stream = Loki.bodies[0]["streams"][0] if Loki.bodies else {}
    check(rc == 0 and len(Loki.bodies) == 1, f"a record is pushed once and exits 0 (rc {rc}, {len(Loki.bodies)} pushes, {err})")
    check(set(stream.get("stream", {})) == STREAM and stream["stream"]["job"] == "platform"
          and stream["stream"]["kind"] == "deploy" and stream["stream"]["host"] == os.uname().nodename,
          f"its labels are job=platform, kind and host alone ({stream.get('stream')})")
    check(stream.get("values", [[None, None]])[0][1] == "node=acer-swift result=ok seconds=12",
          f"the line is the fields as given ({stream.get('values')})")
    check(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d deploy node=acer-swift result=ok seconds=12\n", text(spool))
          is not None, f"the spool keeps the line after a date -Is stamp ({text(spool)!r})")

same = []
for c in PARITY:
    with tempfile.TemporaryDirectory() as tmp:
        spool = pathlib.Path(tmp) / "spool"
        Loki.bodies.clear()
        rc, err = record(spool, url, c["kind"], *c["args"], strict=True)
        s = Loki.bodies[0]["streams"][0] if Loki.bodies else {"stream": {}, "values": [[None, None]]}
        ok = (rc == 0 and {k: v for k, v in s["stream"].items() if k != "host"} == c["labels"]
              and s["values"][0][1] == c["line"] and text(spool).split(" ", 1)[-1] == c["spool"])
        same.append((c["kind"], ok, err.strip()))
check(len(same) == 8 and all(ok for _, ok, _ in same),
      f"for every kind the shell writer had, the line, labels and spool line equal its captured output ({same})")

with tempfile.TemporaryDirectory() as tmp:
    spool = pathlib.Path(tmp) / "spool"
    Loki.bodies.clear()
    rc, err = record(spool, url, "deploys", "result=ok")
    check(rc == 0 and "unknown kind" in err and text(spool) == "" and not Loki.bodies
          and status(spool, url)["counts"].get("unknown_kind") == 1,
          f"outside strict mode an unknown kind records nothing, exits 0 and is counted (rc {rc}, {err.strip()})")
    rc, err = record(spool, url, "deploy", "node=lenovo", "colour=blue", "loose")
    check(rc == 0 and "unknown field 'colour'" in err and "'loose' is not key=value" in err
          and "deploy node=lenovo colour=blue loose" in text(spool) and len(Loki.bodies) == 1
          and status(spool, url)["counts"].get("invalid_fields") == 2,
          f"outside strict mode bad fields are reported and counted, and the record is kept (rc {rc}, {err.strip()})")
    before = text(spool)
    for argv, why in ((["deploys", "result=ok"], "an unknown kind"), (["deploy", "colour=blue"], "an unknown field"),
                      (["deploy", "loose"], "a token that is not key=value"), ([], "no kind")):
        Loki.bodies.clear()
        rc, err = record(spool, url, *argv, strict=True)
        check(rc == 2 and text(spool) == before and not Loki.bodies,
              f"PLATFORM_RECORD_STRICT=1: {why} exits 2 and records nothing (rc {rc}, {err.strip()})")
    rc, err = record(spool, url, "review", "repo=nixos-config", "head=abc1234", "round=1", "grade=9", "reviewer=wZ",
                     "author=w18", "seconds=600", "findings=0", strict=True)
    check(rc == 0 and "review repo=nixos-config head=abc1234 round=1 grade=9" in text(spool),
          f"a review record passes strict mode ({rc}, {err.strip()})")
    rc, err = record(spool, url, "release", "app=alert-bridge", "repo=sammasak/alert-bridge", "rev=0123abc", "narHash=sha256-x",
                     "outPath=/nix/store/x-alert-bridge", "system=x86_64-linux", "checks=pass", "target=acer-swift", "run=1",
                     "ci=pass", "ci_urls=https://x", strict=True)
    check(rc == 0 and "release app=alert-bridge" in text(spool), f"a release record, narHash and outPath too, passes strict mode ({rc}, {err.strip()})")
    rc, err = record(spool, url, "deploy", "node=msi-ms7758", "result=ok", "free_gib=41", "closure_gib=12", "floor_gib=20",
                     "headroom=ok", strict=True)
    check(rc == 0 and "free_gib=41" in text(spool), f"deploy's optional headroom fields pass strict mode ({rc}, {err.strip()})")
    # pi-offload's record_run (devenv-platform feat/offload-record 2c7f210c, agents/pi/offload/pi-offload:318-322): its
    # fields in its order; the fixture fails here the day the schema and pi-offload's call diverge
    offload = (ROOT / "scripts/fixtures/pi-offload-record.txt").read_text().split()
    keys = [a.split("=", 1)[0] for a in offload[1:]]
    check(offload[0] == "offload" and keys == SCHEMA["offload"]["fields"],
          f"offload's schema fields are pi-offload's, in its order ({keys} vs {SCHEMA['offload']['fields']})")
    rc, err = record(spool, url, *offload, strict=True)
    ok_offload = rc == 0 and " ".join(offload) in text(spool)
    check(ok_offload, f"pi-offload's record passes the writer in strict mode ({rc}, {err.strip()})")
    sha = "0123456789abcdef0123456789abcdef01234567"
    bench = [["node=lenovo", "status=ok", f"sha={sha}", "dirty=0", "metrics_tool=0123456789ab", "eval_seconds=14",
              "values=1", "value_bytes=2", "gc_bytes=3", "thunks=4", "function_calls=5", "drv=/nix/store/x-nixos-system.drv",
              "closure_bytes=6"],
             ["node=static", "status=ok", f"sha={sha}", "dirty=0", "metrics_tool=0123456789ab", "files=7", "nix_lines=8",
              "comments=9", "comment_ratio=0.1"],
             ["node=all", "status=unknown", "reason=list-failed", f"sha={sha}", "dirty=0", "metrics_tool=0123456789ab",
              "closure_reason=closure-not-local"]]
    rcs = [record(spool, url, "bench", *b, strict=True)[0] for b in bench]
    bad_rc, _ = record(spool, url, "bench", "node=lenovo", "eval_secs=14", strict=True)
    check(rcs == [0, 0, 0] and bad_rc == 2, f"bench records (node, static, unknown) pass strict mode, a misnamed field does not ({rcs}, {bad_rc})")


with tempfile.TemporaryDirectory() as tmp:
    spool = pathlib.Path(tmp) / "spool"
    schema = pathlib.Path(tmp) / "none.json"
    env = env_for(spool, url) | {"PLATFORM_RECORD_SCHEMA": str(schema)}
    out = subprocess.run([sys.executable, str(WRITER), "gate", "result=pass"], env=env, capture_output=True, text=True)
    check(out.returncode == 0 and "no readable metrics/records.json" in out.stderr and "gate result=pass" in text(spool),
          f"outside strict mode an unreadable schema is reported and the record still kept ({out.returncode}, {out.stderr.strip()})")
    env["PLATFORM_RECORD_STRICT"] = "1"
    out = subprocess.run([sys.executable, str(WRITER), "gate", "result=pass"], env=env, capture_output=True, text=True)
    check(out.returncode == 2, f"strict mode refuses a record with an unreadable schema ({out.returncode}, {out.stderr.strip()})")

server.shutdown()
server.server_close()
with tempfile.TemporaryDirectory() as tmp:
    spool = pathlib.Path(tmp) / "spool"
    rc, err = record(spool, url, "gate", "result=fail")
    st = status(spool, url)
    check(rc == 0 and "did not take" in err and "gate result=fail" in text(spool) and st["retry_pending"] == 1
          and st["counts"].get("push_failed") == 1,
          f"with Loki away the caller still exits 0, the spool holds the record and the retry spool counts it ({rc}, {err.strip()}, {st})")
    rc, err = record(spool, url, "gate", "result=fail")
    check(rc == 0 and "unreachable within 5 min" in err and text(spool).count("gate result=fail") == 2
          and status(spool, url)["retry_pending"] == 2,
          f"after a failed push the next record is kept for retry without trying Loki again ({rc}, {err.strip()})")
    server = http.server.HTTPServer(("127.0.0.1", 0), Loki)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}"
    rc, err = record(spool, url, "gate", "result=pass")
    check(rc == 0 and "unreachable within 5 min" in err and status(spool, url)["retry_pending"] == 3,
          f"within 5 min of a failure Loki is not tried, even back ({rc}, {err.strip()})")
    down = spool.with_name("spool.loki-down")
    old = time.time() - 600
    os.utime(down, (old, old))
    Loki.bodies.clear()
    rc, err = record(spool, url, "gate", "result=pass")
    lines = [v[1] for b in Loki.bodies for s in b["streams"] for v in s["values"]]
    st = status(spool, url)
    check(rc == 0 and len(Loki.bodies) == 1 and lines == ["result=fail", "result=fail", "result=pass", "result=pass"]
          and st["retry_pending"] == 0 and st["counts"].get("retried") == 3 and not down.exists(),
          f"once Loki answers, the retry spool ships with the new record, oldest first, and is emptied ({lines}, {st})")
    Loki.bodies.clear()
    spool.with_name("spool.retry").write_text(json.dumps({"ts": "1", "kind": "gate", "host": "g", "line": "x"}) + "\n")
    down.touch()
    env = env_for(spool, url) | {"PLATFORM_RECORD_SHIPPER": "host"}
    out = subprocess.run([sys.executable, str(WRITER), "gate-step", "result=pass"], env=env, capture_output=True, text=True)
    st = json.loads(subprocess.run([sys.executable, str(WRITER), "--status"], env=env, capture_output=True,
                                   text=True).stdout)
    check(out.returncode == 0 and out.stderr == "" and not Loki.bodies and text(spool).endswith("gate-step result=pass\n")
          and st["retry_pending"] == 0 and st["retry_stale"] == 1 and st["shipper"] == "host" and down.exists()
          and text(spool.with_name("spool.retry")).count("\n") == 1,
          f"a guest's record (PLATFORM_RECORD_SHIPPER=host) goes to the spool alone, a fresh down marker or not: no "
          f"push, no retry, no warning; a queue from before is reported stale, never pending "
          f"({out.returncode}, {out.stderr.strip()}, {Loki.bodies}, {st})")
    server.shutdown()
    server.server_close()

report = {"metrics": {
    "verified_deliveries": {"value": {"total": 18}}, "review": {"value": None},
    "blocked_time": {"value": {"parked_events": 0}},
    "authorization_to_merge": {"value": {"n": 3, "median_seconds": 9000}}}}
with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
    json.dump(report, f)
    f.flush()
    out = subprocess.run(["jq", "-r", "-f", str(ROOT / "scripts/platform-delivery.jq"), f.name],
                         capture_output=True, text=True).stdout.split()
check(out == ["verified_deliveries=18", "prs_reviewed=unknown", "review_passes=unknown", "rework_rounds=unknown",
              "repeated_reviews=unknown", "parked=0", "lead_time_hours=2.5"],
      f"the delivery record: numbers kept (0 too), a null metric unknown, lead time the median in hours ({out})")

finish()
