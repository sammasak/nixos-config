#!/usr/bin/env python3
"""App manifest admission (lib/app-manifest): each fixture there is one registry, evaluated lib-only against the
fleet's facts. A valid one is admitted, and its rendered Caddyfile and Prometheus config equal its golden files byte for
byte; with --caddy, --promtool and --edge-snippets (the edge's own snippet definitions, which a site imports) both are
validated too. An invalid one is refused, and its error message names the field at fault.
The flake check app-manifest runs this with the facts its host evaluations give and `--store dummy://`; run alone it
reads lib/app-manifest/fixtures/host-facts.json, a hand-kept stub of those facts, and <nixpkgs/lib>."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = ROOT / "lib/app-manifest"
FIXTURES = HERE / "fixtures"
GOLDEN = HERE / "golden"
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
    "public-not-granted": ['apps.notes.ingress.notes-public.auth: public, but grants.notes.public is false.'],
    "auth-no-provider": ['apps.notes.ingress.notes.auth: authentik, but the edge defines no (authentik) forward_auth snippet to import (modules/homelab/edge.nix).'],
    "unknown-auth": "option `apps.notes.ingress.notes.auth' is not of type",
    "metrics-path-relative": "option `apps.notes.runtime.service.metricsPath' is not of type",
    "caddy-injection": "option `apps.notes.runtime.service.metricsPath' is not of type",
    "metrics-off-edge": ["apps.notes.runtime.service.metricsPath: msi-ms7758 is not the edge (acer-swift); black-pi scrapes an app's loopback metrics through the edge's metrics site."],
}
# the host facts a case overrides
FACTS = {"auth-no-provider": {"forwardAuth": []}}
# fixture parts no case evaluates on its own
PARTS = {"notes.nix", "host-facts.json"}

parser = argparse.ArgumentParser()
parser.add_argument("--lib", default="<nixpkgs/lib>", help="nixpkgs' lib directory, as a Nix path expression")
parser.add_argument("--host-facts", default=str(FIXTURES / "host-facts.json"))
parser.add_argument("--store", help="the Nix store to evaluate against, e.g. dummy:// in a build sandbox")
parser.add_argument("--caddy", help="caddy binary: `caddy validate` each rendered Caddyfile")
parser.add_argument("--promtool", help="promtool binary: `promtool check config` each rendered Prometheus config")
parser.add_argument("--edge-snippets", help="the edge's snippet definitions (its services.caddy.extraConfig)")
parser.add_argument("only", nargs="*", help="fixtures to run (default: every case)")
args = parser.parse_args()
validate = args.caddy and args.promtool and args.edge_snippets
scratch = pathlib.Path(tempfile.mkdtemp())

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL (scripts/test-app-manifest.py): ") + what)
    failed += not ok


files = {p.name for p in FIXTURES.iterdir()} - PARTS
check(files == {f"{name}.nix" for name in CASES}, f"every fixture has a case and every case a fixture ({sorted(files)})")
golden = {p.name for p in GOLDEN.iterdir()}
want_golden = {f"{n}{s}" for n, w in CASES.items() if w is None for s in (".Caddyfile", ".prometheus.json")}
check(golden == want_golden, f"every valid fixture has its golden files and no other is there ({sorted(golden)})")


def facts_for(name):
    if name not in FACTS:
        return args.host_facts
    path = scratch / f"{name}.facts.json"
    path.write_text(json.dumps(json.loads(pathlib.Path(args.host_facts).read_text()) | FACTS[name]))
    return str(path)


def rendered(name, argv):
    run = subprocess.run(argv + ["--argstr", "what", "render"], capture_output=True, text=True)
    if run.returncode != 0:
        check(False, f"{name}: rendered, but: {' '.join(run.stderr.rsplit('error:', 1)[-1].split())}")
        return
    out = json.loads(run.stdout)
    texts = {".Caddyfile": out["caddyfile"], ".prometheus.json": json.dumps(out["prometheus"], indent=2, sort_keys=True) + "\n"}
    for suffix, text in texts.items():
        path = GOLDEN / f"{name}{suffix}"
        check(path.exists() and path.read_text() == text, f"{name}: rendered {suffix} equals {path.relative_to(ROOT)}")
    if not validate:
        print(f"UNCHECKED: {name}: caddy validate and promtool check config need --caddy, --promtool and --edge-snippets")
        return
    site = scratch / f"{name}.Caddyfile"
    site.write_text(pathlib.Path(args.edge_snippets).read_text() + texts[".Caddyfile"])
    env = dict(os.environ, HOME=str(scratch), XDG_DATA_HOME=str(scratch / "data"), XDG_CONFIG_HOME=str(scratch / "config"))
    run = subprocess.run([args.caddy, "validate", "--adapter", "caddyfile", "--config", str(site)], capture_output=True, text=True, env=env)
    check(run.returncode == 0, f"{name}: caddy validate, with the edge's snippets" + ("" if run.returncode == 0 else f": {run.stderr.strip().splitlines()[-1:]}"))
    prom = scratch / f"{name}.prometheus.yml"
    prom.write_text(texts[".prometheus.json"])
    run = subprocess.run([args.promtool, "check", "config", str(prom)], capture_output=True, text=True)
    check(run.returncode == 0, f"{name}: promtool check config" + ("" if run.returncode == 0 else f": {(run.stdout + run.stderr).strip()}"))

for name in args.only or CASES:
    want = CASES[name]
    argv = ["nix-instantiate", "--eval", "--strict", "--json", str(HERE / "eval.nix"),
            "--arg", "nixpkgsLib", args.lib, "--arg", "hostFacts", facts_for(name),
            "--arg", "registry", str(FIXTURES / f"{name}.nix")]
    if args.store:
        argv[1:1] = ["--store", args.store]
    run = subprocess.run(argv, capture_output=True, text=True)
    # the trace above the last `error:` quotes the fixture's source, which spells the field too
    message = " ".join(run.stderr.rsplit("error:", 1)[-1].split())
    if want is None:
        check(run.returncode == 0, f"{name}: admitted{'' if run.returncode == 0 else ', but refused: ' + message}")
        rendered(name, argv)
        continue
    listed = subprocess.run(argv + ["--argstr", "what", "refusals"], capture_output=True, text=True)
    refused = json.loads(listed.stdout) if listed.returncode == 0 else None
    if isinstance(want, list):
        check(run.returncode != 0 and refused == want, f"{name}: refused by exactly {want!r}" + ("" if refused == want else f"; got: {refused if refused is not None else message}"))
    else:
        check(run.returncode != 0 and refused is None and want in message,
              f"{name}: a type error naming the field ({want!r})" + ("" if refused is None and want in message else f"; got: {refused if refused is not None else message}"))

sys.exit(1 if failed else 0)
