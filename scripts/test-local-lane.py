#!/usr/bin/env python3
"""scripts/local-lane.py's gate on fixtures (#807): one good result passes, and a weakened check, a file out of scope,
a check still failing, a diff over 60 lines or with a binary file, a reviewer saying unsafe or something unclear or
missing, and a check that already passes on the prepared commit each fail at their own item; `run` against a fake
exec-pool and gh retries once, keeps no credential in the lint's environment, cancels each task, opens and merges the
pull request of a pass and writes one record; with no local model ready it submits nothing and records the skip."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

from gate_probe import check, finish

LANE = pathlib.Path(__file__).resolve().parent / "local-lane.py"
WRITER = LANE.parents[1] / "pkgs/platform-record/platform_record.py"
# exec-pool as the lane calls it: submit pushes pool/<task> with the fixture's first (bad) and then its second (good)
# result to the origin and keeps each prompt; wait returns at once
FAKE_POOL = """#!{python}
import pathlib, subprocess, sys
state = pathlib.Path({state!r})
if sys.argv[1] == "cancel":
    with open(state / "cancelled", "a") as f:
        f.write(sys.argv[2] + "\\n")
if sys.argv[1] == "submit":
    n = len(list(state.glob("prompt-*"))) + 1
    (state / f"prompt-{{n}}").write_text(sys.stdin.read())
    rev = sys.argv[sys.argv.index("--rev") + 1]
    tree = state / f"tree-{{n}}"
    run = lambda *a: subprocess.run(["git", "-C", str(tree), *a], check=True, capture_output=True)
    subprocess.run(["git", "clone", "--quiet", {origin!r}, str(tree)], check=True)
    run("checkout", "--quiet", "--detach", rev)
    (tree / "a.txt").write_text("other\\n" if n == 1 else "new\\n")
    run("-c", "user.name=pi", "-c", "user.email=pi@pi", "commit", "--quiet", "-am", "pi")
    run("push", "--quiet", "origin", f"HEAD:refs/heads/pool/t{{n}}")
    print(f"t{{n}}")
"""
# gh as the lane calls it: logs each call; opening a pull request prints 7, merging it true
FAKE_GH = """#!{python}
import pathlib, sys
with open({log!r}, "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
print("true" if "merge_method=merge" in sys.argv else "7")
"""
CHECK = "import pathlib, sys\nsys.exit(pathlib.Path('a.txt').read_text() != 'new\\n')\n"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, files, msg):
    for name, text in files.items():
        path = pathlib.Path(repo) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def gate(repo, prepared, head, reviewer="echo ok", check_args=("--check", "python3 check.py", "--check-file", "check.py")):
    out = subprocess.run([sys.executable, "-I", str(LANE), "gate", "--repo", repo, "--prepared", prepared,
                          "--head", head, *check_args, "--scope", "a.txt", "--scope", "docs/",
                          "--task", "Make a.txt say new.", "--lint", "none", "--reviewer", reviewer],
                         capture_output=True, text=True)
    return out.returncode, json.loads(out.stdout) if out.stdout.strip() else {"stderr": out.stderr}


with tempfile.TemporaryDirectory() as tmp:
    repo = str(pathlib.Path(tmp) / "r")
    subprocess.run(["git", "init", "--quiet", "-b", "main", repo], check=True)
    base = commit(repo, {"a.txt": "old\n", "b.txt": "b\n"}, "base")
    prepared = commit(repo, {"check.py": CHECK}, "test: red")

    def head(files):
        git(repo, "checkout", "--quiet", "--detach", prepared)
        return commit(repo, files, "pi")

    good = head({"a.txt": "new\n", "docs/n.md": "note\n"})
    rc, v = gate(repo, prepared, good)
    check(rc == 0 and v.get("result") == "passed" and v.get("lines") == 3, f"a good result passes ({rc}, {v})")

    cases = {
        "check-file": head({"check.py": "import sys\nsys.exit(0)\n"}),
        "scope": head({"a.txt": "new\n", "b.txt": "changed\n"}),
        "check": head({"a.txt": "other\n"}),
        "lines": head({"a.txt": "new\n", "docs/long.md": "x\n" * 61}),
    }
    binary = head({"a.txt": "new\n", "docs/blob.bin": "\0" * 10})
    rc, v = gate(repo, prepared, binary)
    check(rc == 1 and v.get("failed") == "lines", f"a binary file fails the line count ({rc}, {v})")
    for item, sha in cases.items():
        rc, v = gate(repo, prepared, sha)
        check(rc == 1 and v.get("failed") == item, f"a bad result fails at {item} ({rc}, {v})")

    for said, why in (("unsafe", "unsafe"), ("maybe", "unclear"), (None, "unclear")):
        rc, v = gate(repo, prepared, good, reviewer=f"echo {said}" if said else "/nonexistent/reviewer")
        check(rc == 1 and v.get("failed") == "review" and v.get("why") == why, f"a reviewer saying {said or 'nothing, missing'} fails the review ({rc}, {v})")

    rc, v = gate(repo, good, good)
    check(rc == 1 and v.get("failed") == "prepare", f"a check that passes on the prepared commit is refused ({rc}, {v})")

    # the check outside the tree (scripts/lane-checks/): the base is the prepared commit, and the check cannot be edited
    script = pathlib.Path(tmp) / "lane-check.py"
    script.write_text(CHECK)
    outside = ("--check-script", str(script))
    for name, sha, rc_want in (("a good result passes", good, 0), ("a check still failing fails", cases["check"], 1)):
        git(repo, "checkout", "--quiet", "--detach", base)
        fixed = commit(repo, {"a.txt": git(repo, "show", f"{sha}:a.txt") + "\n"}, "pi")
        rc, v = gate(repo, base, fixed, check_args=outside)
        check(rc == rc_want and v.get("failed") == ("none" if rc_want == 0 else "check"),
              f"with the check outside the tree, {name} ({rc}, {v})")

    # run: the prepared commit is checked, a bad first result is retried with its gate output, and one record is kept
    origin = str(pathlib.Path(tmp) / "origin.git")
    subprocess.run(["git", "clone", "--quiet", "--bare", repo, origin], check=True)
    state = pathlib.Path(tmp) / "pool"
    (state / "bin").mkdir(parents=True)
    fake = state / "bin/exec-pool"
    fake.write_text(FAKE_POOL.format(python=sys.executable, state=str(state), origin=origin))
    fake.chmod(0o755)
    calls = state / "calls"
    (state / "bin/gh").write_text(FAKE_GH.format(python=sys.executable, log=str(calls)))
    (state / "bin/gh").chmod(0o755)
    ready = pathlib.Path(tmp) / "status-ready.json"
    ready.write_text(json.dumps({"models": [
        {"model": "msi/llama3.1:8b", "tier": 3, "tool_capable": False, "health": {"state": "ready"}},
        {"model": "asus-paddock/q", "tier": 3, "tool_capable": True, "health": {"state": "ready"}}]}))
    down = pathlib.Path(tmp) / "status-down.json"
    down.write_text(ready.read_text().replace('{"state": "ready"}}]', '{"state": "cooling"}}]'))
    spool = pathlib.Path(tmp) / "spool"
    env = {**os.environ, "PATH": f"{state / 'bin'}:{os.environ['PATH']}", "PLATFORM_RECORD": str(WRITER),
           "PLATFORM_RECORD_SPOOL": str(spool), "PLATFORM_RECORD_SHIPPER": "host", "PLATFORM_RECORD_STRICT": "1"}
    run = [sys.executable, "-I", str(LANE), "run", "--repo", origin, "--prepared", base, "--check-script",
           str(script), "--scope", "a.txt", "--task", "Make a.txt say new.", "--lint",
           "test -z \"$CLAUDE_CODE_OAUTH_TOKEN\"", "--reviewer", "echo ok"]
    out = subprocess.run([*run, "--status-url", down.as_uri()], capture_output=True, text=True, env=env)
    check(out.returncode == 3 and "no local model up" in out.stdout and not list(state.glob("prompt-*"))
          and "result=skipped failed=no-local-model attempts=0" in spool.read_text(),
          f"run with no local model ready submits nothing and records the skip ({out.returncode}, {out.stdout})")
    spool.unlink()
    out = subprocess.run([*run, "--status-url", ready.as_uri()], capture_output=True, text=True,
                         env={**env, "CLAUDE_CODE_OAUTH_TOKEN": "planted"})
    lines = [json.loads(line) for line in out.stdout.splitlines()]
    check(out.returncode == 0 and [v["failed"] for v in lines] == ["check", "none"]
          and [v["task"] for v in lines] == ["t1", "t2"], f"run retries a failed result once and passes ({out.returncode}, {lines}, {out.stderr[-300:]})")
    prompts = [(state / f"prompt-{n}").read_text() for n in (1, 2)]
    check(CHECK in prompts[0] and "failed the gate at check" in prompts[1],
          "Pi gets the check's source, and the retry the first attempt's gate output")
    kept = spool.read_text() if spool.is_file() else ""
    check("local-lane model=homelab/local repo=" in kept and "result=passed failed=none attempts=2" in kept
          and "task=t2" in kept and "pr=7" in kept, f"run keeps one local-lane record, the task id in the line only ({kept.strip()[-300:]})")
    made = calls.read_text() if calls.is_file() else ""
    check(made.count("api ") == 2 and "-f head=pool/t2 -f base=main" in made
          and "api -X PUT repos/" in made and "/pulls/7/merge -f merge_method=merge -f sha=" in made,
          f"a pass opens the pull request of pool/t2 into main and merges it with a merge commit ({made})")
    cancels = (state / "cancelled").read_text().split() if (state / "cancelled").is_file() else []
    check(cancels == ["t1", "t2"], f"each gated task is cancelled, so none is left at needs_review ({cancels})")

finish()
