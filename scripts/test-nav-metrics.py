#!/usr/bin/env python3
"""The navigation collector (scripts/nav-metrics.py) on fixture transcripts in a temporary HOME: a worker session in a
nixos-config checkout (Read, Grep, Glob and Bash navigation, a missed lookup, repeat reads, an Edit, a malformed line,
an event older than the window) and a coordinator session named as such. The exported values; no prompt, command or
path in the textfile; a thin role writes its sample size alone; a failed section writes section_failed 1 and keeps its
last timestamp; `--list` is METRICS. Seeded: a name outside METRICS is refused."""
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/nav-metrics.py"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


NOW = time.time()


def iso(hours_ago):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(NOW - hours_ago * 3600))


class Session:
    """Builds one transcript; every call gets its result right after it."""

    def __init__(self, cwd, name=None):
        self.cwd, self.lines, self.n = cwd, [], 0
        if name:
            self.lines.append(json.dumps({"type": "agent-name", "agentName": name, "sessionId": "s"}))

    def prompt(self, text, kind="human", hours_ago=1.0):
        self.lines.append(json.dumps({"type": "user", "origin": {"kind": kind}, "timestamp": iso(hours_ago), "cwd": self.cwd,
                                      "message": {"role": "user", "content": text}}))

    def call(self, name, inp, result="ok", is_error=False, hours_ago=1.0, sidechain=False):
        self.n += 1
        tid = f"toolu_{self.n}"
        base = {"timestamp": iso(hours_ago), "cwd": self.cwd, "isSidechain": sidechain}
        self.lines.append(json.dumps(dict(base, type="assistant", message={
            "role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]})))
        self.lines.append(json.dumps(dict(base, type="user", message={
            "role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": result, "is_error": is_error}]})))

    def raw(self, line):
        self.lines.append(line)

    def write(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(self.lines) + "\n")


with tempfile.TemporaryDirectory() as tmp:
    home = pathlib.Path(tmp) / "home"
    repo = home / "nixos-config"
    os.environ["HOME"] = str(home)
    spec = importlib.util.spec_from_file_location("nav_metrics", SCRIPT)
    nm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nm)
    projects = home / ".claude/projects"

    PROMPTS = ["PROMPT-SECRET-alpha: fix the fleet module", "PROMPT-SECRET-beta: read the scripts",
               "PROMPT-SECRET-gamma: coordinate"]
    COMMANDS = []

    def bash(s, command, **kw):
        COMMANDS.append(command)
        s.call("Bash", {"command": command}, **kw)

    w = Session(str(repo))
    # before the window: a prompt and a repo lookup that must not count
    w.prompt("PROMPT-SECRET-old", hours_ago=30)
    w.call("Read", {"file_path": f"{repo}/flake.nix"}, hours_ago=30)
    # stretch 1: seven navigation calls (six on the repo, two of them misses) before the Edit
    w.prompt(PROMPTS[0])
    w.call("Read", {"file_path": f"{repo}/modules/core/fleet.nix"}, result="file body")
    w.call("Read", {"file_path": f"{repo}/modules/core/fleet.nix"}, result="file body")
    w.call("Grep", {"pattern": "CMD-SECRET-pattern"}, result="No matches found")
    w.call("Glob", {"pattern": "**/*.nix"}, result="flake.nix")
    bash(w, "cat docs/fixture.md", result="# Fixture")
    bash(w, "ls /nonexistent-zzz", result="ls: cannot access '/nonexistent-zzz': No such file or directory")
    w.call("Read", {"file_path": f"{repo}/missing.nix"}, result="File does not exist.", is_error=True)
    # neither navigation: a build, and a grep that filters another command's output
    bash(w, "nix build .#checks.x86_64-linux.CMD-SECRET-build", result="")
    bash(w, "echo CMD-SECRET-echo | grep CMD", result="CMD-SECRET-echo")
    w.call("Edit", {"file_path": f"{repo}/modules/core/fleet.nix", "old_string": "a", "new_string": "b"})
    bash(w, "grep -rn foo scripts/", result="scripts/a.py:1:foo")
    w.raw("{not json at all")
    w.raw("[1, 2, 3]")
    w.call("Read", "an input that is not an object")
    # a subagent's record inside the main transcript is not the session's own navigation
    w.call("Read", {"file_path": f"{repo}/sidechain.nix"}, sidechain=True)
    # stretch 2: fifty reads of five files (45 repeats); a task notification does not split it
    w.prompt(PROMPTS[1], kind="peer")
    for i in range(50):
        if i == 25:
            w.prompt("task notification", kind="task-notification")
        bash(w, f"sed -n 1,10p scripts/x{i % 5}.py", result="line")
    w.write(projects / "-home-nixos-config/worker.jsonl")

    c = Session(str(home), name="coordinator-test")
    c.prompt(PROMPTS[2])
    bash(c, "ls ~/nixos-config/modules", result="core")
    bash(c, "git -C ~/nixos-config log --oneline -3", result="abc fix")
    bash(c, "cat /etc/hostname", result="lenovo")
    c.call("Write", {"file_path": f"{home}/.local/state/brief.md", "content": "CMD-SECRET-content"})
    c.write(projects / "-home/coordinator.jsonl")
    # a subagent transcript, one level deeper, is not read
    sub = Session(str(repo))
    sub.prompt("PROMPT-SECRET-sub")
    for _ in range(60):
        sub.call("Read", {"file_path": f"{repo}/sub.nix"}, result="No such file", is_error=True)
    sub.write(projects / "-home-nixos-config/worker/subagents/agent-a.jsonl")

    def run(out, *extra):
        rc = nm.main(["--out", out, "--projects", str(projects), *extra])
        text = pathlib.Path(out).read_text()
        rows = [l for l in text.splitlines() if l and not l.startswith("#")]
        return rc, text, {l.rsplit(" ", 1)[0]: float(l.rsplit(" ", 1)[1]) for l in rows}

    out = f"{tmp}/nav.prom"
    rc, text, m = run(out)
    W, C = 'role="worker"', 'role="coordinator"'
    check(rc == 0, "a full run exits 0")
    check(m.get(f"agent_nav_repo_nav_calls{{{W}}}") == 57,
          f"worker repo navigation calls: 6 + 1 in stretch 1, 50 in stretch 2; none before the window, from a subagent or a filter ({m.get(f'agent_nav_repo_nav_calls{{{W}}}')})")
    check(abs(m.get(f"agent_nav_repo_miss_ratio{{{W}}}", -1) - 2 / 57) < 1e-9,
          f"a Grep with no match and a Read error are the repo misses; the miss outside the repo is not ({m.get(f'agent_nav_repo_miss_ratio{{{W}}}')})")
    check(m.get(f"agent_nav_repo_reads{{{W}}}") == 54 and abs(m.get(f"agent_nav_repeat_read_ratio{{{W}}}", -1) - 46 / 54) < 1e-9,
          f"repeat reads: the second Read of fleet.nix and 45 of the 50 sed -n reads ({m.get(f'agent_nav_repo_reads{{{W}}}')}, {m.get(f'agent_nav_repeat_read_ratio{{{W}}}')})")
    check(m.get(f"agent_nav_stretches{{{W}}}") == 2, "two repo stretches: a task notification starts none")
    check(m.get(f'agent_nav_calls_before_first_edit{{quantile="0.5",{W}}}') == 28.5
          and abs(m.get(f'agent_nav_calls_before_first_edit{{quantile="0.9",{W}}}', -1) - 45.7) < 1e-9,
          "navigation calls before the first edit: 7 (the Edit ends the count) and 50 (no edit)")
    check(m.get(f'agent_nav_topdirs_before_first_edit{{quantile="0.5",{W}}}') == 2
          and abs(m.get(f'agent_nav_topdirs_before_first_edit{{quantile="0.9",{W}}}', -1) - 2.8) < 1e-9,
          "top-level dirs before the first edit: modules, docs and the root in stretch 1, scripts in stretch 2")
    check(m.get(f"agent_nav_repo_nav_calls{{{C}}}") == 2,
          "the session named coordinator counts as coordinator: two repo calls (a path, a git -C cwd), /etc not")
    check([k for k in m if C in k] == [f"agent_nav_repo_nav_calls{{{C}}}"],
          "a thin role (under 50 repo calls) writes its sample size and no ratio or quantile")
    check(all(m.get(f'agent_nav_collector_section_failed{{section="{s}"}}') == 0 for s in nm.SECTIONS)
          and all(f'agent_nav_collector_success_timestamp_seconds{{section="{s}"}}' in m for s in nm.SECTIONS),
          "a full run writes section_failed 0 and a success timestamp for every section")
    labels = set(re.findall(r'[{,]([a-z_]+)="', text))
    check(labels <= {"role", "quantile", "section"}, f"labels are role, quantile and section only ({sorted(labels)})")
    fragments = PROMPTS + ["PROMPT-SECRET", "CMD-SECRET", tmp, str(home), "fleet.nix", "fixture.md", "missing.nix",
                           "x0.py", "/etc/hostname", "nonexistent", "modules/core", "docs/", "scripts/"] + COMMANDS
    leaked = sorted({f for f in fragments for line in text.splitlines() if f in line})
    check(not leaked, f"no prompt, command or path in the textfile {leaked}")

    # thin window: the coordinator's session alone
    thin = projects.parent / "thin"
    c.write(thin / "-home/coordinator.jsonl")
    rc, _, t = run(f"{tmp}/thin.prom", "--projects", str(thin))
    names = {k.split("{")[0] for k in t}
    check(rc == 0 and names == {"agent_nav_repo_nav_calls", "agent_nav_collector_section_failed",
                                "agent_nav_collector_success_timestamp_seconds"}
          and t.get(f"agent_nav_repo_nav_calls{{{W}}}") == 0,
          f"a thin window writes the sample sizes (0 included) and the collector series only ({sorted(names)})")

    # a section that raises: its series are left out, its last success timestamp is kept
    before = m
    good, nm.misses = nm.misses, lambda *a: 1 / 0
    rc, _, m = run(out)
    nm.misses = good
    stamp = 'agent_nav_collector_success_timestamp_seconds{section="misses"}'
    check(rc == 0 and m.get('agent_nav_collector_section_failed{section="misses"}') == 1
          and not any(k.startswith("agent_nav_repo_miss_ratio") for k in m) and m.get(stamp) == before[stamp]
          and m.get('agent_nav_collector_section_failed{section="rereads"}') == 0 and f"agent_nav_repeat_read_ratio{{{W}}}" in m,
          "a failed section writes section_failed 1, no series and its previous timestamp; the others are written")

    # the scan fails (the run deadline): every section failed, the file is still written
    deadline, nm.DEADLINE = nm.DEADLINE, time.monotonic() - 1
    rc, _, m = run(out)
    nm.DEADLINE = deadline
    check(rc == 0 and all(m.get(f'agent_nav_collector_section_failed{{section="{s}"}}') == 1 for s in nm.SECTIONS)
          and not any(k.startswith("agent_nav_repo_nav_calls") for k in m),
          "past the run deadline every section writes section_failed 1 and no sample")

    r = subprocess.run([sys.executable, "-I", str(SCRIPT), "--list"], capture_output=True, text=True)
    check(r.returncode == 0 and r.stdout.split() == list(nm.METRICS), "--list prints METRICS, the names the dashboards check reads")

    try:
        nm.Out().add("agent_nav_not_declared", 1)
        check(False, "seeded: a name outside METRICS is refused")
    except AssertionError:
        check(True, "seeded: a name outside METRICS is refused")



def day(path, calls):
    """A worker transcript with `calls` repo Reads (50 files, a prompt every 100) in the last hour, each answered."""
    t0 = time.time() - 1800
    with open(path, "w") as f:
        for i in range(calls):
            at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0 + i * 0.01))
            if i % 100 == 0:
                f.write(json.dumps({"type": "user", "origin": {"kind": "human"}, "timestamp": at,
                                    "cwd": "/home/u/nixos-config", "message": {"role": "user", "content": "go"}}) + "\n")
            f.write(json.dumps({"type": "assistant", "timestamp": at, "cwd": "/home/u/nixos-config", "message": {
                "content": [{"type": "tool_use", "id": f"t{i}", "name": "Read",
                             "input": {"file_path": f"/home/u/nixos-config/modules/m{i % 50}.nix"}}]}}) + "\n")
            f.write(json.dumps({"type": "user", "timestamp": at, "cwd": "/home/u/nixos-config", "message": {
                "content": [{"type": "tool_result", "tool_use_id": f"t{i}", "content": "x" * 200}]}}) + "\n")


def peak_kb(projects, out):
    """The collector's own peak RSS on `projects`, in a fresh interpreter."""
    code = ("import resource, runpy, sys; s, p, o = sys.argv[1:4]; sys.argv = ['nav-metrics.py', '--out', o, '--projects', p]\n"
            "try:\n    runpy.run_path(s, run_name='__main__')\nexcept SystemExit:\n    pass\n"
            "print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)")
    r = subprocess.run([sys.executable, "-I", "-c", code, str(SCRIPT), str(projects), out], capture_output=True, text=True)
    return int(r.stdout.split()[-1]) if r.returncode == 0 and r.stdout.split() else None


# memory is flat in the day's size: 10x the transcript (calls and bytes) adds no per-call or per-line state
with tempfile.TemporaryDirectory() as tmp:
    small, big = pathlib.Path(tmp, "small/-home-u-nixos-config"), pathlib.Path(tmp, "big/-home-u-nixos-config")
    small.mkdir(parents=True)
    big.mkdir(parents=True)
    day(small / "s.jsonl", 10000)
    day(big / "s.jsonl", 100000)
    lo, hi = peak_kb(small.parent, f"{tmp}/a.prom"), peak_kb(big.parent, f"{tmp}/b.prom")
    check(lo is not None and hi is not None and hi - lo < 8 * 1024,
          f"peak RSS is flat in the input: {lo} kB at 10k calls, {hi} kB at 100k ({(big / 's.jsonl').stat().st_size >> 20} MB)")

# the page cache a run reads through is charged to the unit's cgroup: every file's pages are dropped behind it
with tempfile.TemporaryDirectory() as tmp:
    proj = pathlib.Path(tmp, "-home-u-nixos-config")
    proj.mkdir()
    day(proj / "s.jsonl", 3000)
    size = (proj / "s.jsonl").stat().st_size
    calls, real = [], os.posix_fadvise
    every, nm.DROP_EVERY = nm.DROP_EVERY, 64 * 1024
    os.posix_fadvise = lambda fd, off, n, advice: calls.append((off, n, advice))
    try:
        nm.scan(tmp, time.time() - 86400)
    finally:
        os.posix_fadvise, nm.DROP_EVERY = real, every
    dont = [(o, n) for o, n, a in calls if a == os.POSIX_FADV_DONTNEED]
    check(dont and dont[-1] == (0, 0) and len(dont) >= size // (64 * 1024),
          f"each transcript's pages are dropped every DROP_EVERY bytes and at its end ({len(dont)} drops over {size} bytes)")

print(f"{failed} failed")
raise SystemExit(1 if failed else 0)
