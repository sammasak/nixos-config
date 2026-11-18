#!/usr/bin/env python3
"""The navigation collector (scripts/nav-metrics.py) on fixture transcripts in a temporary HOME: a worker session in a
nixos-config checkout (Read, Grep, Glob and Bash navigation, a missed lookup, repeat reads, an Edit, a malformed line,
an event older than the window) and a coordinator session named as such. The exported values; no prompt, command or
path in the textfile; a thin role writes its sample size alone; a failed section writes section_failed 1 and keeps its
last timestamp; `--list` is METRICS. Seeded: a name outside METRICS is refused. The owner's file, timestamps aside, is
GOLDEN, its text before guests were read.

Guests (--worker): a temp state dir whose instances hold the same transcripts get the same series with worker=<name>;
a link anywhere on an instance's path (the instance dir, home, .claude, projects, a project dir, a transcript) or a
FIFO transcript is refused and counted, and nothing behind it is read; label-like text in a transcript never changes
a label; the file and size caps; the homes are left as they were. One process per guest, as the units run it: each
file holds its own worker's series alone, a second --worker is refused, and a guest whose run crashes leaves the
others' files written and its own last one intact. The per-session state caps (lowered here): files read, calls
pending, a stretch's directories, the run's stretches, a Bash command's length each abandon the transcript with none of
its counts kept; at the real caps 400,000 distinct reads and a 2 MiB command stay well under the guest unit's MemoryMax.
Usage: test-nav-metrics.py [SCRIPT] (a mutated copy for a seed)."""
import importlib.util
import json
import os
import pathlib
import re
import resource
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "scripts/nav-metrics.py"
failed = 0
GOLDEN = """\
# HELP agent_nav_repo_nav_calls Navigation calls on a nixos-config checkout that got a result in the window: the sample size, always written.
# TYPE agent_nav_repo_nav_calls gauge
agent_nav_repo_nav_calls{role="coordinator"} 2
agent_nav_repo_nav_calls{role="worker"} 57
# HELP agent_nav_stretches Repo stretches in the window: prompts whose tool calls navigated the repo or changed a file in it.
# TYPE agent_nav_stretches gauge
agent_nav_stretches{role="worker"} 2
# HELP agent_nav_calls_before_first_edit Navigation calls before the first Edit/Write of a repo stretch (or its end), by quantile.
# TYPE agent_nav_calls_before_first_edit gauge
agent_nav_calls_before_first_edit{quantile="0.5",role="worker"} 28.5
agent_nav_calls_before_first_edit{quantile="0.9",role="worker"} 45.7
# HELP agent_nav_topdirs_before_first_edit Distinct top-level repo directories navigated before the first Edit/Write of a repo stretch, by quantile.
# TYPE agent_nav_topdirs_before_first_edit gauge
agent_nav_topdirs_before_first_edit{quantile="0.5",role="worker"} 2
agent_nav_topdirs_before_first_edit{quantile="0.9",role="worker"} 2.8
# HELP agent_nav_repo_miss_ratio Share of repo navigation calls whose result was an error, empty, no match or no such file.
# TYPE agent_nav_repo_miss_ratio gauge
agent_nav_repo_miss_ratio{role="worker"} 0.0350877192982456
# HELP agent_nav_repo_reads Reads of repo files (Read, cat, head, tail, sed -n) in the window.
# TYPE agent_nav_repo_reads gauge
agent_nav_repo_reads{role="worker"} 54
# HELP agent_nav_repeat_read_ratio Share of repo file reads that read a file the same session already read in the window.
# TYPE agent_nav_repeat_read_ratio gauge
agent_nav_repeat_read_ratio{role="worker"} 0.851851851851852
# HELP agent_nav_collector_section_failed 1 when the section failed this run (an error or the run deadline), else 0.
# TYPE agent_nav_collector_section_failed gauge
agent_nav_collector_section_failed{section="scan"} 0
agent_nav_collector_section_failed{section="stretches"} 0
agent_nav_collector_section_failed{section="misses"} 0
agent_nav_collector_section_failed{section="rereads"} 0
# HELP agent_nav_collector_success_timestamp_seconds Unix time a section last collected without error.
# TYPE agent_nav_collector_success_timestamp_seconds gauge
agent_nav_collector_success_timestamp_seconds{section="scan"} <ts>
agent_nav_collector_success_timestamp_seconds{section="stretches"} <ts>
agent_nav_collector_success_timestamp_seconds{section="misses"} <ts>
agent_nav_collector_success_timestamp_seconds{section="rereads"} <ts>
"""


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

    masked = re.sub(r"(_timestamp_seconds\{[^}]*\}) \S+", r"\1 <ts>", text)
    check(masked == GOLDEN, "the owner's file is byte-identical to before guests were read (timestamps aside)"
          + ("" if masked == GOLDEN else f"\n{masked}"))
    owner = {k: v for k, v in run(f"{tmp}/owner.prom")[2].items() if "_timestamp_" not in k}

    # guests: the instances' homes in a state dir, and what a link out of one would reach
    state, outside = pathlib.Path(tmp, "workers"), pathlib.Path(tmp, "outside")
    w.write(outside / ".claude/projects/-x/s.jsonl")

    def instance(name):
        return state / name / "home/.claude/projects"

    w.write(instance("herman") / "-home-nixos-config/worker.jsonl")
    c.write(instance("herman") / "-home/coordinator.jsonl")
    sub.write(instance("herman") / "-home-nixos-config/worker/subagents/agent-a.jsonl")
    LINKS = {  # an instance whose path holds a link: where it is, and the outside target
        "l-inst": (state / "l-inst", outside.parent / "outside-inst"),
        "l-home": (state / "l-home/home", outside),
        "l-claude": (state / "l-claude/home/.claude", outside / ".claude"),
        "l-projects": (instance("l-projects"), outside / ".claude/projects"),
        "l-dir": (instance("l-dir") / "-x", outside / ".claude/projects/-x"),
        "l-file": (instance("l-file") / "-x/s.jsonl", outside / ".claude/projects/-x/s.jsonl"),
    }
    (outside.parent / "outside-inst").mkdir()
    os.symlink(outside, outside.parent / "outside-inst/home")
    for link, target in LINKS.values():
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, link)
    (instance("fifo") / "-x").mkdir(parents=True)
    os.mkfifo(instance("fifo") / "-x/s.jsonl")
    # a good transcript beside a linked one: the link alone is refused
    w.write(instance("half") / "-x/s.jsonl")
    os.symlink(outside / ".claude/projects/-x/s.jsonl", instance("half") / "-x/t.jsonl")

    # label-like text everywhere a transcript has text: the session's name, its cwd, a prompt, a path
    evil = 'coordinator",worker="lenovo"} 1\nagent_nav_repo_nav_calls{role="x'
    inj = Session('/home/u/nixos-config"} 9\n#', name=evil)
    inj.prompt('worker="lenovo",role="admin"} 1')
    for i in range(60):
        inj.call("Read", {"file_path": f'/home/u/nixos-config/a{i % 3}"}},worker="x'}, result='"} 1\nfoo{a="b')
    inj.write(instance("inject") / "-x/s.jsonl")

    # the caps: past FILES_MAX; over FILE_MAX (sparse); a line over LINE_MAX holding a call; a file older than the window
    for i in range(nm.FILES_MAX + 3):
        one = Session("/home/u/nixos-config")
        one.call("Read", {"file_path": f"/home/u/nixos-config/m{i}.nix"})
        one.write(instance("many") / f"-x/{i}.jsonl")
    big = instance("big") / "-x"
    big.mkdir(parents=True)
    with open(big / "huge.jsonl", "wb") as f:
        f.truncate(nm.FILE_MAX + 1)
    long_ = Session("/home/u/nixos-config")
    long_.call("Read", {"file_path": "/home/u/nixos-config/long.nix", "pad": "x" * nm.LINE_MAX})
    long_.call("Read", {"file_path": "/home/u/nixos-config/short.nix"})
    long_.write(big / "long.jsonl")
    w.write(big / "old.jsonl")
    os.utime(big / "old.jsonl", (NOW - 30 * 3600, NOW - 30 * 3600))

    def tree(root):
        return sorted((str(q), os.lstat(q).st_mtime_ns, q.is_file() and not q.is_symlink() and q.stat().st_size < 1 << 20
                       and q.read_bytes()) for q in root.rglob("*") if not q.is_fifo())

    names = ["herman", *LINKS, "fifo", "half", "inject", "many", "big", "absent"]
    homes_before = tree(state), tree(outside)

    def guest(out, *argv):
        try:
            r = subprocess.run([sys.executable, "-I", str(SCRIPT), "--out", out, *argv], capture_output=True, text=True,
                               timeout=60)
        except subprocess.TimeoutExpired:
            return None, "", {}
        try:
            text = pathlib.Path(out).read_text()
        except OSError:
            return r.returncode, "", {}
        rows = [l for l in text.splitlines() if l and not l.startswith("#")]
        return r.returncode, text, {l.rsplit(" ", 1)[0]: float(l.rsplit(" ", 1)[1]) for l in rows}

    # one process and file per guest, as the nav-metrics-guest@ units run it
    gdir = pathlib.Path(tmp, "guests")
    gdir.mkdir()
    runs = {n: guest(f"{gdir}/nav-guest-{n}.prom", "--state-dir", str(state), "--home", str(home), "--worker", n)
            for n in names}
    rcs = {n: r[0] for n, r in runs.items() if r[0] != 0}
    check(not rcs, f"a guest run for every instance exits 0 ({rcs})")
    gtext = "".join(r[1] for r in runs.values())
    g = {k: v for r in runs.values() for k, v in r[2].items()}
    check(all(r[2] and all(f'worker="{n}"' in k for k in r[2]) for n, r in runs.items())
          and len(g) == sum(len(r[2]) for r in runs.values()),
          "each guest's file holds its own worker's series alone, the collector's included: no two files share a series")

    def as_worker(key, name):
        base, _, lab = key.partition("{")
        pairs = re.findall(r'(\w+)="([^"]*)"', lab) + [("worker", name)]
        return base + "{" + ",".join(f'{k}="{v}"' for k, v in sorted(pairs)) + "}"

    want = {as_worker(k, "herman"): v for k, v in owner.items()}
    got = {k: v for k, v in g.items() if 'worker="herman"' in k and "_timestamp_" not in k and "_skipped" not in k}
    check(got == want, f"an instance with the owner's transcripts gets the owner's series with worker=\"herman\" "
          f"({len(got)} series; differ: {sorted(set(got.items()) ^ set(want.items()))[:4]})")
    check(all(g.get(f'agent_nav_collector_skipped{{reason="{r}",worker="herman"}}') == 0 for r in nm.SKIPS),
          "an instance with nothing to refuse skips nothing (every reason written as 0)")

    def calls(name):
        return sum(v for k, v in g.items() if k.startswith("agent_nav_repo_nav_calls{") and f'worker="{name}"' in k)

    def skipped(name, reason):
        return g.get(f'agent_nav_collector_skipped{{reason="{reason}",worker="{name}"}}')

    for name in [*LINKS, "fifo"]:
        check(skipped(name, "refused") == 1 and calls(name) == 0,
              f"{name}: a link or FIFO on the path is refused and counted, and nothing behind it is read "
              f"(refused {skipped(name, 'refused')}, calls {calls(name)})")
    check(skipped("half", "refused") == 1 and calls("half") == 57,
          f"a linked transcript beside a good one: the link refused, the good one read ({calls('half')})")
    check(calls("absent") == 0 and all(skipped("absent", r) == 0 for r in nm.SKIPS)
          and g.get('agent_nav_collector_section_failed{section="scan",worker="absent"}') == 0,
          "an instance without a home is empty, not refused")
    check(skipped("many", "too_many") == 3 and calls("many") == nm.FILES_MAX,
          f"past FILES_MAX a transcript is counted too_many, not read ({skipped('many', 'too_many')}, {calls('many')})")
    check(skipped("big", "too_large") == 1 and calls("big") == 1 and skipped("big", "too_many") == 0,
          f"a file over FILE_MAX is too_large; a line over LINE_MAX is skipped, the next read; an old file is neither "
          f"({skipped('big', 'too_large')}, {calls('big')})")

    labels = re.findall(r'[{,]([a-z_]+)="([^"]*)"', gtext)
    allowed = {"role": set(nm.ROLES), "quantile": {"0.5", "0.9"}, "section": set(nm.SECTIONS), "reason": set(nm.SKIPS),
               "worker": set(names)}
    bad = sorted({(k, v) for k, v in labels if v not in allowed.get(k, ())})
    grammar = re.compile(r'# (HELP|TYPE) agent_nav_[a-z_]+ .*|agent_nav_[a-z_]+\{[a-z_]+="[a-z0-9._-]+"(,[a-z_]+="[a-z0-9._-]+")*\} '
                         r'-?[0-9.e+-]+')
    check(not bad and all(grammar.fullmatch(l) for l in gtext.splitlines()) and calls("inject") == 60
          and 'agent_nav_repo_nav_calls{role="coordinator",worker="inject"} 60' in gtext and "lenovo" not in gtext
          and "admin" not in gtext,
          f"label-like text in a session's name, cwd, prompt or paths changes no label: every value is a declared "
          f"name or a fixed one, every line a plain sample ({bad[:4]})")
    check((tree(state), tree(outside)) == homes_before, "the guests' homes and the outside are left as they were")
    rc, _, _ = guest(f"{tmp}/bad.prom", "--state-dir", str(state), "--home", str(home), "--worker", 'x"}')
    check(rc not in (0, None) and not os.path.exists(f"{tmp}/bad.prom"), "a worker name outside [a-z][a-z0-9-]{0,10} is refused")
    rc, _, _ = guest(f"{tmp}/two.prom", "--state-dir", str(state), "--home", str(home), "--worker", "herman", "--worker", "half")
    check(rc not in (0, None) and not os.path.exists(f"{tmp}/two.prom"),
          "a second --worker is refused: one guest per process, so one guest's run cannot take another's down")

    # isolation: a guest whose run dies (an OOM kill, simulated by an address-space limit Python cannot start under)
    # leaves the other guest's file written and fresh, and its own last file whole
    crash_prom, ok_prom = gdir / "nav-guest-half.prom", gdir / "nav-guest-herman.prom"
    crash_before, t0 = crash_prom.read_bytes(), time.time()
    time.sleep(0.01)

    def oom():
        resource.setrlimit(resource.RLIMIT_AS, (8 << 20, 8 << 20))

    dead = subprocess.run([sys.executable, "-I", str(SCRIPT), "--out", str(crash_prom), "--state-dir", str(state),
                           "--home", str(home), "--worker", "half"], capture_output=True, preexec_fn=oom, timeout=60)
    rc, _, alive = guest(str(ok_prom), "--state-dir", str(state), "--home", str(home), "--worker", "herman")
    fresh = [v for k, v in alive.items() if k.startswith("agent_nav_collector_success_timestamp_seconds")]
    check(dead.returncode != 0 and rc == 0 and ok_prom.stat().st_mtime >= t0 and len(fresh) == 4
          and min(fresh) >= t0 and crash_prom.read_bytes() == crash_before,
          f"a guest's run that dies costs the other guest nothing: its file is rewritten with fresh timestamps, and the "
          f"dead one's last file is left whole (died rc {dead.returncode}, other rc {rc})")



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


def peak_kb(projects, out, *argv):
    """The collector's own peak RSS on `projects` (or with `argv`), in a fresh interpreter: VmHWM, not ru_maxrss, which
    keeps the RSS of this process when it forked."""
    argv = argv or ("--projects", str(projects))
    code = ("import re, runpy, sys; sys.argv = ['nav-metrics.py', '--out', *sys.argv[2:]]\n"
            "try:\n    runpy.run_path(sys.argv[0] if False else SCRIPT, run_name='__main__')\nexcept SystemExit:\n    pass\n"
            "print(re.search(r'VmHWM:\\s+(\\d+)', open('/proc/self/status').read()).group(1))")
    code = code.replace("sys.argv[0] if False else SCRIPT", repr(str(SCRIPT)))
    r = subprocess.run([sys.executable, "-I", "-c", code, "-", out, *argv], capture_output=True, text=True)
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

# the per-session state caps, lowered to 50 (CMD_MAX to 400): each abandons the transcript, none of its counts kept
with tempfile.TemporaryDirectory() as tmp:
    since, cwd = time.time() - 86400, "/u/nixos-config"

    def pending(s, n):
        for i in range(n):
            s.raw(json.dumps({"type": "assistant", "timestamp": iso(1), "cwd": cwd, "message": {"content": [
                {"type": "tool_use", "id": f"p{i}", "name": "Grep", "input": {"pattern": "x"}}]}}))

    def stretches(s, n):
        for _ in range(n):
            s.prompt("p")
            s.call("Read", {"file_path": f"{cwd}/m/a.nix"})

    CASES = {  # name: what the transcript holds after one counted call, n at the cap and one over
        "files read": lambda s, n: [s.call("Read", {"file_path": f"{cwd}/m/f{i}.nix"}) for i in range(n)],
        "calls pending": pending,
        "a stretch's directories": lambda s, n: [s.prompt("p"), s.call("Bash", {"command": "ls " + " ".join(f"d{i}/" for i in range(n))})],
        "stretches": stretches,
        "a Bash command's length": lambda s, n: s.call("Bash", {"command": "ls " + "x" * (n * 8 - 3)}),
    }
    caps = nm.STATE_MAX, nm.CMD_MAX
    nm.STATE_MAX, nm.CMD_MAX = 50, 400
    try:
        for name, build in CASES.items():
            got = []
            for n in (50, 51):
                s = Session(cwd)
                s.call("Grep", {"pattern": "x"})
                build(s, n)
                path = pathlib.Path(tmp, f"{len(got)}-{n}.jsonl")
                s.write(path)
                skipped = dict.fromkeys(nm.SKIPS, 0)
                t = nm.scan(None, since, [str(path)], skipped)
                got.append((skipped["too_much_state"], sum(r["judged"] + r["reads"] + len(r["before"]) for r in t.values())))
            check(got[0][0] == 0 and got[0][1] > 0 and got[1] == (1, 0),
                  f"{name}: at the cap the transcript counts, one over it is abandoned (too_much_state) and none of its "
                  f"counts kept (skipped, counts at the cap and over: {got})")
        # the run's stretches, across transcripts: the one that passes the cap is abandoned, those before it count
        paths = []
        for i in range(2):
            s = Session(cwd)
            stretches(s, 30)
            paths.append(pathlib.Path(tmp, f"run-{i}.jsonl"))
            s.write(paths[-1])
        skipped = dict.fromkeys(nm.SKIPS, 0)
        t = nm.scan(None, since, [str(p) for p in paths], skipped)
        n = sum(len(r["before"]) for r in t.values())
        check(n == 30 and skipped["too_much_state"] == 1,
              f"the run's stretches are capped across transcripts: the second 30 abandoned, the first kept ({n})")
    finally:
        nm.STATE_MAX, nm.CMD_MAX = caps


def guest_peak(tmp, write):
    """A one-transcript guest `g` written by write(file), as the guest unit runs it: peak kB and its skipped counts."""
    d = pathlib.Path(tmp, "state/g/home/.claude/projects/-x")
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "s.jsonl", "w") as f:
        write(f)
    out = f"{tmp}/g.prom"
    kb = peak_kb(None, out, "--state-dir", f"{tmp}/state", "--home", "/home/u", "--worker", "g")
    text = pathlib.Path(out).read_text() if os.path.exists(out) else ""
    (d / "s.jsonl").unlink()
    return kb, dict(re.findall(r'agent_nav_collector_skipped\{reason="(\w+)",worker="g"\} (\S+)', text))


def distinct_reads(f, n=400000):
    """n Reads of n distinct repo files, none answered (streamed: about 60 MB)."""
    at = iso(0.5)
    f.write(json.dumps({"type": "user", "origin": {"kind": "human"}, "timestamp": at, "message": {"content": "go"}}) + "\n")
    for i in range(n):
        f.write(f'{{"type": "assistant", "timestamp": "{at}", "message": {{"content": [{{"type": "tool_use", '
                f'"id": "t{i}", "name": "Read", "input": {{"file_path": "/home/u/nixos-config/m/{i:06d}.nix"}}}}]}}}}\n')


def long_command(f):
    """One Bash command just under LINE_MAX: some 300,000 repo paths to cat."""
    cmd = "cat " + " ".join(f"a{i}" for i in range(300000))
    f.write(json.dumps({"type": "assistant", "timestamp": iso(0.5), "cwd": "/home/u/nixos-config", "message": {
        "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": cmd[:2 * 1024 * 1024 - 400]}}]}}) + "\n")


# at the real caps a transcript that would grow the state without bound stays well within the guest unit's MemoryMax
unit = (ROOT / "modules/homelab/nav-metrics.nix").read_text().split('"nav-metrics-guest@"', 1)[1]
memory_max = int(re.search(r'MemoryMax = "(\d+)M"', unit).group(1)) * 1024
with tempfile.TemporaryDirectory() as tmp:
    for what, write in (("400,000 distinct repo files read", distinct_reads), ("a 2 MiB Bash command", long_command)):
        kb, skipped = guest_peak(tmp, write)
        check(kb is not None and kb < memory_max * 3 // 4 and skipped.get("too_much_state") == "1",
              f"{what}: abandoned as too_much_state at a peak of {kb} kB, under 3/4 of the unit's MemoryMax "
              f"({memory_max} kB; skipped {skipped})")

print(f"{failed} failed")
raise SystemExit(1 if failed else 0)
