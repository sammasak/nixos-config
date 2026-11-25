#!/usr/bin/env python3
"""The scheduled full gate on main (modules/homelab/scheduled-gate.nix): fetch origin/main into its own clone and, when
main has moved since the last finished run, run `devenv tasks run nixos:qa` in a worktree just added at that commit.
A red head is run once more on the next timer: a failure outside the tree (a fetch, the cache, the heavy lock's
holder) clears itself, and only a red that repeats on that head waits for a fix on main.
nixos:qa takes the heavy-work lock itself, waiting for it, and writes the gate and step records (mode=scheduled), as
a push did. This program keeps the last finished run in STATE/state.json and writes the node-exporter textfile the
ScheduledGateRed and ScheduledGateOverdue alerts read (modules/homelab/monitoring/rules/shipping.nix). A run killed
before nixos:qa returns records nothing here, so the next timer run tries that head again.

Usage: scheduled-gate --repo URL --state DIR --metrics FILE
       scheduled-gate --list    the metric names it writes (flake-modules/grafana-dashboards-check.nix)"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime

METRICS: dict[str, str] = {
    "homelab_scheduled_gate_checked_timestamp_seconds": "When the scheduled gate last read origin/main.",
    "homelab_scheduled_gate_finished_timestamp_seconds": "When the last scheduled full gate finished, 0 if none has.",
    "homelab_scheduled_gate_green_timestamp_seconds": "When the last passing scheduled full gate started, 0 if none "
    "has.",
    "homelab_scheduled_gate_green_deferred": "1 per step and check the last passing scheduled full gate deferred to "
    "its owner host: that green says nothing about it.",
    "homelab_scheduled_gate_main_behind": "1 while origin/main is not the commit the last finished full gate ran on.",
    "homelab_scheduled_gate_behind_since_timestamp_seconds": "When a check first saw main move past the last finished "
    "gate, 0 while it has not.",
    "homelab_scheduled_gate_seconds": "How long the last finished scheduled full gate took, its lock wait included.",
    "homelab_scheduled_gate_red": "1 when the last finished scheduled full gate failed: its head, first failed step, "
    "the check inside it (empty for none) and the last green head.",
}


@dataclass
class State:
    """The last finished run. green is the newest head a run passed on, "" before any did, green_at when that run
    started (a failure recorded while it ran is not one it fixed) and green_deferred the "step\tcheck" units it
    deferred to their owner host; retried is set when this red head was already run again. check is the failed
    step's inner check (the flake check's), "" for none."""

    head: str = ""
    result: str = ""
    finished: float = 0.0
    seconds: float = 0.0
    step: str = ""
    check: str = ""
    green: str = ""
    behind_since: float = 0.0
    green_at: float = 0.0
    green_deferred: list[str] = field(default_factory=list)
    retried: bool = False


def say(text: str) -> None:
    print(f"scheduled-gate: {text}", file=sys.stderr, flush=True)


def git(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def load(path: pathlib.Path) -> State:
    try:
        raw = json.loads(path.read_text())
        st = State(**{k: raw[k] for k in asdict(State()) if k in raw})
    except (OSError, ValueError, TypeError):
        return State()
    # an older run wrote "step (check)" in step: published as is, the alerts' rerun command would not parse
    if not st.check and st.step.endswith(")") and " (" in st.step:
        st.step, _, rest = st.step.partition(" (")
        st.check = rest[:-1]
    return st


def save(path: pathlib.Path, st: State) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(asdict(st), sort_keys=True) + "\n")
    tmp.replace(path)


def label(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def write_metrics(path: pathlib.Path, st: State, checked: float, main: str) -> None:
    """Renamed into place, its temporary name not *.prom: node-exporter never reads half a file."""
    values: dict[str, list[tuple[str, float]]] = {
        "homelab_scheduled_gate_checked_timestamp_seconds": [("", checked)],
        "homelab_scheduled_gate_finished_timestamp_seconds": [("", st.finished)],
        "homelab_scheduled_gate_green_timestamp_seconds": [("", st.green_at)],
        "homelab_scheduled_gate_main_behind": [("", float(main != st.head))],
        "homelab_scheduled_gate_behind_since_timestamp_seconds": [("", st.behind_since if main != st.head else 0.0)],
        "homelab_scheduled_gate_seconds": [("", st.seconds)],
        "homelab_scheduled_gate_red": [],
        "homelab_scheduled_gate_green_deferred": [],
    }
    for unit in sorted(set(st.green_deferred)):
        step, _, check = unit.partition("\t")
        values["homelab_scheduled_gate_green_deferred"].append((f'step="{label(step)}",check="{label(check)}"', 1.0))
    if st.result == "fail":
        labels = f'head="{st.head[:12]}",step="{label(st.step)}",check="{label(st.check)}",green="{st.green[:12] or "none"}"'
        values["homelab_scheduled_gate_red"].append((labels, 1.0))
    lines = []
    for name, help_text in METRICS.items():
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} gauge"]
        lines += [f"{name}{{{lbl}}} {round(v)}" if lbl else f"{name} {round(v)}" for lbl, v in values[name]]
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(path)


def records(spool: pathlib.Path, since: datetime, head: str) -> list[dict[str, str]]:
    """This run's nixos-qa gate-step records of `head`, in order. The spool's lines are "STAMP KIND key=value..."
    (pkgs/platform-record)."""
    try:
        lines = spool.read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        parts = line.split(" ")
        if len(parts) < 3 or parts[1] != "gate-step":
            continue
        try:
            if datetime.fromisoformat(parts[0]) < since:
                continue
        except ValueError:
            continue
        f = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
        sha = f.get("sha") or f.get("head", "")
        if f.get("gate") == "nixos-qa" and sha and head.startswith(sha[:7]):
            out.append(f)
    return out


def deferred(spool: pathlib.Path, since: datetime, head: str) -> list[str]:
    return [
        f"{f.get('step', '')}\t{f.get('check', '')}"
        for f in records(spool, since, head)
        if f.get("result") == "deferred"
    ]


def first_failed_step(spool: pathlib.Path, since: datetime, head: str) -> tuple[str, str]:
    """The first gate-step record of this run that failed, as (step, check): a check inside the flake check names its
    check, "" otherwise; ("unrecorded", "") when nixos:qa failed before its first step (a devenv evaluation error, the
    devenv-fresh guard): its journal says why."""
    for f in records(spool, since, head):
        if f.get("result") == "fail":
            return f.get("step", "unrecorded"), f.get("check", "")
    return "unrecorded", ""


def run(repo: str, state_dir: pathlib.Path, metrics: pathlib.Path) -> int:
    clone, tree = state_dir / "repo", state_dir / "tree"
    state_file, spool = state_dir / "state.json", state_dir / "platform-records"
    if not (clone / ".git").exists():
        shutil.rmtree(clone, ignore_errors=True)
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", repo, str(clone)], check=True)
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main", cwd=clone)
    main = git("rev-parse", "refs/remotes/origin/main", cwd=clone)
    st = load(state_file)
    if main != st.head and not st.behind_since:
        st.behind_since = time.time()
        save(state_file, st)
    write_metrics(metrics, st, time.time(), main)
    retry = main == st.head and st.result == "fail" and not st.retried
    if main == st.head and not retry:
        say(f"origin/main is {main[:12]}, gated already ({st.result}): nothing to run")
        return 0
    if tree.exists():
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=clone, check=False)
        shutil.rmtree(tree, ignore_errors=True)
    git("worktree", "prune", cwd=clone)
    git("worktree", "add", "--quiet", "--detach", str(tree), main, cwd=clone)
    last = "again, once: it was red" if retry else f"last finished: {st.head[:12] or 'none'}"
    say(f"full gate on origin/main {main[:12]} ({last})")
    env = {
        **os.environ,
        "NIXOS_QA_MODE": "scheduled",
        "NIXOS_QA_TIMES": str(state_dir / "nixos-qa-times"),
        "PLATFORM_RECORD_SPOOL": str(spool),
    }
    since = datetime.now().astimezone().replace(microsecond=0)
    start = time.monotonic()
    try:
        rc = subprocess.run(["devenv", "tasks", "run", "nixos:qa"], cwd=tree, env=env, check=False).returncode
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=clone, check=False)
    st.head, st.finished, st.seconds = main, time.time(), round(time.monotonic() - start)
    st.behind_since, st.retried = 0.0, retry
    if rc == 0:
        st.result, st.step, st.check, st.green = "pass", "", "", main
        st.green_at, st.green_deferred = st.finished - st.seconds, deferred(spool, since, main)
    else:
        st.result = "fail"
        st.step, st.check = first_failed_step(spool, since, main)
    save(state_file, st)
    write_metrics(metrics, st, time.time(), main)
    say(f"{st.result} on {main[:12]} in {st.seconds:g} s" + (f", first failed step {st.step}" if st.step else "")
        + (f", check {st.check}" if st.check else ""))
    # a red gate is ScheduledGateRed's to report; a failed unit means the scheduler itself broke
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="scheduled-gate")
    p.add_argument("--list", action="store_true")
    p.add_argument("--repo")
    p.add_argument("--state", type=pathlib.Path)
    p.add_argument("--metrics", type=pathlib.Path)
    a = p.parse_args(argv)
    if a.list:
        print("\n".join(METRICS))
        return 0
    if not (a.repo and a.state and a.metrics):
        p.error("--repo, --state and --metrics are required")
    return run(a.repo, a.state, a.metrics)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
