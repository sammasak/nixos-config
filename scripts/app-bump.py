#!/usr/bin/env python3
"""Bump one app's pin in apps/registry.json (#560) and open the PR: the newest green commit on the app repository's
main (scripts/app-bump-dry-run.py's green_after: its green rule and its refusals), its narHash from `nix flake prefetch`,
the registry entry rewritten on a new branch cut from origin/main, committed, pushed and opened with `gh pr create`
(the body is the dry run's). Nothing else is edited: hosts read the source from the registry (lib/app-manifest/pins.nix).

Prefetching fetches and hashes the app's tree, so it refuses to run on lenovo (the DNS host, no evaluation or fetch
there); run it on acer, msi or asus inside `devenv shell`, so the commit and pre-push hooks run. Needs a clean
checkout, the user's ssh key for the app repository and their `gh` login; no other token.

Exit: 0 a PR opened (or, with --dry-run, printed) or nothing to bump; 2 a refusal; 1 a failed step.
Usage: app-bump.py APP [--dry-run]"""

import argparse
import importlib.util
import json
import pathlib
import re
import socket
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("app_bump_dry_run", ROOT / "scripts/app-bump-dry-run.py")
dry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dry)

REGISTRY = "apps/registry.json"
LENOVO = "lenovo-21CB001PMX"
# pins.nix's narHash pattern, verbatim (scripts/test-app-bump.py fails when they drift)
NAR = "sha256-[A-Za-z0-9+/]{43}="


def sh(argv, timeout=600):
    r = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(argv)}: {r.stderr.strip() or r.returncode}")
    return r.stdout


def pin_of(registry, app):
    dry.need(dry.APP, app, "APP")
    at = f"apps.{app}"
    if app not in registry.get("apps", {}):
        raise dry.Refused(f"{REGISTRY}: no {at}; registered: {', '.join(sorted(registry.get('apps', {})))}.")
    grant = registry.get("grants", {}).get(app)
    if grant is None:
        raise dry.Refused(f"{at}: no grants.{app}, so the platform has not admitted it.")
    allowed = dry.need(dry.REPO, grant.get("repo"), f"grants.{app}.repo")
    source = registry["apps"][app].get("source", {})
    repo = dry.need(dry.REPO, source.get("repo"), f"{at}.source.repo")
    if repo != allowed:
        raise dry.Refused(f"{at}.source.repo: {repo} is not the repository grants.{app} allowlists ({allowed}).")
    rev = dry.need(dry.REV, source.get("rev"), f"{at}.source.rev")
    return dry.Pin(app, repo, rev, grant, None, None, None)


def prefetch(run, repo, rev):
    out = run(["nix", "flake", "prefetch", "--json", f"git+ssh://git@github.com/{repo}?ref=refs/heads/main&rev={rev}"])
    return dry.need(NAR, json.loads(out).get("hash"), f"nix flake prefetch {repo} {rev}: hash")


def main(argv=None, api=dry.gh_api, run=sh, host=socket.gethostname):
    p = argparse.ArgumentParser(description="Pin one app to its repository's newest green main and open the PR.")
    p.add_argument("app")
    p.add_argument("--dry-run", action="store_true", help="print the new entry and the PR; write, commit and push nothing")
    a = p.parse_args(argv)
    try:
        if host() == LENOVO:
            raise dry.Refused(f"refused on {LENOVO}: the prefetch fetches and hashes the app's tree; run it on acer.")
        if not a.dry_run and run(["git", "status", "--porcelain"]).strip():
            raise dry.Refused("the checkout has uncommitted changes; the bump cuts its branch from origin/main.")
        # before anything is written: a host without a gh login (asus, msi) would push the branch and open no PR
        if not a.dry_run:
            try:
                run(["gh", "auth", "status"])
            except RuntimeError as e:
                raise dry.Refused(f"gh is not logged in here, so the PR could not be opened; run it on acer ({e}).") from None
        run(["git", "fetch", "origin", "main"])
        registry = json.loads(run(["git", "show", f"origin/main:{REGISTRY}"]))
        pin = pin_of(registry, a.app)
        green = dry.green_after(api, pin)
        if green.sha is None:
            why = "nothing to bump" if green.reached_pin else f"no green commit in main's last {dry.WINDOW}"
            print(f"app-bump: {a.app}: {why}; pinned at {pin.rev}")
            return 0
        nar = prefetch(run, pin.repo, green.sha)
        registry["apps"][a.app]["source"] |= {"rev": green.sha, "narHash": nar}
        pr = dry.pr(pin, green, f"`{a.app}` in {REGISTRY}", f"narHash: {nar} (nix flake prefetch on {host()})")
        if a.dry_run:
            print(json.dumps({"entry": registry["apps"][a.app], "pr": pr}, indent=2))
            return 0
        branch = f"app-bump/{a.app}-{green.sha[:12]}"
        run(["git", "switch", "--create", branch, "origin/main"])
        (ROOT / REGISTRY).write_text(json.dumps(registry, indent=2) + "\n")
        run(["git", "add", REGISTRY])
        why = f"Why: {green.sha} is the newest green commit on {pin.repo}'s main."
        run(["git", "commit", "-m", pr["title"], "-m", why, "-m", "Refs #560"])
        run(["git", "push", "--set-upstream", "origin", branch], timeout=None)
        url = run(["gh", "pr", "create", "--base", "main", "--head", branch, "--title", pr["title"], "--body", pr["body"]])
    except dry.Refused as e:
        print(f"app-bump: refused: {e}", file=sys.stderr)
        return 2
    except (OSError, RuntimeError, KeyError, TypeError, ValueError, subprocess.TimeoutExpired) as e:
        print(f"app-bump: failed: {e!r}", file=sys.stderr)
        return 1
    print(f"app-bump: {a.app}: {pin.rev} -> {green.sha}: {url.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
