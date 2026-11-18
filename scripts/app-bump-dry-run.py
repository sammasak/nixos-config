#!/usr/bin/env python3
"""Dry run of an app's pin bump (#560): per registered app, the newest green commit on its repository's main and the
pin PR that would move the app's flake input to it (the flake.nix line, the flake.lock node, a title and body),
printed to stdout. Reads the registry file, flake.nix and flake.lock, and GitHub through read-only `gh api` calls;
writes nothing, evaluates and fetches no Nix, needs no token beyond gh's own read.

Registry (--registry FILE): the evaluated registry cut to what a bump reads, in the shape of the config
lib/app-manifest/admission.nix declares (produced on a gate host, or a fixture):
  {"grants": {"<app>": {"owner": "<login>", "repo": "<owner/name>", "host": "<host>", ...}},
   "apps":   {"<app>": {"source": {"repo": "<owner/name>", "rev": "<40 hex>", ...}}}}
Each app's flake input is named after the app and pinned as
`<app>.url = "git+ssh://git@github.com/<repo>?rev=<rev>";`; flake.nix, flake.lock and the registry must agree on
repo and rev, or the app is refused.

Green: walking main newest first (at most WINDOW commits), the first commit with at least one successful check, every
check run completed with a conclusion in OK and, when it has commit statuses, a combined status of success. Every
check counts as required: a private repository on GitHub's free plan cannot read branch protection. Red, pending and
unchecked commits are skipped, never pinned. Reaching the pinned rev first means nothing to bump; a green commit must
descend from the pinned rev (GitHub's compare says `ahead`), so a pin never moves sideways or back.

narHash: hashing the new tree needs a fetch, so it is printed as pending, for `nix flake lock` on a gate host after the
flake.nix edit; `main`'s nar_hash parameter takes a fetcher where fetching is allowed.

Exit: 0 a result per app (bump, nothing-to-bump, no-green); 2 a refusal naming the field; 1 a failed read (GitHub
or an input file).
Usage: app-bump-dry-run.py --registry FILE [--flake DIR] [--json]"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime

ROOT = pathlib.Path(__file__).resolve().parent.parent
# admission's own patterns, verbatim: app and repo from lib/app-manifest/names.nix, source.rev from
# lib/app-manifest/v1alpha1.nix (scripts/test-app-bump-dry-run.py fails when they drift)
APP = "[a-z][a-z0-9-]{0,30}"
REPO = "[A-Za-z0-9-]+/[A-Za-z0-9._-]+"
REV = "[0-9a-f]{40}"
BRANCH = "main"
WINDOW = 100
OK = {"success", "neutral", "skipped"}
PENDING = "pending: computed by `nix flake lock` on a gate host after the flake.nix edit"


class Refused(Exception):
    pass


def need(pattern, value, at):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise Refused(f"{at}: {value!r} does not match `{pattern}`.")
    return value


def gh_api(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {path}: {r.stderr.strip() or r.returncode}")
    return json.loads(r.stdout)


@dataclass(frozen=True)
class Pin:
    app: str
    repo: str
    rev: str
    grant: dict
    line: str
    node: str
    lock: dict


def read_pins(registry, flake_nix, flake_lock):
    grants, apps = registry.get("grants", {}), registry.get("apps", {})
    inputs = flake_lock["nodes"][flake_lock["root"]]["inputs"]
    pins = []
    for app in sorted(apps):
        at = f"apps.{app}"
        need(APP, app, at)
        if app not in grants:
            raise Refused(f"{at}: no grants.{app}, so the platform has not admitted it.")
        allowed = need(REPO, grants[app].get("repo"), f"grants.{app}.repo")
        source = apps[app].get("source", {})
        repo = need(REPO, source.get("repo"), f"{at}.source.repo")
        if repo != allowed:
            raise Refused(f"{at}.source.repo: {repo} is not the repository grants.{app} allowlists ({allowed}).")
        rev = need(REV, source.get("rev"), f"{at}.source.rev")
        lines = re.findall(rf'^ *{re.escape(app)}\.url = "git\+ssh://git@github\.com/[^"]*";$', flake_nix, re.M)
        if len(lines) != 1:
            raise Refused(f"flake.nix: {app}.url: {len(lines)} lines pin it, not one.")
        if f'github.com/{repo}?rev={rev}"' not in lines[0]:
            raise Refused(f"flake.nix: {app}.url: {lines[0].strip()} is not {repo} at {at}.source.rev ({rev}).")
        node = inputs.get(app)
        locked = flake_lock["nodes"].get(node, {}).get("locked", {}) if isinstance(node, str) else {}
        if locked.get("url") != f"ssh://git@github.com/{repo}" or locked.get("rev") != rev:
            raise Refused(f"flake.lock: {app}: locked {locked.get('url')} at {locked.get('rev')}, not {repo} at {rev}.")
        pins.append(Pin(app, repo, rev, grants[app], lines[0], node, flake_lock["nodes"][node]))
    return pins


def verdict(api, repo, sha):
    runs = api(f"repos/{repo}/commits/{sha}/check-runs?per_page=100")
    status = api(f"repos/{repo}/commits/{sha}/status")
    if runs["total_count"] > len(runs["check_runs"]):
        return "unknown: over 100 check runs", ()
    checks = runs["check_runs"]
    names = tuple(r["name"] for r in checks) + tuple(s["context"] for s in status["statuses"])
    if any(r["status"] != "completed" for r in checks):
        return "pending", names
    if any(r["conclusion"] not in OK for r in checks):
        return "red", names
    if status["total_count"] and status["state"] != "success":
        return status["state"], names
    if not any(r["conclusion"] == "success" for r in checks) and not status["total_count"]:
        return "unchecked", names
    return "green", names


@dataclass(frozen=True)
class Green:
    """main's newest green commit after the pin (sha None: none), lane-neutral: lane 1 renders it as a pin diff, a
    release lane would record it."""

    sha: str | None
    date: str | None
    checks: tuple
    skipped: tuple
    reached_pin: bool
    ahead_by: int = 0
    compare_url: str = ""
    compare_status: str = ""


def green_main(api, repo, pinned, window=WINDOW):
    skipped = []
    for c in api(f"repos/{repo}/commits?sha={BRANCH}&per_page={window}"):
        sha = c.get("sha")
        if not isinstance(sha, str) or re.fullmatch(REV, sha) is None:
            raise RuntimeError(f"{repo}: GitHub listed a main commit with sha {sha!r}")
        if sha == pinned:
            return Green(None, None, (), tuple(skipped), True)
        v, names = verdict(api, repo, sha)
        if v == "green":
            cmp = api(f"repos/{repo}/compare/{pinned}...{sha}")
            return Green(
                sha,
                c["commit"]["committer"]["date"],
                names,
                tuple(skipped),
                False,
                cmp["ahead_by"],
                cmp["html_url"],
                cmp["status"],
            )
        skipped.append((sha, v))
    return Green(None, None, (), tuple(skipped), False)


def epoch(iso):
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())


def pin_diff(pin, green, nar_hash=None):
    """The lane-1 rendering: the flake.nix line, the flake.lock node fields and the PR a bot would open."""
    old = pin.lock["locked"]
    lock = [
        ["locked.rev", old["rev"], green.sha],
        ["locked.lastModified", old.get("lastModified"), epoch(green.date)],
        ["locked.narHash", old.get("narHash"), nar_hash(pin.repo, green.sha) if nar_hash else PENDING],
    ]
    if "revCount" in old:
        lock.append(["locked.revCount", old["revCount"], old["revCount"] + green.ahead_by])
    if "rev" in pin.lock.get("original", {}):
        lock.append(["original.rev", pin.lock["original"]["rev"], green.sha])
    skipped = "".join(f"\n  - {s} ({v})" for s, v in green.skipped) or " none"
    body = (
        f"Pins flake input `{pin.app}` to the newest green commit on {pin.repo}'s {BRANCH}.\n\n"
        f"- App commit: {green.sha} ({green.date}), checks: {', '.join(green.checks)}\n"
        f"- Old rev: {pin.rev}\n- New rev: {green.sha}\n"
        f"- Compare: {green.compare_url} ({green.ahead_by} commits)\n"
        f"- Newer {BRANCH} commits skipped, not green:{skipped}\n"
        f"- flake.lock narHash: {lock[2][2]}\n"
        f"- Checked against grants.{pin.app}: {json.dumps(pin.grant, sort_keys=True)}\n\n"
        "Refs #560"
    )
    return {
        "flake.nix": [pin.line, pin.line.replace(f"?rev={pin.rev}", f"?rev={green.sha}")],
        "flake.lock": {"node": pin.node, "fields": lock},
        "pr": {"title": f"{pin.app}: pin {pin.repo} to {green.sha[:12]}", "body": body},
    }


def result(api, pin, nar_hash):
    green = green_main(api, pin.repo, pin.rev)
    out = {"app": pin.app, "repo": pin.repo, "old_rev": pin.rev, "skipped": [list(s) for s in green.skipped]}
    if green.sha is None:
        if green.reached_pin:
            why = "main's head is the pinned rev" if not green.skipped else "no newer main commit is green"
            return out | {"result": "nothing-to-bump", "new_rev": pin.rev, "why": why}
        why = f"no green commit in main's last {WINDOW}, and the pin is not among them"
        return out | {"result": "no-green", "new_rev": None, "why": why}
    if green.compare_status != "ahead":
        raise Refused(
            f"apps.{pin.app}.source.rev: {pin.rev} is not an ancestor of {pin.repo}'s green {BRANCH} {green.sha}"
            f" (compare: {green.compare_status})."
        )
    return out | {"result": "bump", "new_rev": green.sha} | pin_diff(pin, green, nar_hash)


def text(r):
    head = f"== {r['app']} ({r['repo']}): {r['result']}"
    if r["result"] != "bump":
        return f"{head}: {r['why']}; diff empty\n"
    lock = "".join(f"  {f}: {o} -> {n}\n" for f, o, n in r["flake.lock"]["fields"])
    return (
        f"{head} {r['old_rev']} -> {r['new_rev']}\n--- flake.nix\n-{r['flake.nix'][0]}\n+{r['flake.nix'][1]}\n"
        f"--- flake.lock nodes.{r['flake.lock']['node']}\n{lock}--- PR: {r['pr']['title']}\n{r['pr']['body']}\n"
    )


def main(argv=None, api=gh_api, nar_hash=None):
    p = argparse.ArgumentParser(description="Print the pin PR each registered app's green main would get.")
    p.add_argument("--registry", required=True, type=pathlib.Path)
    p.add_argument("--flake", default=ROOT, type=pathlib.Path, help="the directory holding flake.nix and flake.lock")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    try:
        pins = read_pins(
            json.loads(a.registry.read_text()),
            (a.flake / "flake.nix").read_text(),
            json.loads((a.flake / "flake.lock").read_text()),
        )
        results = [result(api, pin, nar_hash) for pin in pins]
    except Refused as e:
        print(f"app-bump-dry-run: refused: {e}", file=sys.stderr)
        return 2
    except (OSError, RuntimeError, KeyError, TypeError, ValueError, subprocess.TimeoutExpired) as e:
        print(f"app-bump-dry-run: read failed: {e!r}", file=sys.stderr)
        return 1
    print(json.dumps(results, indent=2) if a.json else "".join(map(text, results)), end="\n" if a.json else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
