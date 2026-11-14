"""The pre-push shim (.githooks/pre-push) on a throwaway repository, without Nix: prek is replaced by a stub that
logs the lines it is handed. A push that brings new commits to more than one ref is refused before prek and leaves
the remote unchanged; one ref, a delete, a new ref at a commit the remote has, and a new ref beside it pass through
as before. The guard is the platform's no-force-guard v5 text, which carries the block."""
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHIM = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".githooks" / "pre-push"
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


text = SHIM.read_text()
check("no-force-guard v5" in text, "the shim carries the no-force guard v5")
check("only the first would be gated" in text, "the one-ref block is in the shim (a prek install -f drops it)")
prek_lines = [l for l in text.splitlines() if l.startswith('PREK="/')]
if len(prek_lines) != 1:
    sys.exit("FAIL: expected exactly one PREK= line with an absolute path in the shim")

ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
}
for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    ENV.pop(k, None)


def git(cwd, *args, ok=True):
    p = subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True)
    if ok and p.returncode:
        sys.exit(f"FAIL: git {' '.join(args)}: {p.stderr}")
    return p


with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    remote, work, hooks, log = tmp / "remote.git", tmp / "work", tmp / "hooks", tmp / "prek.log"
    stub = tmp / "prek-stub"
    stub.write_text(f'#!/bin/sh\ncat >> "{log}"\necho run >> "{log}"\n')
    stub.chmod(0o755)
    hooks.mkdir()
    (hooks / "pre-push").write_text(text.replace(prek_lines[0], f'PREK="{stub}"'))
    (hooks / "pre-push").chmod(0o755)

    git(tmp, "init", "-q", "--bare", "-b", "main", str(remote))
    git(tmp, "init", "-q", "-b", "main", str(work))
    git(work, "config", "core.hooksPath", str(hooks))
    git(work, "remote", "add", "origin", str(remote))

    def commit(msg):
        git(work, "commit", "-q", "--allow-empty", "-m", msg)
        return git(work, "rev-parse", "HEAD").stdout.strip()

    def remote_ref(ref):
        return git(remote, "rev-parse", "--verify", "-q", ref, ok=False).stdout.strip()

    def push(*refspecs):
        log.write_text("")
        p = git(work, "push", "-q", "origin", *refspecs, ok=False)
        git(work, "fetch", "-q", "origin")
        return p, log.read_text()

    a = commit("a")
    p, seen = push("main:refs/heads/main")
    check(p.returncode == 0 and "run" in seen and remote_ref("refs/heads/main") == a, "one ref with a new commit reaches prek and lands")

    p, seen = push(f"{a}:refs/heads/copy")
    check(p.returncode == 0 and remote_ref("refs/heads/copy") == a, "a new ref at a commit the remote has is pushed")

    b = commit("b")
    git(work, "branch", "-q", "side", a)
    git(work, "checkout", "-q", "side")
    c = commit("c")
    git(work, "checkout", "-q", "main")
    p, seen = push(f"{b}:refs/heads/main", f"{c}:refs/heads/copy")
    check(p.returncode != 0 and "one ref at a time" in p.stderr, "two refs with new commits are refused, and the message says to push one ref at a time")
    check("run" not in seen, "prek is not reached by the refused push")
    check(remote_ref("refs/heads/main") == a and remote_ref("refs/heads/copy") == a, "the refused push leaves the remote unchanged")

    p, seen = push(f"{b}:refs/heads/main", f"{c}:refs/heads/new1")
    check(p.returncode != 0 and remote_ref("refs/heads/main") == a and not remote_ref("refs/heads/new1"),
          "an existing ref and a new ref, both with new commits, are refused")

    p, seen = push(f"{b}:refs/heads/main", f"{a}:refs/heads/old1", ":refs/heads/copy")
    check(p.returncode == 0 and "run" in seen and remote_ref("refs/heads/main") == b and remote_ref("refs/heads/old1") == a
          and not remote_ref("refs/heads/copy"),
          "one ref with new commits beside a ref at a known commit and a delete passes")

    git(work, "tag", "v1", b)
    p, seen = push("refs/tags/v1")
    check(p.returncode == 0 and remote_ref("refs/tags/v1") == b, "a tag at a commit the remote has is pushed")

    p, seen = push(f"+{a}:refs/heads/main")
    check(p.returncode != 0 and "non-fast-forward" in p.stderr and remote_ref("refs/heads/main") == b, "a rewind of main is still refused by the guard")

    p, seen = push(":refs/heads/main")
    check(p.returncode != 0 and remote_ref("refs/heads/main") == b, "deleting main is still refused by the guard")

    block = text.index('printf \'%s\\n\' "$stdin" | {', text.index("} || exit 1"))
    without = text[:block] + text[text.index("} || exit 1", block) + len("} || exit 1\n"):]
    (hooks / "pre-push").write_text(without.replace(prek_lines[0], f'PREK="{stub}"'))
    d = commit("d")
    p, seen = push(f"{d}:refs/heads/main", f"{c}:refs/heads/old1")
    check(p.returncode == 0 and seen.count("run") == 1, "control: without the block the same shape goes through (so the cases above test the block)")

sys.exit(1 if failed else 0)
