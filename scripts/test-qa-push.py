"""The pre-push gate (qaPush in devenv.nix) on a throwaway repository, without Nix: the script body is taken from
devenv.nix as written, with the full gate, the lints and the system generation stubbed. A green full gate is recorded
under its tree, gate executable and generation; that tree, or it plus documentation, gets the lints; anything else,
a damaged, missing or unwritable record included, runs the full gate. Through a real git push, a linked worktree is
judged on the pushed commit, not on its own HEAD."""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


src = (ROOT / "devenv.nix").read_text()
# any layout of the gate call; the body is dedented as Nix does for an indented string
m = re.search(r"\n  qaPush =\s+gate\s+\"nixos-qa-push\".*?''\n(.*?)\n *'';\n", src, re.S)
if not m:
    sys.exit("FAIL: qaPush not found in devenv.nix")
BODY = textwrap.dedent(m.group(1)).replace("'''", "\0q").replace("''${", "\0d")


def render(qa, lints, gen):
    """The hook as writeShellApplication would build it, with qa, the lints and /run/current-system replaced."""
    text = BODY.replace("${lib.getExe qa}", str(qa)).replace("${run lints}", str(lints))
    left = re.findall(r"\$\{[^}]*\}", text)
    if left:
        sys.exit(f"FAIL: Nix interpolations the test does not stub: {left}")
    if text.count("/run/current-system") != 2:
        sys.exit("FAIL: expected /run/current-system twice in qaPush (key and re-check)")
    text = text.replace("/run/current-system", str(gen)).replace("\0q", "''").replace("\0d", "${")
    return "#!/usr/bin/env bash\nset -o errexit\nset -o nounset\nset -o pipefail\n" + text + "\n"


with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    log, gen = t / "log", t / "current-system"
    (t / "gen1").mkdir(), (t / "gen2").mkdir()
    gen.symlink_to(t / "gen1")
    lints = t / "lints"
    lints.write_text(f'#!/usr/bin/env bash\necho LINTS >> "{log}"\ncat >> "{t}/lint-stdin"\nexit "${{LINT_RC:-0}}"\n')
    gates = {}
    for name in ("qa", "qa-other"):
        qa = t / name
        qa.write_text(f'#!/usr/bin/env bash\necho FULL >> "{log}"\necho "nixos-qa: stub took 0 s" >> "${{NIXOS_QA_TIMES:-/dev/null}}"\n'
                      f'[ -z "${{QA_SWITCH:-}}" ] || ln -sfn "$QA_SWITCH" "{gen}"\nexit "${{QA_RC:-0}}"\n')
        gates[name] = t / f"gate-{name}.sh"
        gates[name].write_text(render(qa, lints, gen))
    for f in (lints, t / "qa", t / "qa-other", *gates.values()):
        f.chmod(0o755)

    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GIT_", "PRE_COMMIT_")) and k not in ("NIXOS_QA_TIMES", "GATE_PROBE")}
    env.update(HOME=str(t), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_AUTHOR_NAME="t",
               GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    repo, bare = t / "repo", t / "bare.git"

    def git(*a, cwd=repo):
        return subprocess.run(["git", *a], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(files, msg, cwd=repo):
        for name, text in files.items():
            (cwd / name).parent.mkdir(parents=True, exist_ok=True)
            (cwd / name).write_text(text)
        git("add", "-A", cwd=cwd)
        git("commit", "-qm", msg, cwd=cwd)
        return git("rev-parse", "HEAD", cwd=cwd)

    def gate(rev, which="qa", **extra):
        log.write_text("")
        r = subprocess.run([str(gates[which])], cwd=repo, env={**env, "PRE_COMMIT_TO_REF": rev, **extra},
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
        seen = log.read_text().split()
        verdict = "FULL" if "FULL" in seen else "LINTS" if seen == ["LINTS"] else f"?{seen}"
        return verdict if r.returncode == 0 else f"{verdict}(rc={r.returncode})", r.stderr

    def case(what, rev, want, **kw):
        got, err = gate(rev, **kw)
        check(got == want, f"{what}: {want} (got {got}{'; ' + err.strip() if got != want else ''})")
        return err

    git("init", "-q", "--bare", "-b", "main", str(bare), cwd=t)
    git("init", "-q", "-b", "main", str(repo), cwd=t)
    git("remote", "add", "origin", str(bare))
    base = commit({"flake.nix": "1\n", "NOTES.md": "r\n", "docs/a.md": "a\n", "docs/keys.md": "k\n",
                   "scripts/test-keys.py": "open('docs/keys.md')\n", "modules/x/notes.md": "n\n"}, "base")
    git("push", "-q", "origin", "main")
    git("fetch", "-q", "origin")
    git("switch", "-qc", "work")
    green = repo / ".git" / "nixos-qa-green"

    a = commit({"flake.nix": "2\n"}, "code")
    case("A first push of a code change", a, "FULL")
    tree_a = git("rev-parse", "HEAD^{tree}")
    check(green.read_text().split()[0] == tree_a, "A recorded the pushed commit's tree in the common git dir")
    case("B the same commit again", a, "LINTS")
    git("commit", "-q", "--amend", "-m", "code, reworded")
    case("C message amended, same tree", git("rev-parse", "HEAD"), "LINTS")
    case("D a docs-only commit on top of the green tree", commit({"docs/a.md": "a2\n"}, "docs"), "LINTS")
    e = commit({"docs/keys.md": "k2\n"}, "a doc a test reads")
    case("E a doc that scripts/test-keys.py names", e, "FULL")
    case("E2 that commit again", e, "LINTS")
    case("F another code change", commit({"flake.nix": "3\n"}, "code 2"), "FULL")
    g = commit({"modules/x/notes.md": "n2\n"}, "nested md")
    case("G a nested *.md on top of a green tree", g, "FULL")
    h = commit({"flake.nix": "4\n"}, "code 3")
    case("H the gate fails", h, "FULL(rc=1)", QA_RC="1")
    case("H2 the same commit after the red run", h, "FULL")
    case("H3 and again after that green run", h, "LINTS")
    case("I same tree, another gate executable", h, "FULL", which="qa-other")
    gen.unlink(), gen.symlink_to(t / "gen2")
    case("J same tree, host generation switched", h, "FULL")
    gen.unlink(), gen.symlink_to(t / "gen1")
    case("J2 same tree, generation back", h, "LINTS")
    case("LF a failing lint on the lints-only path of a recorded tree fails the push", h, "LINTS(rc=1)", LINT_RC="1")
    tree_h = git("rev-parse", "HEAD^{tree}")
    green.write_text(f"{tree_h} {t / 'qa'} {t / 'gen1'}")
    case("NL a record whose last line has no newline is not read", h, "FULL")
    case("NL2 the record appended to it is fused with that line", h, "FULL")
    case("NL3 the next record stands on its own line", h, "LINTS")
    green.write_text(green.read_text() + f"{'1' * 40} {t / 'qa'} {t / 'gen1'}\n")
    (t / "lint-stdin").write_text("")
    case("IN a match above other records", h, "LINTS")
    check((t / "lint-stdin").read_text() == "", "IN the lints do not read the rest of the record file")

    def change(what, act, want):
        act()
        git("add", "-A")
        git("commit", "-qm", what)
        case(what, git("rev-parse", "HEAD"), want)

    change("MD a mode-only change under docs/ on top of a recorded tree", lambda: (repo / "docs/a.md").chmod(0o755), "LINTS")
    change("SD a symlink under docs/ to code, on top of a recorded tree", lambda: (repo / "docs/code").symlink_to("../flake.nix"), "LINTS")
    change("MC a mode-only change to code", lambda: (repo / "flake.nix").chmod(0o755), "FULL")
    p = commit({"flake.nix": "5\n"}, "code 4")
    case("P a green run during which the generation switched", p, "FULL", QA_SWITCH=str(t / "gen2"))
    gen.unlink(), gen.symlink_to(t / "gen1")
    case("P2 the same commit, generation back: nothing was recorded", p, "FULL")

    gate_line = f"{t / 'qa'} {t / 'gen1'}"
    q = commit({"flake.nix": "6\n"}, "code 5")
    tree_q = git("rev-parse", "HEAD^{tree}")
    green.write_text(f"{'0' * 40} {gate_line}\n")
    case("K the only record names a tree this clone lacks", q, "FULL")
    green.unlink()
    case("R1 no record file: a recorded-before tree runs the full gate", a, "FULL")
    pwned = t / "pwned"
    green.write_text(f"{tree_a[:20]} {gate_line}\n--output={pwned} {gate_line}\nHEAD {gate_line}\n"
                     f"{tree_a} {gate_line[:-3]}\n\x00\xff garbage\n {gate_line}\n{tree_a}\n")
    case("R2 a damaged record file", a, "FULL")
    check(not pwned.exists(), "R2 a damaged line never reaches git diff as an option")
    green.unlink(), green.mkdir()
    err = case("R3 the record path is a directory: the green push still passes", q, "FULL")
    check("green tree not recorded" in err, "R3 says the green tree was not recorded")
    case("R3b and the next push of that tree runs the full gate again", q, "FULL")
    green.rmdir()
    green.write_text("".join(f"{i:040x} {gate_line}\n" for i in range(60)))
    times = repo / ".git" / "nixos-qa-times"
    times.write_text("".join(f"old {i}\n" for i in range(2500)))
    case("T a green run with 60 records and 2500 step times on file", q, "FULL")
    lines = green.read_text().splitlines()
    check(len(lines) == 50 and lines[-1] == f"{tree_q} {gate_line}", f"T the record file keeps the newest 50 ({len(lines)})")
    tl = times.read_text().splitlines()
    check(len(tl) == 2002 and "nixos-qa on pushed commit" in tl[-2], f"T step times keep the newest 2000 before a run ({len(tl)})")

    git("switch", "-q", "main")
    l_rev = git("rev-parse", "origin/main")
    green.unlink()
    case("L a branch equal to origin/main, nothing recorded", l_rev, "FULL")
    git("switch", "-qc", "docs-main", base)
    change("MDm a mode-only change under docs/ since origin/main", lambda: (repo / "docs/a.md").chmod(0o755), "LINTS")
    change("SDm a symlink under docs/ to code since origin/main", lambda: (repo / "docs/code").symlink_to("../flake.nix"), "LINTS")
    case("LFm a failing lint on the origin/main docs-only path fails the push", git("rev-parse", "HEAD"), "LINTS(rc=1)", LINT_RC="1")
    git("switch", "-q", "main")

    hooks = t / "hooks"
    hooks.mkdir()
    (hooks / "pre-push").write_text(
        f'#!/usr/bin/env bash\necho "${{GIT_DIR:+set}}" > "{t}/gitdir"\nread -r _ lsha _ _\n'
        f'PRE_COMMIT_TO_REF=$lsha exec "{gates["qa"]}"\n')
    (hooks / "pre-push").chmod(0o755)
    git("config", "core.hooksPath", str(hooks))
    git("switch", "-qc", "n", base)
    c2 = commit({"flake.nix": "n2\n"}, "n2")
    c3 = commit({"flake.nix": "n3\n"}, "n3")
    git("switch", "-q", "main")
    wt = t / "wt"
    git("worktree", "add", "-q", str(wt), "n")
    green.unlink(missing_ok=True)
    pushes = 0

    def push(what, cwd, ref, want, gitdir):
        global pushes
        pushes += 1
        log.write_text("")
        r = subprocess.run(["git", "push", "-q", "origin", f"{ref}:refs/heads/p{pushes}"], cwd=cwd, env=env,
                           capture_output=True, text=True)
        seen = log.read_text().split()
        got = ("FULL" if "FULL" in seen else "LINTS" if seen == ["LINTS"] else f"?{seen}") + ("" if r.returncode == 0 else f"(rc={r.returncode})")
        had = (t / "gitdir").read_text().strip() == "set"
        check(got == want and had == gitdir,
              f"{what}: {want}, GIT_DIR {'set' if gitdir else 'unset'} in the hook (got {got}, GIT_DIR {'set' if had else 'unset'})")

    push("N1 a linked worktree at c3 pushes c2", wt, c2, "FULL", True)
    push("N2 then c3, never gated", wt, c3, "FULL", True)
    push("N3 c3 again, gated now", wt, c3, "LINTS", True)
    check(green.exists() and not (repo / ".git" / "worktrees" / "wt" / "nixos-qa-green").exists(),
          "N3 a push from a linked worktree records in the common git dir")
    git("switch", "-qc", "code", base)
    commit({"flake.nix": "n4\n"}, "n4")
    git("switch", "-q", "main")
    git("switch", "-qc", "docsonly", base, cwd=wt)
    commit({"docs/a.md": "d\n"}, "docs", cwd=wt)
    push("N4 a linked worktree on a docs-only branch pushes branch code", wt, "code", "FULL", True)
    green.unlink()
    git("switch", "-q", "n")
    push("N5 the main checkout at c3 pushes c2", repo, c2, "FULL", False)
    push("N6 then c3", repo, c3, "FULL", False)

    listed = git("worktree", "list", "--porcelain").count("worktree ")
    check(listed == 2, f"no gate worktree left behind ({listed} registered, the repository and wt expected)")

print(f"{failed} failed" if failed else "all passed")
sys.exit(1 if failed else 0)
