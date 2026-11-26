#!/usr/bin/env python3
"""#295's reusability check: a seventh host seeded from fixture data alone, into a temporary copy of the tracked tree.
The seed is one flake-modules/hosts.nix entry, one modules/core/fleet.nix hosts entry and hosts/seventh copied from
scripts/fixtures/seventh-host (base role, no secrets, so no .sops.yaml recipient; its pinned key a throwaway one).
Each host is its own nix eval (scripts/seventh-host-probe.nix) of the seeded copy, and for the real hosts of an
unseeded copy of the same files. Inside nixos:qa that unseeded toplevel is the one its flake check evaluated from the
same files (NIXOS_QA_TOPLEVELS), not evaluated again; naked-pi's, the cheapest, still is, and must be the same drv.

Proved: the seed's toplevel drvPath evaluates; it is in every list derived from the fleet (deploy nodes, every host's
ssh known_hosts, black-pi's node-exporter targets and dashboards, lenovo's AdGuard rewrites, Loki's and each store
cache's firewall callers, the edge's OTLP sources, its own node-exporter listener, deferred-checks.py's parse of
fleet.nix) and in none that does not apply to it (store caches and their substituters, the nvidia-gpu targets); the
real hosts that moved are exactly those rendering a derived list that names it. Seeded: a copy whose prometheus,
AdGuard, deploy, Loki, store-cache, edge and known_hosts lists each leave the seed out fails each of those checks; the
seed without its hosts/seventh/ssh_known_hosts fails the build, naming that file.

#295's criterion is not met while COUPLINGS or HAND_KEPT is non-empty: each is a place besides the seed's own three
that a seventh host still needs edited. A new one, or one that went away, fails the test, so both stay exact.

Removing a host is #295's other half and is not seeded here: scripts/test-fleet-contract.py copies hosts.nix with
asus-b460m removed and shows lenovo's machines and jump-host assertions fail (its "removed from hosts.nix" seed)."""
import importlib.util
import json
import os
import pathlib
import re
import resource
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
LOOPBACK = ["localhost", "127.0.0.1", "::1"]
PIN = (ROOT / "scripts/fixtures/seventh-host/ssh_known_hosts").read_text().splitlines()[-1].split(" ", 1)[1]
UNPINNED = (f"modules/core/ssh-known-hosts.nix: no host key pinned at hosts/{SEED}/ssh_known_hosts: each must exist and "
            "hold one `<names> ssh-ed25519 <key>` line (docs/ssh-host-keys.md).")

# a failing assertion's text -> where it is, and what would remove the coupling
COUPLINGS: dict[str, str] = {}
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
    ("modules/homelab/adguardhome.nix", "            }) fleet\n", f'            }}) (removeAttrs fleet [ "{SEED}" ])\n'),
    ("flake-modules/deploy.nix", "lib.mapAttrs mkNode config.configurations.nixos;",
     f'lib.mapAttrs mkNode (removeAttrs config.configurations.nixos [ "{SEED}" ]);'),
    ("modules/core/fleet.nix", "from = lib.remove loki.host (lib.attrNames hosts);",
     f'from = lib.remove "{SEED}" (lib.remove loki.host (lib.attrNames hosts));'),
    ("modules/core/fleet.nix", "from = lib.remove h (lib.attrNames hosts);",
     f'from = lib.remove "{SEED}" (lib.remove h (lib.attrNames hosts));'),
    ("modules/homelab/edge.nix", "otlpSources = map (h: h.address) (lib.attrValues hosts);",
     f'otlpSources = map (h: h.address) (lib.attrValues (removeAttrs hosts [ "{SEED}" ]));'),
    ("modules/core/ssh-known-hosts.nix", "programs.ssh.knownHosts = hosts;",
     f'programs.ssh.knownHosts = removeAttrs hosts [ "{SEED}" ];'),
]


def edit(path, old, new):
    text = path.read_text()
    check(text.count(old) == 1, f"{path.name}: the anchor {old.strip()!r} occurs once (if the file moved on, move it here)")
    path.write_text(text.replace(old, new, 1))


def probe(tree, host, baseline=None, full=False, asserts=False):
    args = (f'tree = "path:{tree}"; host = "{host}"; seed = "{SEED}"; full = {"true" if full else "false"};'
            f' asserts = {"true" if full or asserts else "false"};')
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
    if p["knownHost"]:
        found.append("known_hosts pin")
    return found


def derived(P):
    """Each derived list's verdict on the seed, from the per-host probes: name -> (ok, what was seen)."""
    s, pi, lenovo, acer = P[SEED], P["black-pi"], P["lenovo"], P["acer-swift"]
    node = s["deployNodes"].get(SEED)
    caches = sorted(h for h, p in P.items() if p["storeCache"])
    pi_addresses = s["fleet"]["hosts"]["black-pi"]
    pins = {h: p["knownHost"] for h, p in P.items()}
    return {
        "deploy node": (node == {"hostname": SEED, "remoteBuild": True}, node),
        "known_hosts pin (every host, loopback on itself)": (
            all(k == {"hostNames": [SEED, ADDR] + (LOOPBACK if h == SEED else []), "publicKey": PIN} for h, k in pins.items()),
            pins),
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


def couplings(failing, known_couplings=COUPLINGS):
    """The failing assertions as (the COUPLINGS keys they match, the messages that match none)."""
    known, unknown = set(), []
    for m in failing:
        k = next((k for k in known_couplings if k in m), None)
        if k:
            known.add(k)
        else:
            unknown.append(m)
    return known, unknown


def toplevels(text):
    """NIXOS_QA_TOPLEVELS' "host drv" lines; a host named twice is a flake check fault, not a choice."""
    pairs = [l.split() for l in text.splitlines()]
    check(all(len(p) == 2 for p in pairs) and len({p[0] for p in pairs}) == len(pairs),
          f"NIXOS_QA_TOPLEVELS has one \"host drv\" line per host ({pairs})")
    return dict(pairs)


def same_baseline(reused, evaluated):
    """Reused baselines stand only while the one still evaluated here (naked-pi) is the flake check's too."""
    return not reused or reused.get("naked-pi") == evaluated


check(not same_baseline({"naked-pi": "/nix/store/a.drv"}, "/nix/store/b.drv")
      and not same_baseline({"lenovo": "/nix/store/a.drv"}, "/nix/store/b.drv")
      and same_baseline({}, "/nix/store/b.drv") and same_baseline({"naked-pi": "/nix/store/b.drv"}, "/nix/store/b.drv")
      and toplevels("") == {} and toplevels("a /x.drv\nb /y.drv\n") == {"a": "/x.drv", "b": "/y.drv"},
      "seeded: reused baselines fail unless naked-pi's is the evaluated one, or there are none")


with tempfile.TemporaryDirectory() as tmp:
    base, seeded, broken, unpinned = (pathlib.Path(tmp) / n for n in ("baseline", "seeded", "broken", "unpinned"))
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
    shutil.copytree(seeded, unpinned, symlinks=True)
    (unpinned / "hosts" / SEED / "ssh_known_hosts").unlink()

    real = sorted(set(re.findall(r"^    ([a-z0-9-]+) = \{", (base / "flake-modules/hosts.nix").read_text(), re.M)))
    check(len(real) >= 6 and SEED not in real, f"the real hosts are read from hosts.nix ({real})")
    # "host drv" lines of this gate's flake check, which evaluated the tree these copies are of (an edit between the
    # two steps fails the moved check below, never passes it)
    reused = toplevels(pathlib.Path(os.environ.get("NIXOS_QA_TOPLEVELS", os.devnull)).read_text())
    again = {"naked-pi"} | {h for h in real if h not in reused}
    print(f"seventh-host: unseeded toplevels from the flake check: {sorted(set(real) - again) or 'none'}; "
          f"evaluated here: {sorted(again)}", flush=True)
    P = {h: probe(seeded, h, baseline=base if h in again else None, full=True) for h in real}
    for h in set(real) - again:
        P[h]["baselineDrv"] = reused[h]
    check(same_baseline(reused, P["naked-pi"]["baselineDrv"]),
          f"the flake check's naked-pi toplevel is the unseeded copy's ({reused.get('naked-pi')}, {P['naked-pi']['baselineDrv']})")
    P[SEED] = probe(seeded, SEED, full=True)
    B = {h: probe(broken, h) for h in ["black-pi", "lenovo", "acer-swift", SEED]}
    U = probe(unpinned, SEED, asserts=True)

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
check(couplings(["a.nix pins a b, not ...", "x.nix: something new"], {"a.nix pins": "a.nix"})
      == ({"a.nix pins"}, ["x.nix: something new"]),
      "seeded: an assertion outside COUPLINGS is reported as unknown")
check(U["failing"] == [UNPINNED],
      f"seeded: the seed without its hosts/{SEED}/ssh_known_hosts fails, naming it ({U['failing']})")

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
check(names_seed(P["naked-pi"]) == ["known_hosts pin"],
      f"naked-pi, with no fleet entry, names the seed in its known_hosts only ({names_seed(P['naked-pi'])})")
blank = dict(P, **{"black-pi": dict(P["black-pi"], firewall={"extraCommands": "", "backend": "iptables"}, scrape=[],
                                    dashboardsName=None, knownHost=None)})
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
for name in ["deploy node", "known_hosts pin (every host, loopback on itself)", "node-exporter target (black-pi)",
             "AdGuard rewrite (lenovo)",
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
# a docs change that drops the count is right: the check then names what to update here instead of failing obscurely
check(docs != [], f"the docs state the fleet size the seed outgrows ({docs})" if docs else
      "no doc states the fleet size any more (README.md, CLAUDE.md, flake.nix, docs/*.md): that coupling is gone; "
      "update the test: drop this check and the fleet size from the report below (scripts/seventh-host-check.py)")
print(f"seventh-host: #295 reusability not met: besides hosts.nix, fleet.nix and hosts/{SEED}, a seventh host needs "
      f"{''.join(f'{c}; ' for c in COUPLINGS.values())}its name in {', '.join(HAND_KEPT)}; and the fleet size in {', '.join(docs)}")

# the largest single nix eval's resident peak (Linux: KiB), for the gate host's memory budget
print(f"seventh-host: peak child RSS {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss} KiB")
finish()
