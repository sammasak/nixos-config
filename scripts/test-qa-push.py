"""The pre-push gate (qaPush in devenv.nix) on a throwaway repository, without Nix: the script body is taken from
devenv.nix as written, with the full gate, the lints, the push's eval and the system generation stubbed. A push never
runs the full gate and reads no clock: a tree a full gate passed (recorded under its tree, gate executable and
generation, as scripts/qa-green.sh writes it), or it plus documentation, gets the lints; anything else, a damaged,
missing or unreadable record included, gets the fast set (the push lints, the push eval and its gate-step) and a
result=owed mode=fast gate record, and records no green tree. Through a real git push, a linked worktree is judged on
the pushed commit, not on its own HEAD. The push eval runs under the light-work lock, its record's wait apart from
its run (seeded: a held lock). nixos:qa's step runner, seeded with two red steps: a manual run ends at the first, a
scheduled one runs every step and ends red naming each; a step that reads a red probe is skipped, not red. The eval
record (scripts/eval_record.py): a pushed tree whose flake show passed before under this nix skips the push eval (a
cached step record, still owed); the push eval and the flake check record a pass on a clean tree, the flake check reads
it for its flake show (seeded: NIXOS_EVAL_RECORD=0, another nix, another tree, corrupt, dirty, failed). A docs push's
doc tests build no whole probe, a section alone is built under the light lock."""
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
# a nix that only says its version, for the eval record's key (scripts/eval_record.py)
NIX_STUB = '#!/usr/bin/env bash\n[ "$1" = --version ] && echo "${NIX_STUB_VERSION:-nix (Nix) 2.0-test}"\n'
NIXV = "nix (Nix) 2.0-test"


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


def render(qa, lints, gen, docs, fresh, push_lints, ev, record, light, evrec):
    """The hook as writeShellApplication would build it, with qa (its store path keys a green), the lints, the push's
    lints and eval, the record helper, the doc readers' tests, the devenv-fresh guard and /run/current-system replaced."""
    if re.search(r"\bdate\b", BODY):
        sys.exit("FAIL (scripts/test-qa-push.py): qaPush reads the clock: every push gets the fast set at any hour")
    text = (BODY.replace("${lib.getExe qa}", str(qa)).replace("${run lints}", str(lints)).replace("${lib.getExe docTests}", str(docs))
            .replace("${lib.getExe devenvFresh}", str(fresh)).replace("${run pushLints}", str(push_lints))
            .replace("${lib.getExe pushEval}", str(ev)).replace("${pushEval.name}", "nixos-push-eval")
            .replace("${lib.getExe record}", str(record)).replace("${lib.getExe evalRecord}", str(evrec))
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
    # scripts/eval_record.py as the gate builds it, under a stub nix whose version NIX_STUB_VERSION sets
    (t / "nixbin").mkdir()
    (t / "nixbin/nix").write_text(NIX_STUB)
    (t / "nixbin/nix").chmod(0o755)
    evrec = t / "eval-record"
    evrec.write_text(f'#!/usr/bin/env bash\nPATH="{t}/nixbin:$PATH" exec python3 {ROOT}/scripts/eval_record.py "$@"\n')
    fresh = t / "devenv-fresh"
    fresh.write_text('#!/usr/bin/env bash\n[ -z "${DEVENV_STALE:-}" ] || { echo "nixos-qa: refused: stub stale devenv" >&2; exit 1; }\n')
    gates = {}
    for name in ("qa", "qa-other"):
        qa = t / name
        # the hook never runs the full gate: FULL in the log is a failure of every case
        qa.write_text(f'#!/usr/bin/env bash\necho FULL >> "{log}"\n')
        gates[name] = t / f"gate-{name}.sh"
        gates[name].write_text(render(qa, lints, gen, docs, fresh, push_lints, ev, record, light, evrec))
    for f in (lints, docs, fresh, push_lints, ev, record, evrec, t / "qa", t / "qa-other", *gates.values()):
        f.chmod(0o755)

    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GIT_", "PRE_COMMIT_")) and k not in ("NIXOS_QA_TIMES", "GATE_PROBE", "WORK_LOCKS_HELD",
                                                                   "NIXOS_EVAL_RECORD", "NIX_STUB_VERSION")}
    env.update(HOME=str(t), XDG_STATE_HOME=str(t / "state"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_AUTHOR_NAME="t",
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

    # the eval record (scripts/eval_record.py): a tree whose flake show passed before under this nix skips the push eval
    state = t / "state/nixos-eval-records"
    rq = commit({"flake.nix": "recorded\n"}, "recorded")
    tree_rq = git("rev-parse", "HEAD^{tree}")

    def seed(name, **fields):
        state.mkdir(parents=True, exist_ok=True)
        (state / f"{name}.json").write_text(json.dumps({"tree": name, "nix": NIXV, "flake_show": "ok", "flake_kinds": "[]", **fields}))

    records.write_text("")
    case("RM no record of the pushed tree: the push eval runs", rq, "FAST")
    seed(tree_rq)
    records.write_text(""), times.write_text("")
    got, _ = gate(rq)
    step, _, rest = records.read_text().partition("\n")
    check(got == "PUSHLINTS" and re.fullmatch(rf" gate-step gate=nixos-qa-push step=nixos-push-eval seconds=0 wait_seconds=0 result=cached sha={rq[:7]}", step)
          and re.match(rf"1 gate gate=nixos-qa-push .*result=owed .*head={rq} ", rest)
          and f"nixos-push-eval skipped: tree {tree_rq[:12]} passed it before under this nix" in times.read_text()
          and f"full QA not run for {rq}, owed" in times.read_text(),
          f"RH the pushed tree's flake show recorded under this nix: no push eval, a cached step record, still owed ({got}, {step!r}, {rest!r})")
    case("RS NIXOS_EVAL_RECORD=0: the record is not read", rq, "FAST", NIXOS_EVAL_RECORD="0")
    case("RV a record of another nix is not used", rq, "FAST", NIX_STUB_VERSION="nix (Nix) 9.9")
    (state / f"{tree_rq}.json").write_text(json.dumps({"tree": "c" * 40, "nix": NIXV, "flake_show": "ok", "flake_kinds": "[]"}))
    seed("c" * 40)
    case("RO another tree's records, one under this tree's name, are not used", rq, "FAST")
    for bad in ("{", json.dumps({"tree": tree_rq, "nix": NIXV, "flake_show": "ok"}), "\0\xff",
                json.dumps({"tree": tree_rq, "nix": NIXV, "flake_show": "ok", "flake_kinds": "{"})):
        (state / f"{tree_rq}.json").write_text(bad)
        case(f"RC a corrupt record ({bad[:20]!r}) is a miss", rq, "FAST")

    # a hook built before the pushed tree's devenv files changed (a shell entered before a merge) is refused before
    # any gate, lints-only and green paths included; it records nothing
    stale = commit({"devenv.nix": "changed after entry\n"}, "stale")
    records.write_text("")
    err = case("seeded: a gate built from other devenv files than the pushed tree's is refused, nothing run", stale, "?[](rc=1)",
               DEVENV_STALE="1")
    check("refused" in err and records.read_text() == "", f"seeded: the stale gate records nothing ({err.strip()})")
    case("the same tree from a freshly entered devenv gets the fast set", stale, "FAST")

# nixos:qa's step runner (timed, stepOutcomes and the probe step in devenv.nix) on stub steps: A passes, B and D fail, C
# reads the probe (exits 77 when it is red, as scripts/gate_probe.py does); the probe passes or fails as PROBE_RC says
tm = re.search(r'\n  timed = lib\.concatMapStringsSep "\\n" \(g: \'\'\n(.*?)\n  \'\'\);\n', src, re.DOTALL)
so = re.search(r"\n  stepOutcomes = \'\'\n(.*?)\n  \'\';\n", src, re.DOTALL)
qm = re.search(r'\n  qa =\s+gate\s+"nixos-qa".*?\'\'\n(.*?)\n *\'\';\n', src, re.DOTALL)
pb = re.search(r"\n( *\$\{lightHeld\}\n *probe_out\(\).*?\n *fi\n)", qm.group(1), re.DOTALL) if qm else None
check(tm is not None and so is not None and pb is not None and "${stepOutcomes}" in qm.group(1) and qm.group(1).rstrip().endswith("steps_end"),
      "timed, stepOutcomes and the probe step found in devenv.nix; nixos:qa defines the outcomes and ends with steps_end")
if tm and so and pb:
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        recs = t / "records"
        steps = {"A": "exit 0", "B": "exit 1", "C": '[ "${GATE_PROBE:-}" != red ] || exit 77; exit 0', "D": "exit 1"}
        for n, body in {**steps, "probe": 'echo "$n" >> /dev/null; exit "${PROBE_RC:-0}"', "record": f'echo "$*" >> {recs}'}.items():
            (t / n).write_text(f"#!/usr/bin/env bash\necho {n} >> {t}/ran\n{body}\n")
            (t / n).chmod(0o755)
        (t / "light").touch()

        def unnix(text):
            return (textwrap.dedent(text).replace("${lib.getExe record}", str(t / "record")).replace("\'\'${", "${"))
        timed_steps = "".join(unnix(tm.group(1)).replace("${lib.getExe g}", str(t / n)).replace("${g.name}", n) + "\n" for n in steps)
        probe_step = (unnix(pb.group(1)).replace("${lightHeld}", LIGHT_HELD.replace("\0d", "${").replace("/run/work-locks/light-work.lock", str(t / "light")))
                      .replace("${lib.getExe probe}", str(t / "probe")).replace("${probe.name}", "nixos-gate-probe")
                      .replace("python3 scripts/gate_probe.py coverage", "echo {}"))
        script = t / "runner.sh"
        body = "#!/usr/bin/env bash\nset -euo pipefail\nmode=$1 sha=abc\n" + unnix(so.group(1)) + "\n" + probe_step + timed_steps + "steps_end\n"
        left = re.findall(r"\$\{(?!GATE_PROBE|NIXOS_QA|NIXOS_QA_MODE|WORK_LOCKS_HELD|cap|#red|red|PROBE_RC)[^}]*\}", body)
        check(left == [], f"the step runner has no Nix interpolation the test does not stub ({left})")
        script.write_text(body)

        def runner(mode, **extra):
            for f in (recs, t / "ran"):
                f.write_text("")
            r = subprocess.run(["bash", str(script), mode], env={**env, **extra}, capture_output=True, text=True, check=False)
            results = [(line.split("step=")[1].split()[0], line.split("result=")[1].split()[0])
                       for line in recs.read_text().splitlines() if "gate-step" in line]
            return r.returncode, results, [x for x in (t / "ran").read_text().split() if x != "record"], r.stderr

        rc, res, ran, err = runner("scheduled")
        check(rc == 1 and res == [("nixos-gate-probe", "pass"), ("A", "pass"), ("B", "fail"), ("C", "pass"), ("D", "fail")]
              and "2 red step(s): B D" in err,
              f"seeded: a scheduled run with two red steps runs every step, records each, and ends red naming both ({rc}, {res}, {err.strip()})")
        rc, res, ran, err = runner("manual")
        check(rc == 1 and res == [("nixos-gate-probe", "pass"), ("A", "pass"), ("B", "fail")] and ran == ["probe", "A", "B"],
              f"seeded: a manual run stops at its first red step ({rc}, {res}, {ran})")
        rc, res, ran, err = runner("scheduled", PROBE_RC="1")
        check(rc == 1 and res == [("nixos-gate-probe", "fail"), ("A", "pass"), ("B", "fail"), ("C", "skipped"), ("D", "fail")]
              and "3 red step(s): nixos-gate-probe B D" in err and "C skipped: it reads the gate probe" in err,
              f"seeded: a red probe in a scheduled run: the step reading it is skipped and said so, the rest run ({rc}, {res}, {err.strip()})")
        rc, res, ran, err = runner("manual", PROBE_RC="1")
        check(rc == 1 and res == [("nixos-gate-probe", "fail")] and ran == ["probe"],
              f"seeded: a red probe ends a manual run, recorded as such ({rc}, {res}, {ran})")
        (t / "C").write_text(f"#!/usr/bin/env bash\necho C >> {t}/ran\nexit 77\n")
        rc, res, ran, err = runner("scheduled")
        check(rc == 1 and ("C", "fail") in res, f"a 77 while the probe passed is red, not skipped ({res})")
        for n in ("B", "C", "D"):
            (t / n).write_text(f"#!/usr/bin/env bash\necho {n} >> {t}/ran\nexit 0\n")
        rc, res, ran, err = runner("scheduled")
        check(rc == 0 and all(r == "pass" for _, r in res) and len(res) == 5, f"every step green: the run passes ({rc}, {res})")

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
            # every built check writes a gate-step record; this test reads only what is built. No eval record: the cwd
            # is this checkout (its own cases are below)
            body = body.replace("${lib.getExe record}", "true").replace("${lib.getExe evalRecord}", "false")
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


# the push eval (pushEval) and the flake check (flakeCheck) as writers and readers of the eval record
# (scripts/eval_record.py), each on a throwaway repository with nix stubbed: a pass on a clean tree is recorded with
# its output kinds (and the flake check's host toplevels); a failure or a dirty checkout records nothing; the flake
# check's flake show is not run for a recorded tree, unless NIXOS_EVAL_RECORD=0, the checkout is dirty, or the record is
# another tree's; recorded kinds that differ from flakeKinds still fail the step
pe = re.search(r"\n  pushEval =\s+gate\s+\"nixos-push-eval\".*?''\n(.*?)\n *'';\n", src, re.DOTALL)
check(pe is not None and fc is not None, "pushEval and flakeCheck found in devenv.nix")
if pe and fc:
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        kinds = json.loads((ROOT / "scripts/flake-output-kinds.json").read_text())
        flake_kinds = json.dumps(sorted(kinds), separators=(",", ":"))
        calls, recs = t / "calls", t / "records"
        drv = "/nix/store/" + "d" * 32 + "-nixos-system-h1.drv"
        (t / "bin").mkdir()
        (t / "bin/nix").write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\na = sys.argv[1:]\n"
            f"if a == ['--version']: print(os.environ.get('NIX_STUB_VERSION', {NIXV!r})); sys.exit()\n"
            f"open({str(calls)!r}, 'a').write(' '.join(a) + '\\n')\n"
            f"names = {{'nixosConfigurations': ['h1'], 'formatter': [], 'packages': [], 'checks': ['x86_64-linux'], 'checks.x86_64-linux': ['plain']}}\n"
            "attr = next((x[2:] for x in a if x.startswith('.#')), '')\n"
            f"if a[:2] == ['flake', 'show']: print(json.dumps({{k: 0 for k in os.environ.get('KINDS', ' '.join({kinds!r})).split()}})); sys.exit(int(os.environ.get('SHOW_RC', 0)))\n"
            "if a[:1] == ['build'] and '--dry-run' not in a: sys.exit(int(os.environ.get('BUILD_RC', 0)))\n"
            "if '--expr' in a: print('x86_64-linux', end='')\n"
            "elif any('? driver' in x for x in a): print('[]')\n"
            "elif 'builtins.attrNames' in a: print(json.dumps(names.get(attr, [])))\n"
            f"elif a[:2] == ['eval', '--raw'] and attr.endswith('toplevel.drvPath'): print({drv!r}, end='')\n"
            "elif a[:2] == ['eval', '--raw'] and attr.endswith('.drvPath'): print('/nix/store/' + 'e' * 32 + '-c.drv', end='')\n")
        (t / "bin/nix-store").write_text("#!/usr/bin/env bash\nexit 0\n")
        (t / "bin/uname").write_text("#!/usr/bin/env bash\necho msi-ms7758\n")
        (t / "record").write_text(f'#!/usr/bin/env bash\necho "$*" >> "{recs}"\n')
        evr = t / "eval-record"
        evr.write_text(f'#!/usr/bin/env bash\nexec python3 {ROOT}/scripts/eval_record.py "$@"\n')
        for f in (t / "bin/nix", t / "bin/nix-store", t / "bin/uname", t / "record", evr):
            f.chmod(0o755)
        heavy = re.search(r'\n *gateHeavy = "([^"]*)";\n', src)

        def body_of(m):
            return (textwrap.dedent(m.group(1)).replace("${pkgs.coreutils}/bin/uname", str(t / "bin/uname"))
                    .replace("${gateHeavy}", heavy.group(1) if heavy else "").replace("${lib.getExe record}", str(t / "record"))
                    .replace("${lib.getExe evalRecord}", str(evr)).replace("${flakeKinds}", json.dumps(kinds, separators=(",", ":")))
                    .replace("''$", "$"))
        bodies = {"push": body_of(pe), "flake": body_of(fc)}
        left = {k: re.findall(r"\$\{(?:lib|pkgs|flakeKinds|gateHeavy)[^}]*\}", b) for k, b in bodies.items()}
        check(not any(left.values()), f"pushEval and flakeCheck have no Nix interpolation this test does not stub ({left})")
        pr = t / "repo"
        pr.mkdir()
        genv = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in ("NIXOS_EVAL_RECORD", "NIXOS_QA_TOPLEVELS", "WORK_LOCKS_HELD")}
        (t / "tmp").mkdir()
        genv.update(PATH=f"{t / 'bin'}:{os.environ['PATH']}", XDG_STATE_HOME=str(t / "state"), HOME=str(t), TMPDIR=str(t / "tmp"), GIT_CONFIG_NOSYSTEM="1",
                    GIT_CONFIG_GLOBAL="/dev/null", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        for a in (["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "x"]):
            subprocess.run(["git", *a], cwd=pr, env=genv, check=True)
        (pr / "flake.nix").write_text("{ }\n")
        subprocess.run(["git", "add", "."], cwd=pr, env=genv, check=True)
        subprocess.run(["git", "commit", "-qm", "f"], cwd=pr, env=genv, check=True)
        ptree = subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=pr, env=genv, check=True, capture_output=True, text=True).stdout.strip()
        rfile = t / "state/nixos-eval-records" / f"{ptree}.json"

        def run_(which, **extra):
            calls.write_text(""), recs.write_text("")
            r = subprocess.run(["bash", "-euo", "pipefail", "-c", bodies[which]], cwd=pr, env={**genv, **extra}, capture_output=True, text=True, check=False)
            showed = any(c.startswith("flake show") for c in calls.read_text().splitlines())
            return r.returncode, showed, json.loads(rfile.read_text()) if rfile.exists() else None, r.stderr, recs.read_text()

        rc, showed, rec, err, _ = run_("push")
        check(rc == 0 and showed and rec == {"tree": ptree, "nix": NIXV, "flake_show": "ok", "flake_kinds": flake_kinds},
              f"PE a passing push eval on a clean tree records its flake show and output kinds ({rc}, {rec}, {err[-300:]!r})")
        rfile.unlink()
        rc, showed, rec, err, _ = run_("push", SHOW_RC="1")
        check(rc != 0 and showed and rec is None, f"PE seeded: a failed push eval records nothing ({rc}, {rec})")
        (pr / "untracked").write_text("x\n")
        rc, showed, rec, err, _ = run_("push")
        (pr / "untracked").unlink()
        check(rc == 0 and rec is None, f"PE seeded: a dirty checkout (an untracked file) records nothing ({rc}, {rec})")
        rc, showed, rec, err, rr = run_("flake")
        check(rc == 0 and showed and rec == {"tree": ptree, "nix": NIXV, "flake_show": "ok", "flake_kinds": flake_kinds, "toplevel": {"h1": drv}}
              and "result=cached" not in rr,
              f"FC a miss: the flake check runs its flake show and records it with each host's toplevel ({rc}, {rec}, {err[-300:]!r})")
        rc, showed, rec, err, rr = run_("flake")
        check(rc == 0 and not showed and "flake show skipped: tree" in err and "(eval record; NIXOS_EVAL_RECORD=0 runs it)" in err
              and re.search(r"^gate-step gate=nixos-qa step=nixos-flake-check check=flake-output-kinds owner=msi-ms7758 seconds=0 result=cached ", rr, re.MULTILINE),
              f"FC a hit: no flake show, said so, and a cached gate-step record for it ({rc}, {err[-300:]!r}, {rr!r})")
        rc, showed, rec, err, rr = run_("flake", NIXOS_EVAL_RECORD="0")
        check(rc == 0 and showed, f"FC NIXOS_EVAL_RECORD=0: the flake show runs ({rc})")
        rc, showed, rec, err, rr = run_("flake", NIX_STUB_VERSION="nix (Nix) 9.9")
        check(rc == 0 and showed and rec["nix"] == "nix (Nix) 9.9", f"FC another nix's record is not used, and is replaced ({rc}, {rec})")
        rfile.write_text(json.dumps({**rec, "nix": NIXV, "flake_kinds": '["checks"]'}))
        rc, showed, rec, err, rr = run_("flake")
        check(rc == 1 and not showed and "flake outputs are [\"checks\"]: add the new kind" in err and "result=cached" not in rr,
              f"FC seeded: recorded kinds that differ from the step's still fail it, with no cached record ({rc}, {err[-300:]!r}, {rr!r})")
        rfile.write_text(json.dumps({"tree": ptree, "nix": NIXV, "flake_show": "ok", "flake_kinds": flake_kinds}))
        (pr / "flake.nix").write_text("{ dirty = 1; }\n")
        rc, showed, rec, err, rr = run_("flake")
        subprocess.run(["git", "checkout", "-q", "--", "flake.nix"], cwd=pr, env=genv, check=True)
        check(rc == 0 and showed and "toplevel" not in rec,
              f"FC seeded: a modified tracked file: the record is neither read nor written ({rc}, {rec})")
        other = t / "state/nixos-eval-records" / f"{'f' * 40}.json"
        rfile.rename(other)
        rc, showed, rec, err, rr = run_("flake")
        check(rc == 0 and showed, f"FC seeded: another tree's record is not used ({rc})")
        rfile.unlink()
        rc, showed, rec, err, rr = run_("flake", BUILD_RC="1")
        check(rc != 0 and rec is None, f"FC seeded: a failed flake check records nothing ({rc}, {rec})")
        check(list((t / "tmp").iterdir()) == [], f"the flake check leaves no temporary toplevels file ({list((t / 'tmp').iterdir())})")

# a docs push's doc tests (docTests) build no whole probe: each test builds only its section, under the light lane
dt = re.search(r"\n  docTests =\s+gate\s+\"nixos-doc-tests\".*?''\n(.*?)\n *'';\n", src, re.DOTALL)
check(dt is not None and "getExe probe" not in dt.group(1) and "unset GATE_PROBE" in dt.group(1),
      "docTests builds no whole probe and leaves each test to build its own section")
sys.path.insert(0, str(ROOT / "scripts"))
import gate_probe

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    lock = t / "light"
    lock.touch()
    (t / "bin").mkdir()
    (t / "out.json").write_text('{"s": 1}')
    (t / "bin/nix").write_text(
        f'#!/usr/bin/env bash\ninh=; for f in /proc/self/fd/*; do [ "$(readlink "$f")" != {lock} ] || inh=inherited; done\n'
        f'{{ flock -n {lock} true && echo free || echo held; echo "${{WORK_LOCKS_HELD:-}} $inh"; }} | paste -sd" " > {t}/state\n'
        f'echo "$*" > {t}/argv\necho {t}/out.json\n')
    (t / "bin/nix").chmod(0o755)
    saved = (os.environ.get("PATH", ""), gate_probe.LIGHT, os.environ.pop("GATE_PROBE", None), os.environ.pop("WORK_LOCKS_HELD", None))
    os.environ["PATH"], gate_probe.LIGHT = f"{t / 'bin'}:{saved[0]}", str(lock)
    try:
        got = gate_probe.section("s")
        check(got == 1 and (t / "state").read_text().split() == ["held", "1"] and 'only = [ "s" ]' in (t / "argv").read_text(),
              f"a section built alone is built under the light lock, marked as held, the lock not inherited ({(t / 'state').read_text()!r})")
        os.environ["WORK_LOCKS_HELD"] = "1"
        gate_probe.section("s")
        check((t / "state").read_text().split() == ["free", "1"], "under a caller's light hold the section does not take it again")
        os.environ.pop("WORK_LOCKS_HELD", None)
        holder = subprocess.Popen(["flock", str(lock), "sleep", "4"])
        while subprocess.run(["flock", "-n", str(lock), "true"], check=False).returncode == 0:
            time.sleep(0.05)
        (t / "argv").write_text("")
        gate_probe.LIGHT_WAIT = 1
        try:
            gate_probe.section("s")
            gave_up = ""
        except SystemExit as e:
            gave_up = str(e)
        holder.kill(), holder.wait()
        check("still held after 1 s" in gave_up and (t / "argv").read_text() == "",
              f"seeded: a light lock held past the wait gives up, saying so, and builds nothing ({gave_up!r})")
    finally:
        os.environ["PATH"], gate_probe.LIGHT = saved[0], saved[1]
        os.environ.pop("WORK_LOCKS_HELD", None)
        for k, v in (("GATE_PROBE", saved[2]), ("WORK_LOCKS_HELD", saved[3])):
            if v is not None:
                os.environ[k] = v

print(f"{failed} failed" if failed else "all passed")
sys.exit(1 if failed else 0)
