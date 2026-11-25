#!/usr/bin/env python3
"""scripts/local-lane.py's gate on fixtures (#807): one good result passes, and a weakened check, a file out of scope,
a check still failing, a diff over 60 lines, a reviewer saying unsafe or something unclear, and a check that already
passes on the prepared commit each fail at their own item."""
import json
import pathlib
import subprocess
import sys
import tempfile

from gate_probe import check, finish

LANE = pathlib.Path(__file__).resolve().parent / "local-lane.py"
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
                          "--task", "Make a.txt say new.", "--reviewer", reviewer], capture_output=True, text=True)
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
    for item, sha in cases.items():
        rc, v = gate(repo, prepared, sha)
        check(rc == 1 and v.get("failed") == item, f"a bad result fails at {item} ({rc}, {v})")

    for said, why in (("unsafe", "unsafe"), ("maybe", "unclear")):
        rc, v = gate(repo, prepared, good, reviewer=f"echo {said}")
        check(rc == 1 and v.get("failed") == "review" and v.get("why") == why, f"a reviewer saying {said} fails the review ({rc}, {v})")

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

finish()
