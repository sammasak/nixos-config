#!/usr/bin/env python3
"""#295's reusability check: a seventh host seeded from fixture data alone, into a temporary copy of the tracked tree.
The seed is one flake-modules/hosts.nix entry, one modules/core/fleet.nix hosts entry and hosts/seventh copied from
scripts/fixtures/seventh-host (base role, no secrets, so no .sops.yaml recipient). Each host is its own nix eval
(scripts/seventh-host-probe.nix) of the seeded copy, and for the real hosts of an unseeded copy of the same files.

Proved: the seed's toplevel drvPath evaluates; it is in every list derived from the fleet (deploy nodes, black-pi's
node-exporter targets and dashboards, lenovo's AdGuard rewrites, Loki's and each store cache's firewall callers, the
edge's OTLP sources, its own node-exporter listener, deferred-checks.py's parse of fleet.nix) and in none that does not
apply to it (store caches and their substituters, the nvidia-gpu targets); the real hosts that moved are exactly those
rendering a derived list that names it. Seeded: a copy whose prometheus, AdGuard, deploy, Loki, store-cache and edge
lists each leave the seed out fails each of those checks.

#295's criterion is not met while COUPLINGS or HAND_KEPT is non-empty: each is a place besides the seed's own three
that a seventh host still needs edited. A new one, or one that went away, fails the test, so both stay exact."""
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEED, ADDR = "seventh", "192.168.10.77"
ENTRY = f'    {SEED} = {{ roles = [ "base" ]; deploy.remoteBuild = true; }};\n'
FLEET = f'    {SEED}.address = "{ADDR}";\n'

# a failing assertion's text -> where it is, and what would remove the coupling
COUPLINGS = {
    "modules/core/ssh-known-hosts.nix pins": (
        "modules/core/ssh-known-hosts.nix: every host and guest asserts its pinned keys are exactly hosts.nix's deploy "
        "nodes, so the host's key must be added there; reading each key from its hosts/<dir> would end it"),
}
# host lists kept by hand and held to the fleet by the gate (nixos:known-hosts-test, nixos:readability-test):
# place -> (file, the block holding the list or None for the whole file, the pattern of one entry)
HAND_KEPT = {
    "test-ssh-known-hosts.py EXPECTED": ("scripts/test-ssh-known-hosts.py", r"\nEXPECTED = \{\n.*?\n\}", r'^    "([a-zA-Z0-9-]+)": '),
    "test-ssh-known-hosts.py SOPS_RECIPIENTS": ("scripts/test-ssh-known-hosts.py", r"\nSOPS_RECIPIENTS = \{\n.*?\n\}",
                                                r'^    "([a-zA-Z0-9-]+)": '),
    "README.md host table": ("README.md", None, r"^\| `([A-Za-z0-9-]+)`(?: \(`([a-z0-9-]+)`\))? \|"),
    "docs/architecture.md host table": ("docs/architecture.md", r"\n\| Host \| Mode \|.*?\n\n", r"^\| `([A-Za-z0-9-]+)` \|"),
    "CLAUDE.md deploy block": ("CLAUDE.md", r"\njust deploy HOST.*?\njust checks HOST", r"^#   ([A-Za-z0-9-]+) {2,}\S"),
    "CLAUDE.md Current hostnames": ("CLAUDE.md", r"\nCurrent hostnames:.*?\n\n", r"`([A-Za-z0-9-]+)`"),
}
# the fleet size the docs state (scripts/test-readability.py holds it to hosts.nix)
SIX = re.compile(r"(?<![\w-])(six|6)[- ]hosts?\b", re.IGNORECASE)
RULE = re.compile(r"^iptables -w -A nixos-fw -s (\S+) -p (tcp|udp) --dport ([0-9]+) -j nixos-fw-accept$")
# each derived list hard-coded without the seed, as a source edit (file, from, to)
BREAKS = [
    ("modules/homelab/monitoring/prometheus.nix", "          }) hosts;\n", f'          }}) (removeAttrs hosts [ "{SEED}" ]);\n'),
    ("modules/homelab/adguardhome.nix", "            }) fleet;\n", f'            }}) (removeAttrs fleet [ "{SEED}" ]);\n'),
    ("flake-modules/deploy.nix", "lib.mapAttrs mkNode config.configurations.nixos;",
     f'lib.mapAttrs mkNode (removeAttrs config.configurations.nixos [ "{SEED}" ]);'),
    ("modules/core/fleet.nix", "from = lib.remove loki.host (lib.attrNames hosts);",
     f'from = lib.remove "{SEED}" (lib.remove loki.host (lib.attrNames hosts));'),
    ("modules/core/fleet.nix", "from = lib.remove h (lib.attrNames hosts);",
     f'from = lib.remove "{SEED}" (lib.remove h (lib.attrNames hosts));'),
    ("modules/homelab/edge.nix", "otlpSources = map (h: h.address) (lib.attrValues hosts);",
     f'otlpSources = map (h: h.address) (lib.attrValues (removeAttrs hosts [ "{SEED}" ]));'),
]


def edit(path, old, new):
    text = path.read_text()
    check(text.count(old) == 1, f"{path.name}: the anchor {old.strip()!r} occurs once (if the file moved on, move it here)")
    path.write_text(text.replace(old, new, 1))


def probe(tree, host, baseline=None, full=False):
    args = f'tree = "path:{tree}"; host = "{host}"; seed = "{SEED}"; full = {"true" if full else "false"};'
    if baseline:
        args += f' baseline = "path:{baseline}";'
    t = time.monotonic()
    r = subprocess.run(["nix", "eval", "--impure", "--json", "--expr",
                        f"import {ROOT}/scripts/seventh-host-probe.nix {{ {args} }}"], capture_output=True, text=True)
    print(f"seventh-host: {host} in the {tree.name} copy evaluated in {time.monotonic() - t:.0f} s", flush=True)
    if r.returncode != 0:
        sys.exit(f"FAIL (scripts/seventh-host-check.py): {host} in the {tree.name} copy did not evaluate:\n{r.stderr[-1500:]}")
    return json.loads(r.stdout)


def admitted(firewall, addresses):
    """The ports a host's rendered iptables rules admit from any of `addresses`."""
    lines = [c.strip().replace("'", "").replace('"', "") for l in firewall["extraCommands"].replace("\\\n", " ").splitlines()
             for c in re.split(r";|&&|\|\|", l)]
    return sorted({int(m[3]) for m in map(RULE.match, lines) if m and m[1] in addresses})


def scraped(p, job):
    return {t["instance"]: t["target"] for j in p["scrape"] if j["job"] == job for t in j["targets"]}


def names_seed(p):
    """The derived lists a host renders that name the seed."""
    found = []
    if admitted(p["firewall"], [ADDR]):
        found.append(f"firewall admits it on {admitted(p['firewall'], [ADDR])}")
    if SEED in scraped(p, "node-exporter"):
        found.append("node-exporter targets")
    if {"domain": SEED, "answer": ADDR} in p["rewrites"]:
        found.append("AdGuard rewrites")
    if any(ADDR in l.split() for l in p["otlpSources"]):
        found.append("edge OTLP sources")
    if p["dashboardsName"]:
        found.append("dashboards")
    return found


def derived(P):
    """Each derived list's verdict on the seed, from the per-host probes: name -> (ok, what was seen)."""
    s, pi, lenovo, acer = P[SEED], P["black-pi"], P["lenovo"], P["acer-swift"]
    node = s["deployNodes"].get(SEED)
    caches = sorted(h for h, p in P.items() if p["storeCache"])
    pi_addresses = s["fleet"]["hosts"]["black-pi"]
    return {
        "deploy node": (node == {"hostname": SEED, "remoteBuild": True}, node),
        "node-exporter target (black-pi)": (scraped(pi, "node-exporter").get(SEED) == f"{ADDR}:9100",
                                            scraped(pi, "node-exporter").get(SEED)),
        # not vacuous: the job is read and lists the GPU hosts, just not the seed
        "no nvidia-gpu target (no gpu)": (scraped(pi, "nvidia-gpu") != {} and SEED not in scraped(pi, "nvidia-gpu"),
                                          sorted(scraped(pi, "nvidia-gpu"))),
        "AdGuard rewrite (lenovo)": ({"domain": SEED, "answer": ADDR} in lenovo["rewrites"],
                                     [r for r in lenovo["rewrites"] if r["domain"] == SEED]),
        "Loki caller (sam.fleet.loki.from, black-pi's firewall)": (
            SEED in s["fleet"]["lokiFrom"] and s["fleet"]["lokiPort"] in admitted(pi["firewall"], [ADDR]),
            admitted(pi["firewall"], [ADDR])),
        "store-cache caller (each cache's firewall)": (
            len(caches) >= 4 and all(5000 in admitted(P[h]["firewall"], [ADDR]) for h in caches),
            {h: admitted(P[h]["firewall"], [ADDR]) for h in caches}),
        "not a store cache, nor any cache's substituter": (
            not s["storeCache"] and not any(ADDR in u for p in P.values() for u in p["substituters"]),
            [h for h, p in P.items() if any(ADDR in u for u in p["substituters"])]),
        "edge OTLP source (acer)": (any(ADDR in l.split() for l in acer["otlpSources"]), acer["otlpSources"]),
        "dashboards' host variables (black-pi)": (pi["dashboardsName"] is True, pi["dashboardsName"]),
        "its node-exporter listener admits black-pi": (9100 in admitted(s["firewall"], pi_addresses),
                                                       admitted(s["firewall"], pi_addresses)),
    }


def listed(root, place):
    """The names a HAND_KEPT place lists in `root`; None when its block is gone."""
    path, block, item = HAND_KEPT[place]
    text = (root / path).read_text()
    scope = re.search(block, text, re.S) if block else None
    if block and not scope:
        return None
    names = set()
    for m in re.finditer(item, scope.group(0) if scope else text, re.M):
        names |= {n for g in m.groups() if g for n in g.split("|")}
    return names


def couplings(failing):
    """The failing assertions as (the COUPLINGS keys they match, the messages that match none)."""
    known, unknown = set(), []
    for m in failing:
        k = next((k for k in COUPLINGS if k in m), None)
        if k:
            known.add(k)
        else:
            unknown.append(m)
    return known, unknown


with tempfile.TemporaryDirectory() as tmp:
    base, seeded, broken = (pathlib.Path(tmp) / n for n in ("baseline", "seeded", "broken"))
    tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True, stdout=subprocess.PIPE, text=True).stdout.split()
    for p in tracked:
        if (ROOT / p).is_file():
            (base / p).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / p, base / p)
    shutil.copytree(base, seeded, symlinks=True)
    edit(seeded / "flake-modules/hosts.nix", "  configurations.nixos = {\n", "  configurations.nixos = {\n" + ENTRY)
    edit(seeded / "modules/core/fleet.nix", "\n  hosts = {\n", "\n  hosts = {\n" + FLEET)
    shutil.copytree(ROOT / "scripts/fixtures/seventh-host", seeded / "hosts" / SEED)
    shutil.copytree(seeded, broken, symlinks=True)
    for path, old, new in BREAKS:
        edit(broken / path, old, new)

    real = sorted(set(re.findall(r"^    ([a-z0-9-]+) = \{", (base / "flake-modules/hosts.nix").read_text(), re.M)))
    check(len(real) >= 6 and SEED not in real, f"the real hosts are read from hosts.nix ({real})")
    P = {h: probe(seeded, h, baseline=base, full=True) for h in real}
    P[SEED] = probe(seeded, SEED, full=True)
    B = {h: probe(broken, h) for h in ["black-pi", "lenovo", "acer-swift", SEED]}

    spec = importlib.util.spec_from_file_location("deferred_checks", ROOT / "scripts" / "deferred-checks.py")
    deferred_checks = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(deferred_checks)
    parsed = deferred_checks.fleet_hosts(seeded)
    names = {h: {h, P[h]["hostName"]} for h in real}
    hand = {place: listed(seeded, place) for place in HAND_KEPT}
    docs = [str(p.relative_to(seeded)) for p in [seeded / "README.md", seeded / "CLAUDE.md", seeded / "flake.nix",
                                                 *sorted((seeded / "docs").glob("*.md"))] if SIX.search(p.read_text())]

# 1. the seed evaluates through hosts.nix and the role registry
s = P[SEED]
check(s["hostName"] == SEED and re.fullmatch(rf"/nix/store/[a-z0-9]{{32}}-nixos-system-{SEED}-.*\.drv", s["drv"] or "") is not None,
      f"the seed's toplevel drvPath evaluates ({s['drv']})")
for h, p in P.items():
    known, unknown = couplings(p["failing"] + p["guestsFailing"])
    check(unknown == [], f"{h} fails no assertion besides the known couplings ({unknown})")
    check(known == set(COUPLINGS), f"{h} still fails each known coupling (gone: {sorted(set(COUPLINGS) - known)}: drop it)")
check(couplings(["modules/core/ssh-known-hosts.nix pins a b, not ...", "x.nix: something new"])
      == ({"modules/core/ssh-known-hosts.nix pins"}, ["x.nix: something new"]),
      "seeded: an assertion outside COUPLINGS is reported as unknown")

# 2. it is in every derived list that applies to it, and in none that does not
check(all(p["firewall"]["backend"] == "iptables" for p in P.values()), "every host renders iptables rules, the ones read here")
for name, (ok, seen) in derived(P).items():
    check(ok, f"derived: {name} ({seen})")
check(SEED in parsed, f"derived: deferred-checks.py's text parse of fleet.nix names the seed ({sorted(parsed)})")

# 3. the real hosts that moved are exactly those rendering a derived list that names the seed
moved = {h for h in real if P[h]["drv"] != P[h]["baselineDrv"]}
unexplained = lambda P: sorted(h for h in moved if not names_seed(P[h]))
unmoved = lambda P: sorted(h for h in real if names_seed(P[h]) and h not in moved)
check(all(P[h]["drv"] and P[h]["baselineDrv"] for h in real), "every real host's toplevel evaluates in both copies")
check(unexplained(P) == [] and unmoved(P) == [],
      f"the hosts that moved ({sorted(moved)}) are those whose derived lists name the seed "
      f"({ {h: names_seed(P[h]) for h in real if names_seed(P[h])} }; moved unexplained {unexplained(P)}, named "
      f"but unmoved {unmoved(P)})")
check("naked-pi" not in moved, "naked-pi, with no fleet entry, reads no fleet list and does not move")
blank = dict(P, **{"black-pi": dict(P["black-pi"], firewall={"extraCommands": "", "backend": "iptables"}, scrape=[],
                                    dashboardsName=None)})
check("black-pi" not in moved or unexplained(blank) == ["black-pi"],
      "seeded: black-pi moving with no derived list naming the seed fails the mover check")
# black-pi's explanation must include its scrape list itself, not only the firewall and dashboards beside it
pi_names = lambda P: "node-exporter targets" in names_seed(P["black-pi"])
check(pi_names(P), f"black-pi's move is explained by its node-exporter targets too ({names_seed(P['black-pi'])})")
check(not pi_names(dict(P, **{"black-pi": dict(P["black-pi"], scrape=[])})),
      "seeded: black-pi without its scrape list no longer names the seed in its node-exporter targets")
gpu_seeded = dict(P, **{"black-pi": dict(P["black-pi"], scrape=P["black-pi"]["scrape"] + [
    {"job": "nvidia-gpu", "targets": [{"target": f"{ADDR}:9835", "instance": SEED}]}])})
check(not derived(gpu_seeded)["no nvidia-gpu target (no gpu)"][0],
      "seeded: the seed added to the nvidia-gpu targets fails the no-gpu check")

# 4. each derived list hard-coded without the seed fails its check
broke = derived(dict(P, **B))
for name in ["deploy node", "node-exporter target (black-pi)", "AdGuard rewrite (lenovo)",
             "Loki caller (sam.fleet.loki.from, black-pi's firewall)", "store-cache caller (each cache's firewall)",
             "edge OTLP source (acer)"]:
    check(not broke[name][0], f"seeded: hard-coded without the seed, {name} fails ({broke[name][1]})")
# not vacuous: the broken copy's node-exporter job is read and lists the real hosts, only not the seed
broke_targets = scraped(dict(P, **B)["black-pi"], "node-exporter")
seeded_targets = scraped(P["black-pi"], "node-exporter")
check(broke_targets != {} and set(broke_targets) == set(seeded_targets) - {SEED},
      f"the hard-coded node-exporter list is read, with every fleet host but the seed ({sorted(broke_targets)})")

# what a seventh host still needs edited besides its own three places
for place, listing in hand.items():
    check(listing is not None and all(listing & n for n in names.values()),
          f"{place} still lists every real host by hand ({listing}; derived or moved? update HAND_KEPT)")
    check(listing is None or SEED not in listing, f"{place} lacks the seed: a seventh host must be added there by hand")
check(docs != [], f"the docs state the fleet size the seed outgrows ({docs})")
print(f"seventh-host: #295 reusability not met: besides hosts.nix, fleet.nix and hosts/{SEED}, a seventh host needs "
      f"{'; '.join(COUPLINGS.values())}; its name in {', '.join(HAND_KEPT)}; and the fleet size in {', '.join(docs)}")

finish()
