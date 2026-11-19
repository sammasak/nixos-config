#!/usr/bin/env python3
"""The app pin bump dry run (scripts/app-bump-dry-run.py) on a fake GitHub and a temporary flake.nix and flake.lock,
without network or Nix: replaying the pinned rev is an empty diff; a newer green commit gives the flake.nix line and
the flake.lock fields, narHash pending unless a fetcher is passed; red, pending and unchecked heads are skipped for an
older green one, never pinned; no green commit is reported, not bumped; an unallowlisted repo, a short or branch rev,
a pin flake.nix does not hold and a green commit off the pin's history are refused, naming the field. Its patterns
are admission's own, verbatim. Once through `gh` on PATH: a stub `nix` that is never called, and nothing written.
Usage: test-app-bump-dry-run.py [SCRIPT] (a mutated copy for a seed)."""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "scripts/app-bump-dry-run.py"
spec = importlib.util.spec_from_file_location("app_bump_dry_run", SCRIPT)
bump = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bump)
failed = 0


def check(ok, what):
    global failed
    failed += not ok
    print(("PASS: " if ok else "FAIL (scripts/test-app-bump-dry-run.py): ") + what)


OLD = "7f41955749fc473d11173ffbc18e76973a7bb224"
GREEN = "a" * 40
RED = "b" * 40
PENDING = "c" * 40
UNCHECKED = "d" * 40
REPO = "sammasak/herman"
LINE = f'    herman.url = "git+ssh://git@github.com/{REPO}?rev={OLD}";'
FLAKE_NIX = f"{{\n  inputs = {{\n{LINE}\n    herman.flake = false;\n  }};\n}}\n"
FLAKE_LOCK = {
    "nodes": {
        "herman": {
            "flake": False,
            "locked": {
                "lastModified": 1791192856,
                "narHash": "sha256-f1Z7a7ZyLSUc9plk5Po4JYwGYGYkBwBv3ZIdwTMf0Ig=",
                "ref": "refs/heads/main",
                "rev": OLD,
                "revCount": 1097,
                "type": "git",
                "url": f"ssh://git@github.com/{REPO}",
            },
            "original": {"rev": OLD, "type": "git", "url": f"ssh://git@github.com/{REPO}"},
        },
        "root": {"inputs": {"herman": "herman"}},
    },
    "root": "root",
    "version": 7,
}
GRANT = {"owner": "sammasak", "repo": REPO, "host": "acer-swift", "hostnames": ["herman-next"], "public": True}


def registry(repo=REPO, rev=OLD):
    return {"grants": {"herman": GRANT}, "apps": {"herman": {"source": {"repo": repo, "rev": rev, "package": "web"}}}}


def run_(name, conclusion, status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion}


NO_STATUS = {"state": "pending", "total_count": 0, "statuses": []}
CHECKS = {
    GREEN: ({"total_count": 1, "check_runs": [run_("build", "success")]}, NO_STATUS),
    RED: ({"total_count": 2, "check_runs": [run_("build", "success"), run_("test", "failure")]}, NO_STATUS),
    PENDING: ({"total_count": 1, "check_runs": [run_("build", None, "in_progress")]}, NO_STATUS),
    UNCHECKED: ({"total_count": 0, "check_runs": []}, NO_STATUS),
}


def github(main, compare_status="ahead", ahead_by=3):
    """A read-only GitHub: main's commits newest first, the CHECKS of each and a compare; any other path fails."""
    routes = {
        f"repos/{REPO}/commits?sha=main&per_page=100": [
            {"sha": s, "commit": {"committer": {"date": "2026-11-17T10:00:00Z"}}} for s in main
        ]
    }
    for sha, (runs, status) in CHECKS.items():
        routes[f"repos/{REPO}/commits/{sha}/check-runs?per_page=100"] = runs
        routes[f"repos/{REPO}/commits/{sha}/status"] = status
    routes[f"repos/{REPO}/compare/{OLD}...{GREEN}"] = {
        "status": compare_status,
        "ahead_by": ahead_by,
        "html_url": f"https://github.com/{REPO}/compare/{OLD}...{GREEN}",
    }
    calls = []

    def api(path):
        calls.append(path)
        if path not in routes:
            raise RuntimeError(f"unstubbed GitHub path {path}")
        return routes[path]

    return api, calls, routes


def dry_run(tmp, reg, api, extra=(), nar_hash=None):
    (tmp / "registry.json").write_text(json.dumps(reg))
    before = {p.name: p.read_bytes() for p in tmp.iterdir()}
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = bump.main(["--registry", str(tmp / "registry.json"), "--flake", str(tmp), *extra], api, nar_hash)
    after = {p.name: p.read_bytes() for p in tmp.iterdir()}
    check(before == after, f"{extra or 'text'}: the flake directory is left byte for byte as it was")
    return code, out.getvalue(), err.getvalue()


def case(name):
    """Run a case now; a crash (a seeded script that prints no JSON, say) is that case's FAIL, not the test's end."""

    def run(fn):
        try:
            fn(tmp)
        except Exception as e:
            check(False, f"{name}: crashed with {e!r}")

    return run


def fields(r):
    return {f: (o, n) for f, o, n in r["flake.lock"]["fields"]}


with tempfile.TemporaryDirectory() as d:
    tmp = pathlib.Path(d)
    (tmp / "flake.nix").write_text(FLAKE_NIX)
    (tmp / "flake.lock").write_text(json.dumps(FLAKE_LOCK))

    @case("replay")
    def _(tmp):
        api, calls, _ = github([OLD, "e" * 40])
        code, out, _ = dry_run(tmp, registry(), api, ["--json"])
        [r] = json.loads(out)
        check(
            code == 0 and r["result"] == "nothing-to-bump" and r["new_rev"] == OLD and "flake.nix" not in r,
            f"replay: main's head is the pin, nothing to bump and no diff ({r.get('result')}, exit {code})",
        )
        check(not any("check-runs" in c or "compare" in c for c in calls), "replay: no check or compare is read")
        code, out, _ = dry_run(tmp, registry(), api)
        check(
            code == 0 and "nothing-to-bump" in out and "diff empty" in out, f"replay as text says so: {out.strip()!r}"
        )

    @case("newer green")
    def _(tmp):
        api, calls, _ = github([GREEN, OLD])
        code, out, _ = dry_run(tmp, registry(), api, ["--json"])
        [r] = json.loads(out)
        f = fields(r)
        check(code == 0 and r["result"] == "bump" and r["new_rev"] == GREEN, f"newer green: a bump to it (exit {code})")
        check(r["flake.nix"] == [LINE, LINE.replace(OLD, GREEN)], f"newer green: the flake.nix line ({r['flake.nix']})")
        check(
            f["locked.rev"] == (OLD, GREEN) and f["original.rev"] == (OLD, GREEN),
            "newer green: locked and original rev",
        )
        check(
            f["locked.lastModified"] == (1791192856, 1794909600),
            f"lastModified is the commit time: {f['locked.lastModified']}",
        )
        check(f["locked.revCount"] == (1097, 1100), f"revCount moves by compare's ahead_by: {f['locked.revCount']}")
        check(
            f["locked.narHash"][1].startswith("pending: ") and "nix flake lock" in f["locked.narHash"][1],
            f"narHash is pending for a gate host: {f['locked.narHash'][1]!r}",
        )
        body = r["pr"]["body"]
        check(len(r["pr"]["title"]) <= 72 and GREEN[:12] in r["pr"]["title"], f"PR title: {r['pr']['title']!r}")
        check(
            all(s in body for s in (GREEN, OLD, f"compare/{OLD}...{GREEN}", '"repo": "sammasak/herman"', "Refs #560")),
            "PR body: commit, old and new rev, compare URL, the grant checked against",
        )
        code, out, _ = dry_run(tmp, registry(), api, ["--json"], nar_hash=lambda repo, rev: f"sha256-{repo}@{rev[:4]}")
        check(
            fields(json.loads(out)[0])["locked.narHash"][1] == "sha256-sammasak/herman@aaaa",
            "a fetcher passed in fills narHash",
        )

    @case("red, pending and unchecked heads")
    def _(tmp):
        api, calls, _ = github([RED, PENDING, UNCHECKED, GREEN, OLD])
        code, out, _ = dry_run(tmp, registry(), api, ["--json"])
        [r] = json.loads(out)
        check(
            code == 0
            and r["new_rev"] == GREEN
            and r["skipped"] == [[RED, "red"], [PENDING, "pending"], [UNCHECKED, "unchecked"]],
            f"red, pending and unchecked heads are skipped for the older green one ({r['new_rev']}, {r['skipped']})",
        )
        check(RED in r["pr"]["body"], "the skipped red head is named in the PR body")

    @case("red only or no green")
    def _(tmp):
        api, calls, _ = github([RED, OLD])
        code, out, _ = dry_run(tmp, registry(), api, ["--json"])
        [r] = json.loads(out)
        check(
            code == 0 and r["result"] == "nothing-to-bump" and r["why"] == "no newer main commit is green",
            f"only a red commit after the pin: nothing to bump ({r['result']})",
        )
        api, calls, _ = github([RED, PENDING])
        code, out, _ = dry_run(tmp, registry(), api, ["--json"])
        [r] = json.loads(out)
        check(
            code == 0 and r["result"] == "no-green" and r["new_rev"] is None,
            f"no green and no pin in the window: no-green ({r['result']})",
        )

    @case("off the pin's history")
    def _(tmp):
        api, calls, _ = github([GREEN, OLD], compare_status="diverged")
        code, _, err = dry_run(tmp, registry(), api, ["--json"])
        check(
            code == 2 and "apps.herman.source.rev" in err and "diverged" in err,
            f"a green commit off the pin's history is refused: {err.strip()!r}",
        )

    for name, reg, field in [
        (
            "an unallowlisted repo",
            registry(repo="mallory/herman"),
            "apps.herman.source.repo: mallory/herman is not the repository grants.herman allowlists",
        ),
        ("a short rev", registry(rev=OLD[:7]), "apps.herman.source.rev: '7f41955' does not match"),
        ("a branch rev", registry(rev="main"), "apps.herman.source.rev: 'main' does not match"),
        ("an uppercase rev", registry(rev=OLD.upper()), "apps.herman.source.rev"),
        ("a rev flake.nix does not pin", registry(rev=GREEN), "flake.nix: herman.url"),
        ("an app without a grant", {"grants": {}, "apps": registry()["apps"]}, "apps.herman: no grants.herman"),
        (
            "a grant repo off the pattern",
            {"grants": {"herman": GRANT | {"repo": "herman"}}, "apps": registry()["apps"]},
            "grants.herman.repo",
        ),
    ]:
        api, calls, _ = github([GREEN, OLD])
        code, out, err = dry_run(tmp, reg, api, ["--json"])
        check(
            code == 2 and field in err and out == "" and calls == [],
            f"{name} is refused before any GitHub read: {err.strip()!r}",
        )

    lock = json.loads(json.dumps(FLAKE_LOCK))
    lock["nodes"]["herman"]["locked"]["rev"] = GREEN
    (tmp / "flake.lock").write_text(json.dumps(lock))
    api, calls, _ = github([GREEN, OLD])
    code, _, err = dry_run(tmp, registry(), api, ["--json"])
    check(
        code == 2 and "flake.lock: herman" in err,
        f"a lock that disagrees with the registry is refused: {err.strip()!r}",
    )
    (tmp / "flake.lock").write_text(json.dumps(FLAKE_LOCK))

    names = (ROOT / "lib/app-manifest/names.nix").read_text()
    schema = (ROOT / "lib/app-manifest/v1alpha1.nix").read_text()
    check(
        f'app = "{bump.APP}";' in names and f'repo = "{bump.REPO}";' in names, "APP and REPO are names.nix's, verbatim"
    )
    check(f'strMatching "{bump.REV}"' in schema, "REV is v1alpha1.nix's source.rev pattern, verbatim")

    # the CLI through the default runner: gh on PATH serves the same fake, a nix there marks any call
    bin_ = tmp / "bin"
    bin_.mkdir()
    _, _, routes = github([GREEN, OLD])
    (tmp / "routes.json").write_text(json.dumps(routes))
    (bin_ / "gh").write_text(
        f"#!{sys.executable}\nimport json, sys\nr = json.load(open({str(tmp / 'routes.json')!r}))\n"
        "sys.exit(1) if sys.argv[1:2] != ['api'] or sys.argv[2] not in r else print(json.dumps(r[sys.argv[2]]))\n"
    )
    (bin_ / "nix").write_text(f"#!/bin/sh\ntouch {tmp / 'nix-called'}\nexit 1\n")
    for stub in ("gh", "nix"):
        (bin_ / stub).chmod(0o755)
    (tmp / "registry.json").write_text(json.dumps(registry()))
    p = subprocess.run(
        [sys.executable, str(SCRIPT), "--registry", str(tmp / "registry.json"), "--flake", str(tmp), "--json"],
        capture_output=True,
        text=True,
        env={"PATH": str(bin_)},
        timeout=60,
    )
    check(
        p.returncode == 0 and json.loads(p.stdout or "[{}]")[0].get("new_rev") == GREEN,
        f"CLI through gh on PATH: exit {p.returncode}, {p.stderr.strip()!r}",
    )
    check(not (tmp / "nix-called").exists(), "no nix is run")
    os.remove(bin_ / "gh")
    p = subprocess.run(
        [sys.executable, str(SCRIPT), "--registry", str(tmp / "registry.json"), "--flake", str(tmp)],
        capture_output=True,
        text=True,
        env={"PATH": str(bin_)},
        timeout=60,
    )
    check(
        p.returncode == 1 and p.stdout == "" and "read failed: " in p.stderr,
        f"a failed GitHub read exits 1 and prints no PR ({p.returncode}, {p.stderr.strip()!r})",
    )

sys.exit(1 if failed else 0)
