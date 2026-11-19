#!/usr/bin/env python3
"""The app pin bump (scripts/app-bump.py) on a fake GitHub and a stub for every git, nix and gh call, in a temporary
checkout: a green commit after the pin rewrites only that entry's rev and narHash in apps/registry.json, on a branch
cut from origin/main, and the commit, push and `gh pr create` follow with the dry run's PR text; a replayed pin, no
green commit, an unknown app, an unallowlisted repo, a green commit off the pin's history, a malformed prefetch hash, a
dirty checkout and lenovo are refused or reported before anything is written; --dry-run writes and runs nothing past
the prefetch. No network, no Nix. Usage: test-app-bump.py"""

import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("app_bump", ROOT / "scripts/app-bump.py")
bump = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bump)
failed = 0


def check(ok, what):
    global failed
    failed += not ok
    print(("PASS: " if ok else "FAIL (scripts/test-app-bump.py): ") + what)


APP, REPO = "alert-bridge", "sammasak/alert-bridge"
OLD, GREEN, RED, OTHER = "e" * 40, "a" * 40, "b" * 40, "f" * 40
NAR = "sha256-" + "A" * 43 + "="
REGISTRY = {
    "grants": {APP: {"owner": "sammasak", "repo": REPO, "host": "lenovo-21CB001PMX"}},
    "apps": {APP: {"source": {"repo": REPO, "rev": OLD, "narHash": "sha256-" + "B" * 43 + "="}}},
}
OK_RUNS = {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}]}
RED_RUNS = {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "failure"}]}
NO_STATUS = {"state": "pending", "total_count": 0, "statuses": []}


def github(main, compare="ahead"):
    routes = {f"repos/{REPO}/commits?sha=main&per_page=100": [{"sha": s, "commit": {"committer": {"date": "2026-11-18T10:00:00Z"}}} for s in main]}
    for sha, runs in ((GREEN, OK_RUNS), (RED, RED_RUNS)):
        routes[f"repos/{REPO}/commits/{sha}/check-runs?per_page=100"] = runs
        routes[f"repos/{REPO}/commits/{sha}/status"] = NO_STATUS
    routes[f"repos/{REPO}/compare/{OLD}...{GREEN}"] = {"status": compare, "ahead_by": 2, "html_url": f"https://github.com/{REPO}/compare/{OLD}...{GREEN}"}
    return lambda path: routes[path]


def shell(registry=REGISTRY, dirty="", nar=NAR, fail=None):
    """A stub for every subprocess the bump runs: answers by argv prefix and records each call."""
    calls = []

    def run(argv, timeout=600):
        calls.append(argv)
        if fail and argv[: len(fail)] == fail:
            raise RuntimeError(f"{' '.join(argv)}: stub failure")
        head = tuple(argv[:3])
        if head == ("git", "status", "--porcelain"):
            return dirty
        if head == ("git", "show", "origin/main:apps/registry.json"):
            return json.dumps(registry)
        if head == ("nix", "flake", "prefetch"):
            return json.dumps({"hash": nar, "storePath": "/nix/store/x-source"})
        if head[:3] == ("gh", "pr", "create"):
            return "https://github.com/sammasak/nixos-config/pull/9999\n"
        return ""

    return run, calls


def bumped(argv, api, run, host="acer-swift"):
    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "apps").mkdir()
    (tmp / "apps/registry.json").write_text(json.dumps(REGISTRY, indent=2) + "\n")
    bump.ROOT = tmp
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = bump.main(argv, api, run, lambda: host)
    return code, out.getvalue(), err.getvalue(), json.loads((tmp / "apps/registry.json").read_text())


def wrote_nothing(name, calls, written):
    ran = [c[:2] for c in calls if c[:2] in (["git", "switch"], ["git", "commit"], ["git", "push"], ["gh", "pr"])]
    check(written == REGISTRY and not ran, f"{name}: the registry is untouched and no branch, commit, push or PR ({ran})")


run, calls = shell()
code, out, err, written = bumped([APP], github([RED, GREEN, OLD]), run)
want = json.loads(json.dumps(REGISTRY))
want["apps"][APP]["source"] |= {"rev": GREEN, "narHash": NAR}
check(code == 0 and written == want, f"bump: exit 0, only apps.{APP}.source.rev and narHash change ({code}, {err.strip()})")
heads = [c[:3] for c in calls]
order = [["git", "status", "--porcelain"], ["git", "fetch", "origin"], ["git", "show", "origin/main:apps/registry.json"],
         ["nix", "flake", "prefetch"], ["git", "switch", "--create"], ["git", "add", "apps/registry.json"],
         ["git", "commit", "-m"], ["git", "push", "--set-upstream"], ["gh", "pr", "create"]]
check(heads == order, f"bump: status, fetch, read origin/main, prefetch, branch, add, commit, push, PR, in that order ({heads})")
by = {tuple(c[:3]): c for c in calls}
check(by[("nix", "flake", "prefetch")][-1] == f"git+ssh://git@github.com/{REPO}?ref=refs/heads/main&rev={GREEN}",
      "bump: prefetches the green rev on main over ssh, as pins.nix fetches it")
check(by[("git", "switch", "--create")][3:] == [f"app-bump/{APP}-{GREEN[:12]}", "origin/main"], "bump: the branch is cut from origin/main")
commit = by[("git", "commit", "-m")]
check(len(commit[3]) <= 72 and commit[5].startswith("Why: ") and "Refs #560" in commit, f"bump: commit subject <= 72, a Why: line, Refs #560 ({commit[3:]})")
pr = by[("gh", "pr", "create")]
body = pr[pr.index("--body") + 1]
check(all(s in body for s in (GREEN, OLD, NAR, f"compare/{OLD}...{GREEN}", RED, "apps/registry.json", "Refs #560")),
      "bump: the PR body is the dry run's: new and old rev, narHash, compare, the skipped red head")

run, calls = shell()
code, out, err, written = bumped([APP, "--dry-run"], github([GREEN, OLD]), run)
check(code == 0 and GREEN in out and NAR in out, f"--dry-run: prints the new entry and the PR ({code}, {err.strip()})")
wrote_nothing("--dry-run", calls, written)
check(not any(c[:2] == ["git", "status"] for c in calls), "--dry-run: runs on a dirty checkout")

for name, main, word in (("replay", [OLD], "nothing to bump"), ("no green", [RED, RED], "no green commit")):
    run, calls = shell()
    code, out, err, written = bumped([APP], github(main), run)
    check(code == 0 and word in out and not any(c[0] == "nix" for c in calls), f"{name}: exit 0, {word!r}, no prefetch ({code}, {out.strip()})")
    wrote_nothing(name, calls, written)

bad_repo = json.loads(json.dumps(REGISTRY))
bad_repo["apps"][APP]["source"]["repo"] = "mallory/alert-bridge"
short = json.loads(json.dumps(REGISTRY))
short["apps"][APP]["source"]["rev"] = "e2d61abf"
REFUSALS = (
    ("lenovo", [APP], github([GREEN, OLD]), shell(), "lenovo-21CB001PMX", "refused on lenovo-21CB001PMX"),
    ("dirty checkout", [APP], github([GREEN, OLD]), shell(dirty=" M flake.nix\n"), "acer-swift", "uncommitted changes"),
    ("unknown app", ["nope"], github([GREEN, OLD]), shell(), "acer-swift", f"no apps.nope; registered: {APP}"),
    ("unallowlisted repo", [APP], github([GREEN, OLD]), shell(registry=bad_repo), "acer-swift", f"grants.{APP} allowlists ({REPO})"),
    ("short rev", [APP], github([GREEN, OLD]), shell(registry=short), "acer-swift", f"apps.{APP}.source.rev"),
    ("off the pin's history", [APP], github([GREEN, OLD], compare="diverged"), shell(), "acer-swift", "is not an ancestor"),
    ("base32 prefetch hash", [APP], github([GREEN, OLD]), shell(nar="sha256:0abc"), "acer-swift", "does not match"),
)
for name, argv, api, (run, calls), host, word in REFUSALS:
    code, out, err, written = bumped(argv, api, run, host)
    check(code == 2 and word in err, f"{name}: exit 2 naming {word!r} ({code}, {err.strip()})")
    wrote_nothing(name, calls, written)
    if name == "lenovo":
        check(calls == [], "lenovo: refused before any git, nix or gh call")

run, calls = shell(fail=["git", "push"])
code, out, err, written = bumped([APP], github([GREEN, OLD]), run)
check(code == 1 and "stub failure" in err and not any(c[:2] == ["gh", "pr"] for c in calls), "a failed push exits 1 and opens no PR")

pins = (ROOT / "lib/app-manifest/pins.nix").read_text()
check(f'strMatching "{bump.NAR}"' in pins, "NAR is pins.nix's narHash pattern, verbatim")
check('strMatching "[0-9a-f]{40}"' in pins and bump.dry.REV == "[0-9a-f]{40}", "pins.nix's rev pattern is the dry run's REV")
live = json.loads((ROOT / "apps/registry.json").read_text())
check((ROOT / "apps/registry.json").read_text() == json.dumps(live, indent=2) + "\n", "apps/registry.json is in the layout the bump writes")

sys.exit(1 if failed else 0)
