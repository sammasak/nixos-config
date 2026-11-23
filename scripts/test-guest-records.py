#!/usr/bin/env python3
"""The host's shipper of guest platform records (scripts/guest-records.py, core.nix's dev-env-records units), run on
a temp state dir against a fake Loki: each line once, also after the spool is rewritten; labels set by the host
alone; a line naming a label key, an unknown kind, an oversize or too old line dropped; the per-run cap; a link or
FIFO anywhere on the spool's path refused; progress kept outside the guest's home. Its allow-list is
pkgs/platform-record/platform_record.py's, and core.nix's trashOne ships before its rename, never failing it.
Usage: test-guest-records.py [SHIPPER [CORE_NIX]] (a seeded copy of either must fail it)."""
import hashlib
import importlib.util
import http.server
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHIPPER = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "scripts/guest-records.py"
CORE = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "modules/workers/core.nix"
PREFIX = "acer-swift"
OWNER_HOST = "lenovo-21CB001PMX"

schema = json.loads((ROOT / "metrics/records.json").read_text())["kinds"]
guest_kinds = sorted(k for k, v in schema.items() if v["guest"])
block = re.search(r"records = \{.*?kinds = \[(.*?)\];", (ROOT / "modules/workers/default.nix").read_text(), re.S)
kinds = re.findall(r'"([a-z-]+)"', block.group(1)) if block else []
check(len(schema) >= 10 and sorted(kinds) == guest_kinds and not {"deploy", "delivery", "trash-sweep"} & set(kinds),
      f"default.nix's records.kinds is metrics/records.json's guest kinds; a guest never deploys, records deliveries or "
      f"sweeps the host's trash ({kinds} vs {guest_kinds})")
FLEET = ["acer-swift", "asus-b460m", "black-pi", OWNER_HOST, "msi-ms7758", "naked-pi"]

core = CORE.read_text()
trash = re.search(r"\n  trashOne = ''\n(.*?)\n  '';\n", core, re.S)
body = trash.group(1) if trash else ""
ship = re.search(r'^\s*\S*timeout 30 \S*systemctl start "dev-env-records@\$n\.service" \|\| true$', body, re.M)
mv = re.search(r'^\s*mv -T --no-copy "\$d/\$n"', body, re.M)
guard = re.search(r"^\s*if \[\[ ! -L \$d/\$n && -d \$d/\$n \]\]; then$", body, re.M)
check(bool(ship and mv and guard) and guard.start() < ship.start() < mv.start(),
      "trashOne ships the instance's records (timeout 30, || true) before its rename, inside the not-a-link guard")
unit = re.search(r"\n  recordsUnit = names: timeout: \{\n(.*?)\n  \};\n", core, re.S)
u = unit.group(1) if unit else ""
want = ['"-I"', "DynamicUser = true;", 'CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];',
        'AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];', 'IPAddressDeny = "any";',
        "IPAddressAllow = cfg.records.address;", 'StateDirectory = "dev-env-records";', "NoNewPrivileges = true;",
        'ProtectSystem = "strict";']
check(all(w in u for w in want) and "guest-records.py" in u and "User = \"root\"" not in u,
      f"the units run python -I as a dynamic user with CAP_DAC_READ_SEARCH alone, reaching Loki's address only "
      f"(missing: {[w for w in want if w not in u]})")


class Loki(http.server.BaseHTTPRequestHandler):
    pushes = []
    status = 204

    def do_POST(self):
        Loki.pushes.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        self.send_response(Loki.status)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Loki)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_port}/loki/api/v1/push"

tmp = pathlib.Path(tempfile.mkdtemp(prefix="guest-records-"))
state, progress, outside = tmp / "state", tmp / "progress", tmp / "outside"
for d in (state, progress, outside):
    d.mkdir()
NOW = time.time()
TZ = timezone(timedelta(hours=1))


def rec(age, kind, fields):
    return f"{datetime.fromtimestamp(int(NOW - age), TZ).isoformat()} {kind} {fields}"


def spool_of(home):
    return home / ".local/state/platform-records"


def write(name, lines):
    """As platform_record.py does: a new file renamed over the spool, so a new inode each time."""
    s = spool_of(state / name / "home")
    s.parent.mkdir(parents=True, exist_ok=True)
    new = s.with_name("platform-records.new")
    new.write_text("".join(line + "\n" for line in lines))
    os.replace(new, s)
    return s.stat().st_ino


def run(*names):
    Loki.pushes.clear()
    try:
        p = subprocess.run([sys.executable, "-I", str(SHIPPER), "--state-dir", str(state), "--progress", str(progress),
                            "--prefix", PREFIX, "--url", URL, "--kinds", ",".join(kinds), "--fleet", ",".join(FLEET), *names],
                           capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out", []
    entries = [(s["stream"], v[0], v[1]) for _, b in Loki.pushes for s in b["streams"] for v in s["values"]]
    return p.returncode, p.stdout, p.stderr, entries


def bodies(entries):
    return [e[2] for e in entries]


def tree(root):
    return sorted((str(p.relative_to(root)), p.stat(follow_symlinks=False).st_mtime_ns) for p in root.rglob("*"))


# herman: what a gate writes, and what a guest might write besides
L = {
    "old": rec(8 * 86400, "gate", "gate=nixos-qa result=pass old=1"),
    "qa": rec(600, "gate", "gate=nixos-qa result=pass sha=abc"),
    "step": rec(500, "gate-step", f"gate=nixos-qa step=flake-check seconds=3 result=pass hostname={OWNER_HOST}"),
    "host": rec(400, "gate", f"gate=nixos-qa result=pass host={OWNER_HOST}"),
    "kind": rec(350, "bogus", "x=1"),
    "big": rec(300, "gate", "pad=" + "a" * 5000),
    "job": rec(250, "gate", 'note="a" job=platform'),
    "deploy": rec(100, "deploy", "node=acer-swift result=ok"),
    "delivery": rec(95, "delivery", "verified_deliveries=3"),
    # a guest speaking for a fleet host: a deferral's or a build's owner, a deploy's node, by hostname or flake attribute
    "owner": rec(90, "gate-step", f"step=nixos-flake-check check=c owner={OWNER_HOST} result=built"),
    "ownercase": rec(85, "gate-step", f"step=nixos-flake-check check=c owner={OWNER_HOST.lower()} result=built"),
    "node": rec(80, "gate", "gate=nixos-qa result=pass node=lenovo"),
    # its own name is no fleet host's
    "own": rec(70, "gate-step", f"step=nixos-flake-check check=c owner={PREFIX}-herman result=built"),
    # Loki's logfmt splits at any byte <= 0x20: each of these would read as acer-swift's coverage there
    "nul": rec(65, "coverage", "x=1\x00node=acer-swift"),
    "soh": rec(60, "coverage", "x=1\x01node=acer-swift"),
    # a control byte with no host in it: only the control-byte rule drops it
    "ctl": rec(55, "coverage", "x=1\x02y=2"),
    "tab": rec(50, "coverage", "x=1\ty=2"),
}
herman = [L[k] for k in ("old", "qa", "step", "host", "kind", "big", "job", "deploy", "delivery", "owner", "ownercase", "node", "own",
                         "nul", "soh", "ctl", "tab")]
ino1 = write("herman", herman)
fields = lambda k: L[k].split(" ", 2)[2]

# links and a FIFO out of an instance dir, each to a spool of good lines
good = "".join(rec(60, "gate", f"leak={i}") + "\n" for i in range(3))
for d in (outside / ".local/state", outside / "state"):
    d.mkdir(parents=True)
    (d / "platform-records").write_text(good)
(outside / "platform-records").write_text(good)
(state / "linka/home").mkdir(parents=True)
(state / "linka/home/.local").symlink_to(outside / ".local")
(state / "linkb/home/.local").mkdir(parents=True)
(state / "linkb/home/.local/state").symlink_to(outside / "state")
(state / "linkc/home/.local/state").mkdir(parents=True)
(state / "linkc/home/.local/state/platform-records").symlink_to(outside / "platform-records")
(state / "fifo/home/.local/state").mkdir(parents=True)
os.mkfifo(state / "fifo/home/.local/state/platform-records")
(state / "empty/home").mkdir(parents=True)
homes = tree(state)

rc, out, err, got = run("herman", "linka", "linkb", "linkc", "empty")
check(sorted(bodies(got)) == sorted(fields(k) for k in ("qa", "step", "own")),
      f"the first run pushes the gate's lines alone (got {bodies(got)}; {out.strip()} {err.strip()})")
check(all(s == {"job": "platform", "kind": s.get("kind"), "host": f"{PREFIX}-herman"} for s, _, _ in got)
      and sorted((s["kind"], b) for s, _, b in got) == sorted([("gate", fields("qa")), ("gate-step", fields("step")), ("gate-step", fields("own"))]),
      f"labels are exactly job=platform, the line's kind and host={PREFIX}-herman, though a field names "
      f"{OWNER_HOST} ({[s for s, _, _ in got]})")
check(not any(f"host={OWNER_HOST}" in b for b in bodies(got)), "a line with host= in its fields is dropped")
check(fields("job") not in bodies(got), "a line with job= in its fields is dropped")
check(fields("kind") not in bodies(got) and "3 unknown kind" in out, f"an unknown kind is dropped and counted ({out.strip()})")
check(fields("deploy") not in bodies(got) and fields("delivery") not in bodies(got),
      "a guest's deploy or delivery line is not shipped: guests never deploy")
check(not any(fields(k) in bodies(got) for k in ("owner", "ownercase", "node")) and "3 names a fleet host in node= or owner=" in out,
      f"a line whose owner= or node= names a fleet host (hostname, any case, or flake attribute) is dropped and counted ({out.strip()})")
check(fields("own") in bodies(got), "a line whose owner= is the guest's own name is shipped")
check(not any(fields(k) in bodies(got) for k in ("nul", "soh", "ctl", "tab")) and "4 not printable ASCII" in out,
      f"a line with any byte below 0x20 (NUL, SOH, another control byte, a tab) is dropped and counted ({out.strip()})")
check(fields("job") not in bodies(got) and "1 a backslash or quote" in out, f"a quoted value is dropped and counted ({out.strip()})")
# the grammar on its own: each of these is a form Loki would read as node=acer-swift or as another field
spec = importlib.util.spec_from_file_location("guest_records", SHIPPER)
gr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gr)
STAMP = "2026-11-18T12:00:00+01:00"
AT = datetime.fromisoformat(STAMP).timestamp()  # judge()'s now: the fixed STAMP never ages out of Loki's window
bad = {
    "a \\u escape": ('coverage x=1 node="acer\\u002dswift"', "a backslash or quote"),
    "a quote": ('coverage x=1 node="acer-swift"', "a backslash or quote"),
    "a backslash": ("coverage x=1 node=acer\\-swift", "a backslash or quote"),
    "Cyrillic a": ("coverage x=1 node=\u0430cer-swift", "not printable ASCII"),
    "a zero-width space": ("coverage x=1 node=acer\u200b-swift", "not printable ASCII"),
    "a duplicate key": ("coverage x=1 node=a node=b", "a duplicate key"),
    "two spaces": ("coverage x=1  y=2", "not key=value tokens"),
    "a token with no =": ("coverage x=1 (no NVIDIA libs)", "not key=value tokens"),
    "an upper-case key": ("coverage X=1", "not key=value tokens"),
    "a value outside the charset": ("coverage x=a;b", "not key=value tokens"),
    "a key starting with __": ("coverage __error__=x", "not key=value tokens"),
}
got_bad = {n: gr.parse(f"{STAMP} {line}".encode()) for n, (line, _) in bad.items()}
check(all(got_bad[n] == why for n, (_, why) in bad.items()), f"each form outside the grammar is refused for its own reason ({got_bad})")
ok = gr.parse(f"{STAMP} gate gate=nixos-qa seconds=12 result=pass head= deferred_checks=a:checks.x86_64-linux.b,c drv=/nix/store/x-y.drv".encode())
check(not isinstance(ok, str) and ok[2][3] == ("head", ""),
      f"a real record parses: empty value, comma list, store path, colons ({ok})")
pi = gr.judge(f"{STAMP} offload class=lint first_pass=1 model=homelab/auto served=a,b elapsed_s=41".encode(), set(kinds), AT,
              frozenset())
check(not isinstance(pi, str) and pi[1] == "offload", f"a guest's offload record ships in the existing grammar ({pi})")
lone = gr.judge(f"{STAMP} gate gate=nixos-qa result=pass".encode(), {"gate"}, AT, frozenset())
check(not isinstance(lone, str) and lone[2] == "gate=nixos-qa result=pass", f"what ships is rebuilt from the parsed fields ({lone})")
check(fields("big") not in bodies(got) and "1 oversize" in out, "a line over 4 KiB is dropped and counted")
check(fields("old") not in bodies(got) and "1 older than Loki takes" in out, "a line older than Loki's window is skipped")
check(sorted(int(t) // 10**9 for _, t, _ in got) == sorted(int(NOW - a) for a in (600, 500, 70)),
      "each entry carries the line's own time")
check(all(p == "/loki/api/v1/push" for p, _ in Loki.pushes) and len(Loki.pushes) == 1, "one push to the push path")
check(not any("leak=" in b for b in bodies(got)) and all(f"{n}: not shipped" in err for n in ("linka", "linkb", "linkc")),
      f"a link at .local, at state or at the spool is refused and nothing of theirs is pushed ({err.strip()})")
check(rc == 1, f"a refused instance fails the run (rc {rc})")
check("empty" not in err, "a home without a spool is no error")
frc, _, ferr, fgot = run("fifo")
check(frc == 1 and fgot == [] and "fifo: not shipped" in ferr, f"a FIFO spool is refused at once (rc {frc}, {ferr.strip()})")
check(tree(state) == homes, "the guest homes are left exactly as they were")
check((progress / "herman.json").is_file(),
      f"progress is kept under --progress, the unit's StateDirectory ({sorted(p.name for p in progress.iterdir())})")

rc, out, err, got = run("herman")
check(rc == 0 and got == [] and Loki.pushes == [], f"a second run pushes nothing (rc {rc}, {bodies(got)})")

L["new"] = rec(50, "gate", "gate=nixos-qa result=fail sha=def")
ino2 = write("herman", herman + [L["new"]])
rc, out, err, got = run("herman")
check(ino2 != ino1 and rc == 0 and bodies(got) == [fields("new")],
      f"a rewritten spool (new inode, same lines and one more) pushes only the new one ({bodies(got)})")

L["late"] = rec(1000, "gate", "late=1")
L["a"] = rec(40, "gate", "after=1")
L["b"] = rec(30, "gate", "after=2")
write("herman", [L["late"], L["a"], L["b"]])
rc, out, err, got = run("herman")
check(bodies(got) == [fields("a"), fields("b")],
      f"with the last shipped line gone, only lines no older than it go ({bodies(got)})")

L["down"] = rec(20, "gate", "while_down=1")
write("herman", [L["late"], L["a"], L["b"], L["down"]])
Loki.status = 500
rc, out, err, _ = run("herman")
Loki.status = 204
rc2, _, _, got = run("herman")
check(rc == 1 and rc2 == 0 and bodies(got) == [fields("down")],
      f"a push Loki did not take is sent again on the next run ({bodies(got)})")

bulk = [rec(8 * 86400 + i, "gate", f"stale={i}") for i in range(50, 0, -1)]
bulk += [rec(3000 - i, "gate", f"n={i}") for i in range(1200)]
write("bulk", bulk)
counts, first = [], ""
for i in range(4):
    rc, out, err, got = run("bulk")
    counts.append(len(got))
    first = first or out
check(counts == [500, 500, 200, 0], f"at most 500 lines per instance and run ({counts})")
check("50 older than Loki takes" in first, f"the backlog's too-old lines are skipped and counted ({first.strip()})")

# --usage (#494): host-made kind=usage lines from the container cgroups and confs, never from a guest file
check("usage" not in kinds, f"usage is not a guest kind: a guest cannot write one ({kinds})")
uu = re.search(r"\n  usageUnit =\n(.*?)\n  prepareDirs", core, re.S)
uu = uu.group(1) if uu else ""
check("recordsUnit names" in uu and '"--usage"' in uu and '"/sys/fs/cgroup/${slice}.slice"' in uu and '"/etc/nixos-containers"' in uu,
      "the usage unit is the shipper's own sandbox (recordsUnit), with --usage, the slice's cgroup and the containers' confs")
cg, confs = tmp / "cg", tmp / "confs"
confs.mkdir()
SP = "/nix/store/" + "a" * 32 + "-nixos-system-acer-herman-26.11"
for n, conf in (("herman", f"PRIVATE_NETWORK=1\nSYSTEM_PATH={SP}\n"), ("t2", "SYSTEM_PATH=/home/lukas/x; rm -rf /\n")):
    d = cg / f"container@{n}.service"
    d.mkdir(parents=True)
    (d / "cpu.stat").write_text("usage_usec 120000000\nuser_usec 100000000\nsystem_usec 20000000\n")
    (d / "memory.current").write_text("2015899648\n")
    (d / "memory.peak").write_text("7518265344\n")
    (d / "memory.stat").write_text("anon 1500000000\nfile 400000000\n")
    (confs / f"{n}.conf").write_text(conf)
write("herman", [rec(30, "gate", "from=spool")])


def usage_run(*names):
    Loki.pushes.clear()
    p = subprocess.run([sys.executable, "-I", str(SHIPPER), "--state-dir", str(state), "--progress", str(progress),
                        "--prefix", PREFIX, "--url", URL, "--kinds", ",".join(kinds), "--usage", "--cgroup", str(cg),
                        "--containers", str(confs), *names], capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout, p.stderr, [(s["stream"], v[0], v[1]) for _, b in Loki.pushes for s in b["streams"] for v in s["values"]]


rc, out, err, got = usage_run("herman", "t2")
by = {e[0]["host"]: e for e in got}
h = by.get(f"{PREFIX}-herman")
check(rc == 0 and h is not None and h[0] == {"job": "platform", "kind": "usage", "host": f"{PREFIX}-herman"}
      and h[2] == f"cpu_usec=120000000 user_usec=100000000 mem_current=2015899648 mem_anon=1500000000 mem_peak=7518265344 toplevel={SP}",
      f"one kind=usage line per instance, in the host's stream: cpu, user, current, anon, lifetime peak, the system ({got}, {err.strip()})")
check(by.get(f"{PREFIX}-t2", (None, None, ""))[2].endswith(" toplevel=unknown"),
      f"seeded: a conf whose SYSTEM_PATH is not a store path gives toplevel=unknown, never its text ({by.get(f'{PREFIX}-t2')})")
check(len(got) == 2 and not any("from=spool" in e[2] for e in got), f"usage mode ships no spool line ({got})")
rc, out, err, got = usage_run("herman", "gone")
check(rc == 0 and [e[0]["host"] for e in got] == [f"{PREFIX}-herman"] and "not running, skipped: gone" in out and err == "",
      f"an instance without a cgroup (stopped) is skipped and logged, rc 0, and the others still go ({rc}, {out.strip()}, {err.strip()})")
broken = cg / "container@broken.service"
broken.mkdir()
(broken / "cpu.stat").write_text("system_usec 1\n")
for f, v in (("memory.current", "1\n"), ("memory.peak", "1\n"), ("memory.stat", "anon 1\n")):
    (broken / f).write_text(v)
rc, out, err, got = usage_run("herman", "broken")
check(rc == 1 and [e[0]["host"] for e in got] == [f"{PREFIX}-herman"] and "broken: no usage" in err,
      f"seeded: a cgroup that is there but cannot be read (cpu.stat without usage_usec) fails the run, rc 1 ({rc}, {err.strip()})")
(broken / "cpu.stat").write_text("usage_usec 1\nuser_usec 1\n")
os.chmod(broken / "memory.peak", 0)
rc, out, err, got = usage_run("broken")
os.chmod(broken / "memory.peak", 0o644)
check(rc == 1 and got == [] and "broken: no usage (PermissionError" in err if os.geteuid() != 0 else True,
      f"seeded: an unreadable counter file in a present cgroup is a read error, rc 1 ({rc}, {err.strip()})")
real_cg = cg
cg = tmp / "no-such-slice"
rc, out, err, got = usage_run("herman")
check(rc == 1 and got == [] and "is not a directory" in err,
      f"seeded: a --cgroup slice that is not there fails the run (rc 1), never reads as every instance stopped ({rc}, {err.strip()})")
cg = real_cg
write("forge", [rec(30, "usage", "cpu_usec=1")])
rc, out, err, got = run("forge")
check(got == [] and "unknown kind" in out, f"seeded: a guest's own kind=usage line is dropped as an unknown kind ({got}, {out.strip()})")

shutil.rmtree(tmp)
finish()
