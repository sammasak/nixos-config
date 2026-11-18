#!/usr/bin/env python3
"""App manifest admission (lib/app-manifest): each fixture there is one registry, evaluated lib-only against the
fleet's facts. A valid one is admitted; an invalid one is refused, and its error message names the field at fault.
The flake check app-manifest runs this with the facts its host evaluations give and `--store dummy://`; run alone it
reads lib/app-manifest/fixtures/host-facts.json, a hand-kept stub of those facts, and <nixpkgs/lib>."""
import argparse
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = ROOT / "lib/app-manifest"
FIXTURES = HERE / "fixtures"
# fixture -> None (admitted), a list (exactly the admission rules it breaks, each message naming the field: no case
# passes on a second, unrelated refusal) or a string (a type error, which stops evaluation at the field it names)
CASES = {
    "valid-herman": None,
    "valid-service": None,
    "duplicate-hostname": [
        'apps.herman.ingress.herman-next: herman-next.sammasak.dev is also claimed by apps.notes.',
        'apps.notes.ingress.herman-next: herman-next.sammasak.dev is also claimed by apps.herman.',
    ],
    "edge-hostname": ['apps.notes.ingress.auth: auth.sammasak.dev is already served by the edge (modules/homelab/edge.nix).'],
    "unknown-secret": ['apps.notes.runtime.service.secrets."notes/api_key": no sops secret of that name is declared on acer-swift.'],
    "ungranted-secret": ['apps.notes.runtime.service.secrets."cloudflare/api_token": not in grants.notes.secrets.'],
    "forbidden-mount": 'The option `apps.notes.runtime.service.state\' has names ["../../etc/ssh"]',
    "oversized-resources": "option `apps.notes.runtime.service.resources.memoryMiB' is not of type",
    "memory-over-grant": ['apps.notes.runtime.service.resources.memoryMiB: 1024 is above grants.notes.memoryMiB (256).'],
    "port-clash": ['apps.notes.runtime.service.port: 8081/tcp on acer-swift is sam.fleet.listeners.gateway-api.'],
    "port-clash-apps": [
        "apps.notes.runtime.service.port: 8090/tcp on acer-swift is also apps.wiki's.",
        "apps.wiki.runtime.service.port: 8090/tcp on acer-swift is also apps.notes's.",
    ],
    "missing-owner": "The option `apps.notes.owner' was accessed but has no value defined",
    "owner-not-granted": ['apps.notes.owner: mallory is not the owner grants.notes approves (sammasak).'],
    "unpinned-rev": "option `apps.notes.source.rev' is not of type",
    "repo-not-allowlisted": ['apps.notes.source.repo: mallory/notes is not the repository grants.notes allowlists (sammasak/notes).'],
    "store-path-source": "The option `apps.notes.source.storePath' does not exist",
    "unknown-field": "The option `apps.notes.systemd' does not exist",
    "unknown-api-version": "option `apps.notes.apiVersion' is not of type",
    "no-grant": ['apps.notes: no grants.notes, so the platform has not admitted it.'],
}
# fixture parts no case evaluates on its own
PARTS = {"notes.nix", "host-facts.json"}

parser = argparse.ArgumentParser()
parser.add_argument("--lib", default="<nixpkgs/lib>", help="nixpkgs' lib directory, as a Nix path expression")
parser.add_argument("--host-facts", default=str(FIXTURES / "host-facts.json"))
parser.add_argument("--store", help="the Nix store to evaluate against, e.g. dummy:// in a build sandbox")
parser.add_argument("only", nargs="*", help="fixtures to run (default: every case)")
args = parser.parse_args()

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL (scripts/test-app-manifest.py): ") + what)
    failed += not ok


files = {p.name for p in FIXTURES.iterdir()} - PARTS
check(files == {f"{name}.nix" for name in CASES}, f"every fixture has a case and every case a fixture ({sorted(files)})")

for name in args.only or CASES:
    want = CASES[name]
    argv = ["nix-instantiate", "--eval", "--strict", "--json", str(HERE / "eval.nix"),
            "--arg", "nixpkgsLib", args.lib, "--arg", "hostFacts", args.host_facts,
            "--arg", "registry", str(FIXTURES / f"{name}.nix")]
    if args.store:
        argv[1:1] = ["--store", args.store]
    run = subprocess.run(argv, capture_output=True, text=True)
    # the trace above the last `error:` quotes the fixture's source, which spells the field too
    message = " ".join(run.stderr.rsplit("error:", 1)[-1].split())
    if want is None:
        check(run.returncode == 0, f"{name}: admitted{'' if run.returncode == 0 else ', but refused: ' + message}")
        continue
    listed = subprocess.run(argv + ["--argstr", "what", "refusals"], capture_output=True, text=True)
    refused = json.loads(listed.stdout) if listed.returncode == 0 else None
    if isinstance(want, list):
        check(run.returncode != 0 and refused == want, f"{name}: refused by exactly {want!r}" + ("" if refused == want else f"; got: {refused if refused is not None else message}"))
    else:
        check(run.returncode != 0 and refused is None and want in message,
              f"{name}: a type error naming the field ({want!r})" + ("" if refused is None and want in message else f"; got: {refused if refused is not None else message}"))

sys.exit(1 if failed else 0)
