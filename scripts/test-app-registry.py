#!/usr/bin/env python3
"""The app registry (apps/registry.json through lib/app-manifest/pins.nix), evaluated lib-only without fetching any
source: the live registry type-checks; each case is that registry with one field bent and must fail evaluation with a
message naming the field (a bad rev, a missing or malformed narHash, an unallowlisted repo, no grant, an unknown field,
an unknown host), and an app no entry registers fails by name. A wrong narHash for a good rev is the fetcher's own
refusal, which needs the network, so it is not a case here. The flake check app-manifest runs this with `--store
dummy://`; run alone it reads <nixpkgs/lib>."""
import argparse
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PINS = ROOT / "lib/app-manifest/pins.nix"
LIVE = json.loads((ROOT / "apps/registry.json").read_text())
APP = "alert-bridge"
EXPR = """{ lib, registry, app }:
let p = import %s { lib = import lib; inherit registry; };
in if app == "" then builtins.attrNames p.checked
   else if builtins.substring 0 4 app == "pin:" then (p.pin (builtins.substring 4 (-1) app)).source.rev
   else p.src app""" % PINS


def bent(fn):
    r = copy.deepcopy(LIVE)
    fn(r)
    return r


def source(**kv):
    return lambda r: r["apps"][APP]["source"].update(kv)


def drop(*path):
    def fn(r):
        for k in path[:-1]:
            r = r[k]
        del r[path[-1]]

    return fn


# name -> (registry, app looked up, the text the error must hold)
CASES = {
    "bad-rev": (bent(source(rev="main")), "", f"`apps.{APP}.source.rev' is not of type"),
    "short-rev": (bent(source(rev="e2d61abf")), "", f"`apps.{APP}.source.rev' is not of type"),
    "missing-hash": (bent(drop("apps", APP, "source", "narHash")), "", f"`apps.{APP}.source.narHash' was accessed but has no value defined"),
    "base32-hash": (bent(source(narHash="sha256:1v4gsn2bvhx3cbbm2s0yk1fa82hzym5lsyvsrbp9mdbvlj22wqd4")), "", f"`apps.{APP}.source.narHash' is not of type"),
    "repo-not-allowlisted": (bent(source(repo="mallory/alert-bridge")), "", f"apps.{APP}.source.repo: mallory/alert-bridge is not the repository grants.{APP} allowlists (sammasak/alert-bridge)."),
    "no-grant": (bent(drop("grants", APP)), "", f"apps.{APP}: no grants.{APP}, so the platform has not admitted it."),
    "unknown-field": (bent(source(ref="refs/heads/dev")), "", f"The option `apps.{APP}.source.ref' does not exist"),
    "unknown-host": (bent(lambda r: r["grants"][APP].update(host="nohost")), "", f"`grants.{APP}.host' is not of type"),
    "unknown-app": (LIVE, "nope", f"no apps.nope; registered: {APP}"),
}

parser = argparse.ArgumentParser()
parser.add_argument("--lib", default="<nixpkgs/lib>", help="nixpkgs' lib directory, as a Nix path expression")
parser.add_argument("--store", help="the Nix store to evaluate against, e.g. dummy:// in a build sandbox")
args = parser.parse_args()
scratch = pathlib.Path(tempfile.mkdtemp())
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL (scripts/test-app-registry.py): ") + what)
    failed += not ok


def evaluate(name, registry, app):
    path = scratch / f"{name}.json"
    path.write_text(json.dumps(registry, indent=2))
    argv = ["nix-instantiate", "--eval", "--strict", "--json", "-E", EXPR,
            "--arg", "lib", args.lib, "--arg", "registry", str(path), "--argstr", "app", app]
    if args.store:
        argv[1:1] = ["--store", args.store]
    return subprocess.run(argv, capture_output=True, text=True)


run = evaluate("live", LIVE, "")
check(run.returncode == 0 and json.loads(run.stdout) == sorted(LIVE["apps"]),
      f"apps/registry.json type-checks and registers {sorted(LIVE['apps'])}" + ("" if run.returncode == 0 else f": {run.stderr.strip()[-400:]}"))
run = evaluate("live-pin", LIVE, f"pin:{APP}")
check(run.returncode == 0 and json.loads(run.stdout) == LIVE["apps"][APP]["source"]["rev"],
      f"pin {APP}: the checked entry's rev, with no fetch (a sandbox's nix has no fetch-tree)"
      + ("" if run.returncode == 0 else f": {run.stderr.strip()[-400:]}"))
for name, (registry, app, want) in CASES.items():
    run = evaluate(name, registry, app)
    message = " ".join(run.stderr.rsplit("error:", 1)[-1].split())
    check(run.returncode != 0 and want in " ".join(run.stderr.split()),
          f"{name}: evaluation fails naming {want!r}" + ("" if run.returncode != 0 else "; it evaluated") + ("" if want in " ".join(run.stderr.split()) else f"; got: {message}"))

sys.exit(1 if failed else 0)
