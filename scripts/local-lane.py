#!/usr/bin/env python3
"""The local-model lane (#807): Pi on a local model takes one prepared task, and a gate that never takes its word
decides. goals.md "Quality gate for a local-model task" is the contract; items 1 to 5 below are its numbers.

  gate --repo DIR --prepared SHA --head SHA (--check CMD --check-file PATH... | --check-script FILE)
       --scope PATH... --task TEXT --lint CMD|none [--reviewer CMD|none] [--check-timeout S]
      Items 1 to 5 on two commits of a local clone; prints one JSON line, exit 0 pass, 1 fail.
  run  --repo URL --prepared SHA (the gate's flags but --head) [--model M] [--timeout S] [--key K]
      Item 1 on the prepared commit, then `exec-pool submit --agent pi`, wait, the gate on its pushed
      pool/<task> branch, one retry with the gate's output on a fail, and one `local-lane` platform record.

The hosted agent's check either sits in the repository (the prepared commit is the base plus the check, and item 2
holds the check files to it) or is a Python FILE outside it (scripts/lane-checks/), run from the tree's root: then the
prepared commit is the base itself, the gate runs its own copy, and Pi gets the source to run as /tmp/lane-check.py, so
item 2 holds by construction. Either way it must fail on the prepared commit. A `dir/` scope covers what is under it. The reviewer reads a prompt on stdin and must print exactly ok, unsafe or "does not fix the problem" on its
first line; anything else, its crash included, fails closed. The check and the lint run under `sh -c` in a detached
worktree at each commit, without the environment's credential-like variables (SECRET); `--lint none` leaves item 4 at
`git diff --check`."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

MAX_LINES = 60
REVIEWER = "claude -p --model haiku"
VERDICTS = ("ok", "unsafe", "does not fix the problem")
TAIL = 3000
# what the check and the lint, which can run model-written code, do not inherit
SECRET = re.compile(r"TOKEN|SECRET|KEY|PASS|AUTH|CREDENTIAL|COOKIE", re.I)

REVIEW_PROMPT = """You review a change a small local model made for this task. Answer with exactly one line: \
ok, unsafe, or does not fix the problem. Say unsafe only if the change could do harm (deletes data, weakens a check \
or a security boundary, leaks a secret, runs something it should not). Say does not fix the problem only if the diff \
does not do what the task asks. Style, naming and missing polish are ok.

Task:
{task}

Diff:
{diff}
"""

PROMPT = """{task}

Change only these paths: {scope}. {guard}Keep the change under {lines} changed lines. When you are done, run \
`{check}` from the repository root and make it pass, then commit with a message whose body has a `Why:` line and push \
your branch."""
IN_TREE = "Do not edit {checks}: they are the check, and a changed check fails the task. "
OUTSIDE = "The check is this Python file; write it to /tmp/lane-check.py first, unchanged:\n\n{source}\n"


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check).stdout


def run_check(repo, sha, cmd, timeout):
    """(exit code, output tail) of cmd in a fresh worktree at sha; 124 on a timeout."""
    with tempfile.TemporaryDirectory(prefix="local-lane-") as tmp:
        tree = pathlib.Path(tmp) / "tree"
        git(repo, "worktree", "add", "--detach", "--quiet", str(tree), sha)
        try:
            env = {k: v for k, v in os.environ.items() if not SECRET.search(k)}
            out = subprocess.run(["sh", "-c", cmd], cwd=tree, env=env, capture_output=True, text=True,
                                 timeout=timeout)
            return out.returncode, (out.stdout + out.stderr)[-TAIL:]
        except subprocess.TimeoutExpired:
            return 124, f"timed out after {timeout} s"
        finally:
            git(repo, "worktree", "remove", "--force", str(tree), check=False)


def in_scope(path, scope):
    return any(path == s or (s.endswith("/") and path.startswith(s)) for s in scope)


def review(cmd, task, diff):
    if cmd == "none":
        return "ok", "skipped"
    try:
        out = subprocess.run(shlex.split(cmd), input=REVIEW_PROMPT.format(task=task, diff=diff), capture_output=True,
                             text=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as e:
        return "unclear", str(e)
    first = (out.stdout.strip().splitlines() or [""])[0].strip().strip(".").lower()
    return (first if out.returncode == 0 and first in VERDICTS else "unclear"), out.stdout[-TAIL:]


def gate(a, head):
    """The verdict on head: {result, failed (the first item that failed), lines, ...}."""
    repo, prep = a.repo, a.prepared
    out = {"head": head, "lines": None}

    def fail(item, why, **more):
        return {**out, "result": "failed", "failed": item, "why": why, **more}

    if subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", prep, head]).returncode != 0:
        return fail("scope", "head does not descend from the prepared commit")
    if a.check_file and git(repo, "diff", "--name-only", prep, head, "--", *a.check_file).strip():
        return fail("check-file", "a check file differs from the prepared one")
    changed = git(repo, "diff", "--name-only", "--no-renames", prep, head).split()
    if not changed:
        return fail("scope", "no change")
    outside = [p for p in changed if not in_scope(p, a.scope)]
    if outside:
        return fail("scope", f"outside the scope: {' '.join(outside)}")
    numstat = [line.split("\t") for line in git(repo, "diff", "--numstat", prep, head).splitlines()]
    if any(row[0] == "-" for row in numstat):
        return fail("lines", "a binary file changed")
    out["lines"] = sum(int(n) for row in numstat for n in row[:2] if n.isdigit())
    if out["lines"] > MAX_LINES:
        return fail("lines", f"{out['lines']} changed lines, over {MAX_LINES}")
    code, tail = run_check(repo, head, a.check, a.check_timeout)
    if code != 0:
        return fail("check", f"the check exits {code} on the head", output=tail)
    whitespace = subprocess.run(["git", "-C", repo, "diff", "--check", prep, head], capture_output=True, text=True)
    if whitespace.returncode != 0:
        return fail("lint", "git diff --check", output=whitespace.stdout[-TAIL:])
    if a.lint != "none":
        code, tail = run_check(repo, head, a.lint, a.check_timeout)
        if code != 0:
            return fail("lint", f"the lint exits {code}", output=tail)
    verdict, said = review(a.reviewer, a.task, git(repo, "diff", prep, head))
    if verdict != "ok":
        return fail("review", verdict, output=said)
    return {**out, "result": "passed", "failed": "none"}


def prepared_fails(a):
    code, tail = run_check(a.repo, a.prepared, a.check, a.check_timeout)
    why = "the check times out on the prepared commit" if code == 124 else "the check passes on the prepared commit"
    return code not in (0, 124), {"result": "invalid", "failed": "prepare", "why": why, "output": tail}


def cmd_gate(a):
    ok, bad = prepared_fails(a)
    verdict = gate(a, git(a.repo, "rev-parse", a.head).strip()) if ok else bad
    print(json.dumps(verdict))
    return 0 if verdict["result"] == "passed" else 1


class PoolError(Exception):
    pass


def pool(*args, stdin=None):
    out = subprocess.run(["exec-pool", *args], input=stdin, capture_output=True, text=True)
    if out.returncode != 0:
        raise PoolError(f"exec-pool {args[0]} exits {out.returncode}: {out.stderr.strip()[-500:]}")
    return out.stdout.strip()


def record(fields):
    exe = os.environ.get("PLATFORM_RECORD") or shutil.which("platform-record") or str(
        pathlib.Path(__file__).resolve().parents[1] / "pkgs/platform-record/platform_record.py")
    subprocess.run([exe, "local-lane", *(f"{k}={v}" for k, v in fields.items())], check=False)


def cmd_run(a):
    started = time.monotonic()
    url = a.repo
    with tempfile.TemporaryDirectory(prefix="local-lane-clone-") as tmp:
        a.repo = str(pathlib.Path(tmp) / "repo")
        subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", url, a.repo], check=True)
        git(a.repo, "fetch", "--quiet", "origin", a.prepared)
        a.prepared = git(a.repo, "rev-parse", a.prepared).strip()
        ok, bad = prepared_fails(a)
        if not ok:
            print(json.dumps(bad))
            return 2
        guard = (IN_TREE.format(checks=", ".join(a.check_file)) if a.check_file
                 else OUTSIDE.format(source=pathlib.Path(a.check_script).read_text()))
        prompt = PROMPT.format(task=a.task, scope=", ".join(a.scope), guard=guard, lines=MAX_LINES,
                               check=a.check if a.check_file else "python3 -I /tmp/lane-check.py")
        key = hashlib.sha256(json.dumps([a.prepared, a.check, a.scope, a.task]).encode()).hexdigest()[:16]
        verdict, task = {}, ""
        for attempt in (1, 2):
            try:
                task = pool("submit", "--agent", "pi", "--model", a.model, "--repo", url, "--rev", a.prepared,
                            "--workdir", ".", "--key", f"{a.key or 'local-lane-' + key}-{a.model}-{attempt}",
                            "--prompt-file", "-", stdin=prompt).split()[-1]
            except PoolError as e:
                verdict = {"result": "error", "failed": "submit", "why": str(e), "lines": None, "attempt": attempt}
                print(json.dumps(verdict), flush=True)
                break
            subprocess.run(["exec-pool", "wait", task, "--timeout", str(a.timeout)], capture_output=True)
            fetched = subprocess.run(["git", "-C", a.repo, "fetch", "--quiet", "origin", f"pool/{task}"],
                                     capture_output=True)
            if fetched.returncode != 0:
                verdict = {"result": "failed", "failed": "push", "why": f"no branch pool/{task}", "lines": None}
            else:
                verdict = gate(a, git(a.repo, "rev-parse", "FETCH_HEAD").strip())
            verdict.update(task=task, attempt=attempt)
            print(json.dumps(verdict), flush=True)
            if verdict["result"] == "passed":
                break
            prompt += (f"\n\nA first attempt failed the gate at {verdict['failed']}: {verdict['why']}."
                       f"\n{verdict.get('output', '')}")
    record({"model": a.model, "repo": url.removeprefix("https://github.com/").removesuffix(".git"),
            "result": verdict["result"], "failed": verdict["failed"], "attempts": verdict["attempt"],
            "lines": verdict["lines"] if verdict["lines"] is not None else "unknown",
            "seconds": int(time.monotonic() - started), "task": task})
    return 0 if verdict["result"] == "passed" else 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("gate", "run"):
        s = sub.add_parser(name)
        s.add_argument("--repo", required=True)
        s.add_argument("--prepared", required=True)
        s.add_argument("--check")
        s.add_argument("--check-file", action="append", default=[])
        s.add_argument("--check-script")
        s.add_argument("--scope", action="append", required=True)
        s.add_argument("--task", required=True)
        s.add_argument("--lint", required=True, help="the repository's fast lints at the head, or none")
        s.add_argument("--reviewer", default=os.environ.get("LOCAL_LANE_REVIEWER", REVIEWER))
        s.add_argument("--check-timeout", type=int, default=300)
    sub.choices["gate"].add_argument("--head", required=True)
    sub.choices["run"].add_argument("--model", default="homelab/local")
    sub.choices["run"].add_argument("--timeout", type=int, default=3600)
    sub.choices["run"].add_argument("--key", help="a new one runs the same prepared task again")
    a = p.parse_args()
    if bool(a.check_script) == bool(a.check and a.check_file):
        p.error("give either --check with --check-file, or --check-script")
    if a.check_script:
        a.check = f"python3 -I {shlex.quote(str(pathlib.Path(a.check_script).resolve()))}"
    return cmd_gate(a) if a.cmd == "gate" else cmd_run(a)


if __name__ == "__main__":
    sys.exit(main())
