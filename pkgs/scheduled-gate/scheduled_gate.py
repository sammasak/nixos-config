#!/usr/bin/env python3
"""The scheduled full gate on main (modules/homelab/scheduled-gate.nix): fetch origin/main into its own clone and, when
main has moved since the last finished run, run `devenv tasks run nixos:qa` in a worktree just added at that commit.
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
from dataclasses import asdict, dataclass
from datetime import datetime

METRICS: dict[str, str] = {
    "homelab_scheduled_gate_checked_timestamp_seconds": "When the scheduled gate last read origin/main.",
    "homelab_scheduled_gate_finished_timestamp_seconds": "When the last scheduled full gate finished, 0 if none has.",
    "homelab_scheduled_gate_main_behind": "1 while origin/main is not the commit the last finished full gate ran on.",
    "homelab_scheduled_gate_behind_since_timestamp_seconds": "When a check first saw main move past the last finished "
    "gate, 0 while it has not.",
    "homelab_scheduled_gate_seconds": "How long the last finished scheduled full gate took, its lock wait included.",
    "homelab_scheduled_gate_red": "1 when the last finished scheduled full gate failed: its head, first failed step "
    "and the last green head.",
}


@dataclass
class State:
    """The last finished run. green is the newest head a run passed on, "" before any did."""

    head: str = ""
    result: str = ""
    finished: float = 0.0
    seconds: float = 0.0
    step: str = ""
    green: str = ""
    behind_since: float = 0.0


def say(text: str) -> None:
    print(f"scheduled-gate: {text}", file=sys.stderr, flush=True)


def git(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def load(path: pathlib.Path) -> State:
    try:
        raw = json.loads(path.read_text())
        return State(**{k: raw[k] for k in asdict(State()) if k in raw})
    except (OSError, ValueError, TypeError):
        return State()


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
        "homelab_scheduled_gate_main_behind": [("", float(main != st.head))],
        "homelab_scheduled_gate_behind_since_timestamp_seconds": [("", st.behind_since if main != st.head else 0.0)],
        "homelab_scheduled_gate_seconds": [("", st.seconds)],
        "homelab_scheduled_gate_red": [],
    }
    if st.result == "fail":
        labels = f'head="{st.head[:12]}",step="{label(st.step)}",green="{st.green[:12] or "none"}"'
        values["homelab_scheduled_gate_red"].append((labels, 1.0))
    lines = []
    for name, help_text in METRICS.items():
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} gauge"]
        lines += [f"{name}{{{lbl}}} {round(v)}" if lbl else f"{name} {round(v)}" for lbl, v in values[name]]
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(path)


def first_failed_step(spool: pathlib.Path, since: datetime, head: str) -> str:
    """The first gate-step record of this run that failed: a check inside the flake check names its check too. The
    spool's lines are "STAMP KIND key=value..." (pkgs/platform-record); "unrecorded" when nixos:qa failed before its
    first step (a devenv evaluation error, the devenv-fresh guard): its journal says why."""
    try:
        lines = spool.read_text().splitlines()
    except OSError:
        return "unrecorded"
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
        if f.get("gate") != "nixos-qa" or f.get("result") != "fail" or not sha or not head.startswith(sha[:7]):
            continue
        step = f.get("step", "unrecorded")
        return f"{step} ({f['check']})" if f.get("check") else step
    return "unrecorded"


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
    if main == st.head:
        say(f"origin/main is {main[:12]}, gated already ({st.result}): nothing to run")
        return 0
    if tree.exists():
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=clone, check=False)
        shutil.rmtree(tree, ignore_errors=True)
    git("worktree", "prune", cwd=clone)
    git("worktree", "add", "--quiet", "--detach", str(tree), main, cwd=clone)
    say(f"full gate on origin/main {main[:12]} (last finished: {st.head[:12] or 'none'})")
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
    st.behind_since = 0.0
    if rc == 0:
        st.result, st.step, st.green = "pass", "", main
    else:
        st.result, st.step = "fail", first_failed_step(spool, since, main)
    save(state_file, st)
    write_metrics(metrics, st, time.time(), main)
    say(f"{st.result} on {main[:12]} in {st.seconds:g} s" + (f", first failed step {st.step}" if st.step else ""))
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
