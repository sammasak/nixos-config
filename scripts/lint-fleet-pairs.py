#!/usr/bin/env python3
"""No tracked file, docs included, names a fleet listener or ntfy by its LAN address:port instead of its inside name
(<name>.<zone>:<port>). The literals are read from modules/core/fleet.nix's text, without evaluating it, so the
docs-only push runs this too; scripts/test-fleet-contract.py holds the parse to the evaluated sam.fleet.
Exit 0 when nothing names one, 1 when a file does (path:line printed) or the seeded case is missed, 2 when fleet.nix
cannot be read: unknown is never a pass. With FILE arguments it scans those files only, skipping the seeded case.
Standard library only, no Nix: it runs in the lints lane (devenv.nix `lints`)."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FLEET = "modules/core/fleet.nix"
# path prefix -> why a literal there stays
PAIR_ALLOWED = {
    "docs/records/": "dated records of what was run, as it was run",
    "modules/homelab/monitoring/rules/tests/": "Prometheus series labels: a scrape's instance is its address",
    "lib/app-manifest/golden/": "the rendered scrape config the manifest library is held to",
    "pkgs/platform-record/platform_record.py": "a record must ship with DNS down; its default is held to sam.fleet.loki.url",
    "pkgs/scorecard/scorecard.py": "its defaults are held to sam.fleet's urls; scorecard reads with DNS down too",
}
LITERAL = re.compile(r"(?<![0-9.])([0-9]{1,3}(?:[.][0-9]{1,3}){3}:[0-9]+)(?![0-9])")
# the predicates `scraped` is called with, as they read in fleet.nix
SCRAPED_ONLY = {"_: true": lambda h: True, "h: h.gpu or null != null": lambda h: h["gpu"]}


class Unreadable(Exception):
    pass


def need(m: re.Match[str] | None, what: str) -> re.Match[str]:
    if not m:
        raise Unreadable(f"{FLEET}: {what}")
    return m


def endpoint(body: str, strings: dict[str, str], what: str) -> tuple[str, int]:
    """(host, port) of an attrset body: `host = "x";` or `host = <let string>;`, `port = N;`, or `inherit (ntfy) host port;`."""
    if re.search(r"^\s*inherit \(ntfy\) host port;$", body, re.M):
        return endpoint(strings["ntfy-body"], strings, what)
    host = need(re.search(r'^\s*host = ("([^"]+)"|(\w+));$', body, re.M), f"{what} has no `host = ...;`")
    port = need(re.search(r"^\s*port = ([0-9]+);$", body, re.M), f"{what} has no `port = N;`")
    name = host[2] or strings.get(host[3])
    if name is None:
        raise Unreadable(f"{FLEET}: {what}'s host {host[3]} is no let-bound string")
    return name, int(port[1])


def pairs(root: pathlib.Path = ROOT) -> list[dict[str, str]]:
    """Every listener's and ntfy's {literal: address:port, name: <name>.<zone>:<port>}, sorted, as gate-probe.nix's
    fleet-contract `pairs` evaluates them."""
    text = (root / FLEET).read_text()
    lets = dict(re.findall(r"^  ([A-Za-z]\w*) = \{\n(.*?)\n  \};$", text, re.M | re.S))
    strings = dict(re.findall(r'^  ([A-Za-z]\w*) = "([^"]*)";$', text, re.M))
    strings["ntfy-body"] = need(re.search(r"^  ntfy = \{\n(.*?)\n  \};$", text, re.M | re.S), "no let-bound `ntfy`")[1]
    zone = need(re.search(r'^    zone = "([^"]+)";$', text, re.M), "no `zone = \"...\";`")[1]
    table = need(re.search(r"^  hosts = \{\n(.*?)\n  \};$", text, re.M | re.S), "no `  hosts = {` table")[1]
    hosts = {}
    for name, body in re.findall(r"^    ([A-Za-z0-9-]+) = \{\n(.*?)\n    \};$", table, re.M | re.S):
        address = need(re.search(r'^      address = "([^"]+)";$', body, re.M), f"host {name} has no address")[1]
        hosts[name] = {"address": address, "gpu": re.search(r"^      gpu = (?!null;)", body, re.M) is not None}
    for name, address in re.findall(r'^    ([A-Za-z0-9-]+)\.address = "([^"]+)";$', table, re.M):
        hosts[name] = {"address": address, "gpu": False}
    keys = set(re.findall(r"^    ([^ #}\n][^ .=\n]*)", table, re.M))
    if not hosts or keys != set(hosts):
        raise Unreadable(f"{FLEET}: the hosts table has entries this parse does not read ({sorted(keys)} vs {sorted(hosts)})")
    caches = need(re.search(r"^  storeCaches = \[\n(.*?)\n  \];$", text, re.M | re.S), "no `storeCaches = [` list")[1]
    block = need(re.search(r"^    listeners = \{\n(.*?)\n    \}\n(.*?)\n    \);\n    public = ", text, re.M | re.S),
                 "no `    listeners = { ... } // ... );` block before `public`")
    body, tail = block[1], block[2]

    found: dict[str, tuple[str, int]] = {}
    entries = re.findall(r"^      ([A-Za-z0-9-]+) = \{\n(.*?)\n      \};$", body, re.M | re.S)
    for name, b in entries:
        found[name] = endpoint(b, strings, f"listener {name}")
    aliases = re.findall(r"^      ([A-Za-z0-9-]+) = ([A-Za-z]\w*);$", body, re.M)
    inherits = [n for line in re.findall(r"^      inherit ([\w ]+);$", body, re.M) for n in line.split()]
    for name, let in aliases + [(n, n) for n in inherits]:
        if let not in lets:
            raise Unreadable(f"{FLEET}: listener {name} is {let}, no let-bound attrset")
        found[name] = endpoint(lets[let], strings, f"listener {name} ({let})")
    top = [l for l in body.splitlines() if re.match(r"      [^ #}]", l)]
    if len(top) != len(entries) + len(aliases) + len(re.findall(r"^      inherit ([\w ]+);$", body, re.M)):
        raise Unreadable(f"{FLEET}: a listener line this parse does not know: {top}")

    scraped = re.findall(r'^    // scraped "([\w-]+)" ([0-9]+) \((.*)\)$', tail, re.M)
    for prefix, port, only in scraped:
        if only not in SCRAPED_ONLY:
            raise Unreadable(f"{FLEET}: scraped {prefix}'s predicate ({only}) is not one this parse knows")
        for h, facts in hosts.items():
            if SCRAPED_ONLY[only](facts):
                found[f"{prefix}-{h}"] = (h, int(port))
    cache = need(re.search(r'"([\w-]+)-\$\{h\}" \{\s*host = h;\s*port = ([0-9]+);', tail),
                 'no `"<name>-${h}" { host = h; port = N; ...}` map over storeCaches')
    if not re.search(r"\) storeCaches$", tail, re.M):
        raise Unreadable(f"{FLEET}: the listToAttrs map is not over storeCaches")
    for h in re.findall(r'"([^"]+)"', caches):
        found[f"{cache[1]}-{h}"] = (h, int(cache[2]))
    if tail.count("//") != len(scraped) + 1:
        raise Unreadable(f"{FLEET}: a `//` after the listeners this parse does not know")

    found["ntfy"] = endpoint(strings["ntfy-body"], strings, "ntfy")
    out = []
    for name, (host, port) in found.items():
        if host not in hosts:
            raise Unreadable(f"{FLEET}: {name}'s host {host} is not in the hosts table")
        out.append({"literal": f"{hosts[host]['address']}:{port}", "name": f"{name.lower()}.{zone}:{port}"})
    return sorted(out, key=lambda p: (p["literal"], p["name"]))


def pair_literals(files: list[tuple[str, str]], table: dict[str, str]) -> list[tuple[str, int, str, str]]:
    """files: [(path, text)] -> [(path, line number, literal, its inside name)]"""
    found = []
    for path, text in files:
        if path == "flake.lock" or path.startswith(tuple(PAIR_ALLOWED)):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for m in LITERAL.finditer(line):
                if m[1] in table:
                    found.append((path, n, m[1], table[m[1]]))
    return found


def main(args: list[str]) -> int:
    try:
        table = {p["literal"]: p["name"] for p in pairs()}
    except (Unreadable, OSError) as e:
        print(f"lint-fleet-pairs: {e}", file=sys.stderr)
        return 2
    if len(table) < 10 or not all(".fleet." in n for n in table.values()):
        print(f"lint-fleet-pairs: only {len(table)} listeners read from {FLEET}: {table}", file=sys.stderr)
        return 2
    try:
        if args:
            files = [(p, pathlib.Path(p).read_text(errors="ignore")) for p in args]
        else:
            tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True, stdout=subprocess.PIPE,
                                     text=True).stdout.split("\0")
            files = [(p, (ROOT / p).read_text(errors="ignore")) for p in tracked if p and (ROOT / p).is_file()]
            if len(files) < 100 or FLEET not in dict(files):
                raise Unreadable(f"the tracked tree was not read ({len(files)} files)")
    except (Unreadable, OSError, subprocess.CalledProcessError) as e:
        print(f"lint-fleet-pairs: {e}", file=sys.stderr)
        return 2
    rc = 0
    for path, n, lit, name in pair_literals(files, table):
        print(f"{path}:{n}: names {lit}, use its inside name {name}", file=sys.stderr)
        rc = 1
    if not args:
        lit = next(iter(table))
        seeded = pair_literals([("docs/x.md", f"curl http://{lit}/ready"), ("docs/records/x.md", f"ran http://{lit}/")],
                               table)
        if [(p, l) for p, _, l, _ in seeded] != [("docs/x.md", lit)]:
            print(f"lint-fleet-pairs: seeded: a runbook naming {lit} is not found, or a dated record is ({seeded})",
                  file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
