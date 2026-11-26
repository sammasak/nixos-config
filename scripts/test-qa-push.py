"""The pre-push gate (qaPush in devenv.nix) on a throwaway repository, without Nix: the script body is taken from
devenv.nix as written, with the full gate, the lints, the push's eval and the system generation stubbed. A push never
runs the full gate and reads no clock: a tree a full gate passed (recorded under its tree, gate executable and
generation, as scripts/qa-green.sh writes it), or it plus documentation, gets the lints; anything else, a damaged,
missing or unreadable record included, gets the fast set (the push lints, the push eval and its gate-step) and a
result=owed mode=fast gate record, and records no green tree. Through a real git push, a linked worktree is judged on
the pushed commit, not on its own HEAD. The push eval runs under the light-work lock, its record's wait apart from
its run (seeded: a held lock)."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): ") + what)
    failed += not ok


src = (ROOT / "devenv.nix").read_text()
# any layout of the gate call; the body is dedented as Nix does for an indented string
m = re.search(r"\n  qaPush =\s+gate\s+\"nixos-qa-push\".*?''\n(.*?)\n *'';\n", src, re.S)
if not m:
    sys.exit("FAIL (scripts/test-qa-push.py): qaPush not found in devenv.nix")
BODY = textwrap.dedent(m.group(1)).replace("'''", "\0q").replace("''${", "\0d")
lh = re.search(r"\n  lightHeld = ''\n(.*?)\n  '';\n", src, re.DOTALL)
if not lh:
    sys.exit("FAIL (scripts/test-qa-push.py): lightHeld not found in devenv.nix")
LIGHT_HELD = textwrap.dedent(lh.group(1)).replace("''${", "\0d").replace("${pkgs.util-linux}/bin/flock", "flock")


def render(qa, lints, gen, docs, fresh, push_lints, ev, record, light):
    """The hook as writeShellApplication would build it, with qa (its store path keys a green), the lints, the push's
    lints and eval, the record helper, the doc readers' tests, the devenv-fresh guard and /run/current-system replaced."""
    if re.search(r"\bdate\b", BODY):
        sys.exit("FAIL (scripts/test-qa-push.py): qaPush reads the clock: every push gets the fast set at any hour")
    text = (BODY.replace("${lib.getExe qa}", str(qa)).replace("${run lints}", str(lints)).replace("${lib.getExe docTests}", str(docs))
            .replace("${lib.getExe devenvFresh}", str(fresh)).replace("${run pushLints}", str(push_lints))
            .replace("${lib.getExe pushEval}", str(ev)).replace("${pushEval.name}", "nixos-push-eval")
            .replace("${lib.getExe record}", str(record))
            .replace("${lightHeld}", LIGHT_HELD.replace("/run/work-locks/light-work.lock", str(light))))
    left = re.findall(r"\$\{[^}]*\}", text)
    if left:
        sys.exit(f"FAIL (scripts/test-qa-push.py): Nix interpolations the test does not stub: {left}")
    if text.count("/run/current-system") != 1:
        sys.exit("FAIL (scripts/test-qa-push.py): expected /run/current-system once in qaPush (the green's key)")
    text = text.replace("/run/current-system", str(gen)).replace("\0q", "''").replace("\0d", "${")
    return "#!/usr/bin/env bash\nset -o errexit\nset -o nounset\nset -o pipefail\n" + text + "\n"


with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    log, gen = t / "log", t / "current-system"
    (t / "gen1").mkdir(), (t / "gen2").mkdir()
    gen.symlink_to(t / "gen1")
    lints = t / "lints"
    lints.write_text(f'#!/usr/bin/env bash\necho LINTS >> "{log}"\ncat >> "{t}/lint-stdin"\nexit "${{LINT_RC:-0}}"\n')
    docs = t / "doc-tests"
    docs.write_text(f'#!/usr/bin/env bash\necho "DOCTESTS $*" >> "{log}"\nexit "${{DOC_RC:-0}}"\n')
    # the devenv-fresh guard (devenvFresh, tested on its own below): refuses when DEVENV_STALE is set
    push_lints = t / "push-lints"
    push_lints.write_text(f'#!/usr/bin/env bash\necho PUSHLINTS >> "{log}"\nexit "${{PUSHLINT_RC:-0}}"\n')
    ev = t / "push-eval"
    light = t / "light-work.lock"
    light.touch()
    # the eval as it runs: whether it can take the light lock (held, or free) and its WORK_LOCKS_HELD
    ev.write_text(f'#!/usr/bin/env bash\necho EVAL >> "{log}"\n'
                  f'{{ flock -n "{light}" true && echo free || echo held; echo "${{WORK_LOCKS_HELD:-}}"; }} | paste -sd" " > "{t}/eval-lock"\n'
                  'exit "${EVAL_RC:-0}"\n')
    records = t / "records"
    record = t / "record"
    record.write_text(f'#!/usr/bin/env bash\necho "$PLATFORM_RECORD_STRICT $*" >> "{records}"\n')
    fresh = t / "devenv-fresh"
    fresh.write_text('#!/usr/bin/env bash\n[ -z "${DEVENV_STALE:-}" ] || { echo "nixos-qa: refused: stub stale devenv" >&2; exit 1; }\n')
    gates = {}
    for name in ("qa", "qa-other"):
        qa = t / name
        # the hook never runs the full gate: FULL in the log is a failure of every case
        qa.write_text(f'#!/usr/bin/env bash\necho FULL >> "{log}"\n')
        gates[name] = t / f"gate-{name}.sh"
        gates[name].write_text(render(qa, lints, gen, docs, fresh, push_lints, ev, record, light))
    for f in (lints, docs, fresh, push_lints, ev, record, t / "qa", t / "qa-other", *gates.values()):
        f.chmod(0o755)

    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GIT_", "PRE_COMMIT_")) and k not in ("NIXOS_QA_TIMES", "GATE_PROBE", "WORK_LOCKS_HELD")}
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

    def verdict(seen):
        return ("FULL" if "FULL" in seen else "LINTS" if seen == ["LINTS"] else "FAST" if seen == ["PUSHLINTS", "EVAL"]
                else "PUSHLINTS" if seen == ["PUSHLINTS"] else "LINTS+" + " ".join(seen[2:]) if seen[:2] == ["LINTS", "DOCTESTS"] else f"?{seen}")

    def gate(rev, which="qa", **extra):
        log.write_text("")
        r = subprocess.run([str(gates[which])], cwd=repo, env={**env, "PRE_COMMIT_TO_REF": rev, **extra},
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
        v = verdict(log.read_text().split())
        return v if r.returncode == 0 else f"{v}(rc={r.returncode})", r.stderr

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
    times = repo / ".git" / "nixos-qa-times"

    def greened(rev, exe="qa"):
        """A full gate's green for rev's tree, as a clean manual nixos:qa records it (scripts/qa-green.sh, tested below)."""
        with open(green, "a") as f:
            f.write(f"{git('rev-parse', rev + '^{tree}')} {t / exe} {os.path.realpath(gen)}\n")

    a = commit({"flake.nix": "2\n"}, "code")
    records.write_text("")
    case("A first push of a code change: the fast set", a, "FAST")
    step, _, rec = records.read_text().partition("\n")
    check(re.fullmatch(rf" gate-step gate=nixos-qa-push step=nixos-push-eval seconds=\d+ wait_seconds=0 result=pass sha={a[:7]}", step)
          and (t / "eval-lock").read_text().split() == ["held", "1"],
          f"A the push eval's gate-step record, the eval under the light lock and marked as holding it ({step!r})")
    check(re.fullmatch(rf"1 gate gate=nixos-qa-push seconds=\d+ result=owed sha={a[:7]} mode=fast head={a} checkout=clean\n", rec)
          and f"full QA not run for {a}, owed to the scheduled gate on main" in times.read_text(),
          f"A one strict owed gate record and the owed line in nixos-qa-times ({rec.strip()!r})")
    check(not green.exists(), "A a push records no green tree")
    case("B the same commit again: still owed", a, "FAST")
    tree_a = git("rev-parse", "HEAD^{tree}")
    greened(a)
    records.write_text("")
    case("B2 that commit once a full gate passed on its tree", a, "LINTS")
    check(records.read_text() == "", "B2 a green tree owes nothing")
    git("commit", "-q", "--amend", "-m", "code, reworded")
    case("C message amended, same tree", git("rev-parse", "HEAD"), "LINTS")
    case("D a docs-only commit on top of the green tree", commit({"docs/a.md": "a2\n"}, "docs"), "LINTS")
    e = commit({"docs/keys.md": "k2\n"}, "a doc a test reads")
    case("E a doc that scripts/test-keys.py names, on top of a green tree", e, "FAST")
    greened(e)
    case("E2 that commit once green", e, "LINTS")
    case("F another code change", commit({"flake.nix": "3\n"}, "code 2"), "FAST")
    g = commit({"modules/x/notes.md": "n2\n"}, "nested md")
    case("G a nested *.md on top of a green tree", g, "FAST")
    h = commit({"flake.nix": "4\n"}, "code 3")
    greened(h)
    case("H a green tree", h, "LINTS")
    case("I same tree, another gate executable", h, "FAST", which="qa-other")
    gen.unlink(), gen.symlink_to(t / "gen2")
    case("J same tree, host generation switched", h, "FAST")
    gen.unlink(), gen.symlink_to(t / "gen1")
    case("J2 same tree, generation back", h, "LINTS")
    case("LF a failing lint on the lints-only path of a recorded tree fails the push", h, "LINTS(rc=1)", LINT_RC="1")
    tree_h = git("rev-parse", "HEAD^{tree}")
    green.write_text(f"{tree_h} {t / 'qa'} {t / 'gen1'}")
    case("NL a record whose last line has no newline is not read", h, "FAST")
    green.write_text(green.read_text() + "\n")
    case("NL2 the same record with its newline", h, "LINTS")
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
    change("MC a mode-only change to code", lambda: (repo / "flake.nix").chmod(0o755), "FAST")

    gate_line = f"{t / 'qa'} {t / 'gen1'}"
    q = commit({"flake.nix": "6\n"}, "code 5")
    tree_q = git("rev-parse", "HEAD^{tree}")
    green.write_text(f"{'0' * 40} {gate_line}\n")
    case("K the only record names a tree this clone lacks", q, "FAST")
    green.unlink()
    case("R1 no record file: a recorded-before tree gets the fast set", a, "FAST")
    pwned = t / "pwned"
    green.write_text(f"{tree_a[:20]} {gate_line}\n--output={pwned} {gate_line}\nHEAD {gate_line}\n"
                     f"{tree_a} {gate_line[:-3]}\n\x00\xff garbage\n {gate_line}\n{tree_a}\n")
    case("R2 a damaged record file", a, "FAST")
    check(not pwned.exists(), "R2 a damaged line never reaches git diff as an option")
    green.unlink(), green.mkdir()
    case("R3 the record path is a directory: the push still passes", q, "FAST")
    green.rmdir()
    green.write_text(f"{tree_q} {gate_line}\n" + "".join(f"{i:040x} {gate_line}\n" for i in range(60)))
    times.write_text("".join(f"old {i}\n" for i in range(2500)))
    case("T a match older than the newest 50 records is not read", q, "FAST")
    tl = times.read_text().splitlines()
    check(len(tl) == 2002 and "owed" in tl[-1], f"T step times keep the newest 2000 before a push adds its own ({len(tl)})")

    git("switch", "-q", "main")
    l_rev = git("rev-parse", "origin/main")
    green.unlink()
    case("L a branch equal to origin/main, nothing recorded", l_rev, "FAST")
    git("switch", "-qc", "docs-main", base)
    change("MDm a mode-only change under docs/ since origin/main", lambda: (repo / "docs/a.md").chmod(0o755), "LINTS")
    change("SDm a symlink under docs/ to code since origin/main", lambda: (repo / "docs/code").symlink_to("../flake.nix"), "LINTS")
    case("LFm a failing lint on the origin/main docs-only path fails the push", git("rev-parse", "HEAD"), "LINTS(rc=1)", LINT_RC="1")
    git("switch", "-qc", "docs-read", base)
    k = commit({"docs/keys.md": "k3\n", "docs/a.md": "a4\n"}, "a doc a test reads, since origin/main")
    case("DR documentation since origin/main that a test reads runs the lints and that test, not the fast set", k,
         "LINTS+scripts/test-keys.py")
    case("DRf the doc's test failing fails the push", k, "LINTS+scripts/test-keys.py(rc=1)", DOC_RC="1")
    case("DRc the same plus a code change is the fast set", commit({"flake.nix": "dr\n"}, "and code"), "FAST")
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
        got = verdict(log.read_text().split()) + ("" if r.returncode == 0 else f"(rc={r.returncode})")
        had = (t / "gitdir").read_text().strip() == "set"
        check(got == want and had == gitdir,
              f"{what}: {want}, GIT_DIR {'set' if gitdir else 'unset'} in the hook (got {got}, GIT_DIR {'set' if had else 'unset'})")

    times.write_text("")
    push("N1 a linked worktree at c3 pushes c2", wt, c2, "FAST", True)
    check(f"not run for {c2}," in times.read_text() and not (repo / ".git" / "worktrees" / "wt" / "nixos-qa-times").exists(),
          "N1 a push from a linked worktree judges the pushed commit and writes the common git dir")
    push("N2 then c3", wt, c3, "FAST", True)
    greened(c3)
    push("N3 c3 again, green now", wt, c3, "LINTS", True)
    git("switch", "-qc", "code", base)
    commit({"flake.nix": "n4\n"}, "n4")
    git("switch", "-q", "main")
    git("switch", "-qc", "docsonly", base, cwd=wt)
    commit({"docs/a.md": "d\n"}, "docs", cwd=wt)
    push("N4 a linked worktree on a docs-only branch pushes branch code", wt, "code", "FAST", True)
    green.unlink()
    git("switch", "-q", "n")
    push("N5 the main checkout at c3 pushes c2", repo, c2, "FAST", False)
    push("N6 then c3", repo, c3, "FAST", False)

    listed = git("worktree", "list", "--porcelain").count("worktree ")
    check(listed == 2, f"no gate worktree left behind ({listed} registered, the repository and wt expected)")

    # A manual nixos:qa's green (scripts/qa-green.sh, called by qa in devenv.nix): recorded for a clean checkout that
    # did not change during the run, under the key the hook looks up, so pushing that tree runs the lints only; any
    # change no commit holds, a HEAD or generation that moved, or a gate not run as its store path records nothing.
    git("config", "--unset", "core.hooksPath")
    qg = ROOT / "scripts" / "qa-green.sh"
    genv = {**env, "QA_SYSTEM": str(gen), "QA_GATE_PREFIX": f"{t}/"}

    def manual(gate=str(t / "qa"), during=None, result="pass", mode="manual"):
        begin = subprocess.run(["bash", str(qg), "begin"], cwd=repo, env=genv, capture_output=True, text=True, check=True).stdout.split()
        if during:
            during()
        r = subprocess.run(["bash", str(qg), "record", gate, result, mode, *begin], cwd=repo, env=genv, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def switch_gen(to):
        gen.unlink()
        gen.symlink_to(t / to)

    switch_gen("gen1")
    green.unlink(missing_ok=True)
    m1 = commit({"flake.nix": "m1\n"}, "m1")
    rc, out = manual()
    want = f"{git('rev-parse', 'HEAD^{tree}')} {t / 'qa'} {t / 'gen1'}"
    check(rc == 0 and "recorded green" in out and green.read_text().split("\n")[-2] == want,
          f"M1 a clean manual green is recorded under the key the hook looks up ({out.strip()})")
    case("M1 then the push of that tree runs the lints only", m1, "LINTS")
    for what, files, during, gate_exe, extra in (
        ("M2 an untracked file at the start", {"flake.nix": "m2\n"}, None, None, {}),
        ("M3 a tracked file modified at the start", {"flake.nix": "m3\n"}, None, None, {}),
        ("M4 HEAD moved during the run", {"flake.nix": "m4\n"}, lambda: commit({"flake.nix": "m4b\n"}, "during"), None, {}),
        ("M5 the generation switched during the run", {"flake.nix": "m5\n"}, lambda: switch_gen("gen2"), None, {}),
        ("M6 the gate not run as its store path", {"flake.nix": "m6\n"}, None, "nixos-qa", {}),
        ("M7 a failed gate", {"flake.nix": "m7\n"}, None, None, {"result": "fail"}),
        ("M8 a scheduled run (its own clone keeps its state)", {"flake.nix": "m8\n"}, None, None, {"mode": "scheduled"}),
        ("M9 a file marked skip-worktree", {"flake.nix": "m9\n"}, None, None, {}),
    ):
        rev = commit(files, what[:2])
        if what.startswith("M2"):
            (repo / "scratch.txt").write_text("x\n")
        if what.startswith("M3"):
            (repo / "flake.nix").write_text("edited\n")
        if what.startswith("M9"):
            git("update-index", "--skip-worktree", "flake.nix")
            (repo / "flake.nix").write_text("hidden\n")
        rc, out = manual(gate_exe or str(t / "qa"), during, **extra)
        if what.startswith("M9"):
            git("update-index", "--no-skip-worktree", "flake.nix")
        (repo / "scratch.txt").unlink(missing_ok=True)
        git("checkout", "-q", "--", "flake.nix")
        switch_gen("gen1")
        check(rc == 0 and "green not recorded" in out, f"seeded: {what}: nothing is recorded ({out.strip()})")
        case(f"{what}: the push of that tree gets the fast set", rev, "FAST")

    n = commit({"flake.nix": "fast lint\n"}, "fast lint")
    records.write_text("")
    case("WF a failing push lint fails the push before the eval", n, "PUSHLINTS(rc=1)", PUSHLINT_RC="1")
    check(records.read_text() == "", "WF a failed push writes no owed record")
    case("WE a failing push eval fails the push", n, "FAST(rc=1)", EVAL_RC="1")
    rec = records.read_text()
    check(re.fullmatch(rf" gate-step gate=nixos-qa-push step=nixos-push-eval seconds=\d+ wait_seconds=0 result=fail sha={n[:7]}\n", rec),
          f"WE a failed push eval records its failed step and no owed gate ({rec!r})")
    holder = subprocess.Popen(["flock", str(light), "sleep", "2"])
    while subprocess.run(["flock", "-n", str(light), "true"], check=False).returncode == 0:
        time.sleep(0.05)
    records.write_text("")
    case("LW the push eval waits for a held light lock", n, "FAST")
    holder.wait()
    step = records.read_text().partition("\n")[0]
    check(re.fullmatch(rf" gate-step gate=nixos-qa-push step=nixos-push-eval seconds=[01] wait_seconds=[123] result=pass sha={n[:7]}", step),
          f"LW seeded: its record counts the wait apart from the run ({step!r})")
    records.write_text("")
    case("LH under a caller's light hold", n, "FAST", WORK_LOCKS_HELD="1")
    step = records.read_text().partition("\n")[0]
    check(" wait_seconds=unknown result=pass" in step and (t / "eval-lock").read_text().split() == ["free", "1"],
          f"LH a caller's hold is not taken again, its wait unknown ({step!r})")
    light.unlink()
    records.write_text("")
    case("LN no light lock on this host", n, "FAST")
    step = records.read_text().partition("\n")[0]
    check(" wait_seconds=0 result=pass" in step, f"LN no lock file: the eval unlocked, no wait ({step!r})")
    light.touch()

    # a hook built before the pushed tree's devenv files changed (a shell entered before a merge) is refused before
    # any gate, lints-only and green paths included; it records nothing
    stale = commit({"devenv.nix": "changed after entry\n"}, "stale")
    records.write_text("")
    err = case("seeded: a gate built from other devenv files than the pushed tree's is refused, nothing run", stale, "?[](rc=1)",
               DEVENV_STALE="1")
    check("refused" in err and records.read_text() == "", f"seeded: the stale gate records nothing ({err.strip()})")
    case("the same tree from a freshly entered devenv gets the fast set", stale, "FAST")

# devenvFresh on its own, with the hashes Nix would bake in (builtFrom) and sha256sum on a throwaway tree
fm = re.search(r"\n  devenvFresh = gate \"nixos-devenv-fresh\" \[ pkgs.coreutils \] ''\n(.*?)\n *'';\n", src, re.S)
bm = re.search(r"\n  builtFrom =.*?\[(.*?)\];", src, re.S)
check(fm is not None and bm is not None and re.findall(r"\./(\S+)", bm.group(1)) == ["devenv.nix", "devenv.yaml", "devenv.lock", "devenv.local.nix", "devenv.local.yaml"],
      "devenvFresh and builtFrom found in devenv.nix; builtFrom covers devenv.nix, devenv.yaml, devenv.lock and the local overrides devenv loads")
if fm and bm:
    import hashlib
    fbody = textwrap.dedent(fm.group(1)).replace("''${", "${")
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        files = {"devenv.nix": "{ }\n", "devenv.yaml": "inputs: {}\n", "devenv.lock": "{}\n"}
        for n, c in files.items():
            (t / n).write_text(c)
        # built with no devenv.local.yaml and a devenv.local.nix, as builtFrom writes them (absent: not there at build)
        (t / "devenv.local.nix").write_text("{ env.X = \"1\"; }\n")
        built = {**{n: hashlib.sha256(c.encode()).hexdigest() for n, c in files.items()},
                 "devenv.local.nix": hashlib.sha256((t / "devenv.local.nix").read_bytes()).hexdigest(), "devenv.local.yaml": "absent"}
        pairs = " ".join(f"{n}={h}" for n, h in built.items())
        script = t / "fresh.sh"
        left = re.findall(r"\$\{(?!pair|have|1:-)[^}]*\}", fbody.replace("${builtFrom}", ""))
        check(left == [], f"devenvFresh has no interpolation besides builtFrom ({left})")
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + fbody.replace("${builtFrom}", pairs) + "\n")

        def fresh_run():
            r = subprocess.run(["bash", str(script)], cwd=t, capture_output=True, text=True)
            return r.returncode, r.stderr
        rc, err = fresh_run()
        check(rc == 0 and err == "", f"devenvFresh passes a tree whose devenv files are the ones it was built from ({rc}: {err.strip()})")
        (t / "devenv.lock").write_text('{"nodes": {}}\n')
        rc, err = fresh_run()
        check(rc == 1 and "refused" in err and " devenv.lock " in err and "devenv.nix" not in err and "devenv shell -- true" in err,
              f"seeded: a changed devenv.lock is refused, naming it and how to re-enter ({rc}: {err.strip()})")
        (t / "devenv.lock").write_text(files["devenv.lock"])
        (t / "devenv.yaml").unlink()
        rc, err = fresh_run()
        check(rc == 1 and "devenv.yaml" in err, f"seeded: a missing devenv.yaml is refused, not passed ({rc}: {err.strip()})")
        (t / "devenv.yaml").write_text(files["devenv.yaml"])
        rc, err = fresh_run()
        check(rc == 0, f"the local overrides as built (devenv.local.nix present, devenv.local.yaml absent) pass ({rc}: {err.strip()})")
        (t / "devenv.local.nix").write_text("{ env.X = \"2\"; }\n")
        rc, err = fresh_run()
        check(rc == 1 and "devenv.local.nix" in err, f"seeded: an edited devenv.local.nix is refused ({rc}: {err.strip()})")
        (t / "devenv.local.nix").unlink()
        rc, err = fresh_run()
        check(rc == 1 and "devenv.local.nix" in err, f"seeded: a devenv.local.nix removed since the build is refused ({rc}: {err.strip()})")
        (t / "devenv.local.nix").write_text("{ env.X = \"1\"; }\n")
        (t / "devenv.local.yaml").write_text("inputs: {}\n")
        rc, err = fresh_run()
        check(rc == 1 and "devenv.local.yaml" in err and "devenv.local.nix" not in err,
              f"seeded: a devenv.local.yaml created after the build (absent then) is refused ({rc}: {err.strip()})")
        (t / "devenv.local.yaml").unlink()
        # the hook's case: the pushed commit's worktree has no local overrides (untracked), the entered checkout has them
        pushed = t / "pushed"
        pushed.mkdir()
        for n, c in files.items():
            (pushed / n).write_text(c)
        r = subprocess.run(["bash", str(script), str(t)], cwd=pushed, capture_output=True, text=True)
        check(r.returncode == 0, f"a pushed worktree without the untracked local overrides passes when the entered checkout has them as built ({r.returncode}: {r.stderr.strip()})")
        r = subprocess.run(["bash", str(script)], cwd=pushed, capture_output=True, text=True)
        check(r.returncode == 1 and "devenv.local.nix" in r.stderr,
              f"seeded: without the entered checkout the same worktree is refused (its devenv.local.nix is not there) ({r.returncode})")
    check(re.search(r'\$\{lib\.getExe devenvFresh\} "\$entered"', BODY.replace("\0d", "${")) is not None and "entered=$PWD" in BODY,
          "qaPush hands devenvFresh the checkout it was entered from, before it moves into the pushed worktree")


# The flake check (flakeCheck in devenv.nix) refuses to run on lenovo when a check is a VM test (it has a driver,
# whatever its name), and builds them elsewhere: nix and uname stubbed, a fake flake with one VM check ("rebind") and
# one plain check.
fc = re.search(r"\n  flakeCheck =\s+gate\s+\"nixos-flake-check\".*?''\n(.*?)\n *'';\n", src, re.S)
check(fc is not None, "flakeCheck found in devenv.nix")
if fc:
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        calls = t / "calls"
        # the kinds the step expects (flake-output-kinds.json), so adding one there does not break this test
        kinds = json.loads((ROOT / "scripts/flake-output-kinds.json").read_text())
        names = {"nixosConfigurations": ["h1"], "formatter": [], "packages": [], "checks": ["x86_64-linux"],
                 "checks.x86_64-linux": ["rebind", "plain"]}
        (t / "nix").write_text("#!/usr/bin/env python3\nimport json, sys\na = sys.argv[1:]\n"
                               f"open({str(calls)!r}, 'a').write(' '.join(a) + '\\n')\n"
                               f"names = {names!r}\n"
                               "attr = next((x[2:] for x in a if x.startswith('.#')), '')\n"
                               f"if a[:2] == ['flake', 'show']: print(json.dumps({{k: 0 for k in {kinds!r}}}))\n"
                               "elif '--expr' in a: print('x86_64-linux', end='')\n"
                               "elif any('? driver' in x for x in a): print(json.dumps(['rebind']))\n"
                               "elif 'builtins.attrNames' in a: print(json.dumps(names.get(attr, [])))\n"
                               "elif a[:2] == ['eval', '--raw'] and attr.endswith('.drvPath'): print('/nix/store/x-' + attr[:-8] + '.drv', end='')\n")
        for host in ("lenovo-21CB001PMX", "msi-ms7758"):
            (t / "uname").write_text(f"#!/usr/bin/env bash\necho {host}\n")
            for f in ("nix", "uname"):
                (t / f).chmod(0o755)
            calls.write_text("")
            body = textwrap.dedent(fc.group(1)).replace("${pkgs.coreutils}/bin/uname", str(t / "uname"))
            heavy = re.search(r'\n *gateHeavy = "([^"]*)";\n', src)
            body = body.replace("${gateHeavy}", heavy.group(1) if heavy else "").replace("''$", "$")
            # every built check writes a gate-step record; this test reads only what is built
            body = body.replace("${lib.getExe record}", "true")
            body = body.replace("${flakeKinds}", json.dumps(kinds, separators=(",", ":")))
            run = subprocess.run(["bash", "-euo", "pipefail", "-c", body], capture_output=True, text=True,
                                 env={**os.environ, "PATH": f"{t}:{os.environ['PATH']}"})
            built = [c for c in calls.read_text().splitlines() if c.startswith("build ") and "--dry-run" not in c]
            vm_built = any("rebind" in c for c in built)
            if host.startswith("lenovo"):
                hosts_evaluated = any("toplevel" in c for c in calls.read_text().splitlines())
                check(run.returncode != 0 and not built and not hosts_evaluated
                      and "refused on lenovo: rebind boot a QEMU VM" in run.stderr,
                      f"on lenovo the gate fails, builds nothing and names the VM check ({run.returncode}, {run.stderr[-300:]!r})")
            else:
                check(run.returncode == 0 and vm_built and "refused" not in run.stderr,
                      f"on msi the VM check is booted ({run.stderr[-300:]!r})")

print(f"{failed} failed" if failed else "all passed")
sys.exit(1 if failed else 0)
