#!/usr/bin/env python3
"""Wiring test for modules/core/ssh-known-hosts.nix (nixos-config#86): the pinned host keys are the verified ones
(fingerprints recorded here, in docs/ssh-host-keys.md and beside each key in hosts/<dir>/ssh_known_hosts), every name and address of each host is covered, a host
pins loopback to its own key only, every client fails closed, deploy-rs too, the old github pin is gone, and every
sops secret a host declares is in a file encrypted to that host's key and names a key that file has. The hand-kept
host lists (EXPECTED, SOPS_RECIPIENTS, the docs' host rows) name every deploy node; the Justfile's HOST recipes and the
verify script's default read the hosts table instead (scripts/hosts-table.sh), held here to the evaluated nodes."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAILED = False

# the verified inventory: SHA256 fingerprints as read out of band on 2026-11-04 (docs/ssh-host-keys.md)
EXPECTED = {
    "github": (["github.com"], "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"),
    "lenovo-21CB001PMX": (["lenovo-21CB001PMX", "192.168.10.154"], "SHA256:7DLYFLKZ4wrcrO0Bk7MnZ8yYHrVeu5pFsSwYWjvpNGs"),
    "acer-swift": (["acer-swift", "192.168.10.110"], "SHA256:5Ong1jvhk4Hgx82l2fYrKBjqlkVyG5rYvYfVPo7WdRY"),
    "msi-ms7758": (["msi-ms7758", "msi", "192.168.10.235"], "SHA256:JebDBAzSWRc/WHY8wQG7jVcidYFp4eFKyjuTzXl5Jwc"),
    "asus-b460m": (["asus-b460m", "192.168.10.113"], "SHA256:SsemYL0zG8kEdMlejNVgNsVsI+DF/PVHs3olZqR8S84"),
    "black-pi": (["black-pi", "192.168.10.137", "192.168.10.136"], "SHA256:i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY"),
    "naked-pi": (["naked-pi", "192.168.10.127", "192.168.10.138", "192.168.10.180"], "SHA256:auOEtU3d4yfB4U6iB7WIt0gSCLwK7hCDPorJAwVs0sY"),
}
# every fleet host decrypts its sops secrets with its ssh host key: the key's age form must be that host's recipient
SOPS_RECIPIENTS = {
    "lenovo-21CB001PMX": "age13lj7pyzzspnk8ck3rg5kgh63ekm7k9j5cyzl8awzr37hnr34r94qugqc4y",
    "acer-swift": "age1uu9y3sfr4htk4rrsw66df5gn2xt3t3mykm52ljxlctj37yuza5mqpxlyuk",
    "msi-ms7758": "age1g0k9vwsduy0sclensm38ksxgj5pkjds4r4su5dqufee6lxtl0gzsmvcx4r",
    "asus-b460m": "age1ye0ma9wl5nt33u73744jv7qsqtelw70tsxlm8wkgaelm7crpsf7sxh2ksl",
    "black-pi": "age16l5rqqh0xv9r6rcuyyz2s9ca5ex25azg9dp4z460zh2r3eqwd3ps9yx7tn",
    "naked-pi": "age1kdjqlt6s6fklcdjm2y9dggyvc9nmpcglsu3gduzudcl85ur8jdwqz26wer",
}
# files encrypted ahead of the module that will declare them: the host that will, and what lands it
AWAITING: dict[str, tuple[str, str]] = {}
LOOPBACK = ["localhost", "127.0.0.1", "::1"]


def check(condition, message):
    global FAILED
    if not condition:
        FAILED = True
        print(f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): {message}")
    else:
        print(f"PASS: {message}")


def ssh_to_age(public_key):
    out = subprocess.run(["ssh-to-age"], input=public_key + "\n", capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def fingerprint(public_key):
    out = subprocess.run(["ssh-keygen", "-lf", "-"], input=public_key + "\n", capture_output=True, text=True)
    return out.stdout.split()[1] if out.returncode == 0 else None


def sops_recipients(path):
    """The age recipients in an encrypted file's plaintext `sops:` metadata; no other line is kept or decrypted."""
    lines = path.read_text().splitlines() if path.is_file() else []
    meta = lines[lines.index("sops:"):] if "sops:" in lines else []
    return {m.group(1) for line in meta if (m := re.fullmatch(r"\s*(?:- )?recipient: (age1[0-9a-z]+)", line))}


def key_paths(path):
    """Every leaf key path (`a`, `a/b`) of a sops yaml file outside its `sops:` metadata, from the plaintext key names;
    no value is kept or decrypted. A mapping is no secret, so its own path is not a leaf. A file with a line outside
    `sops:` this does not read (a quoted key, a list, a `/` in a name: sops-nix splits keys on `/`) has no paths."""
    paths, stack = set(), []
    for line in path.read_text().splitlines() if path.is_file() else []:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"( *)([A-Za-z0-9_.-]+):(?: |$)", line)
        if m:
            indent = len(m.group(1))
            stack = [(i, n) for i, n in stack if i < indent] + [(indent, m.group(2))]
        elif not (stack and stack[0][1] == "sops" and line.startswith(" ")):
            return set()
        if stack[0][1] != "sops" and m:
            paths.add("/".join(n for _, n in stack))
    return {p for p in paths if not any(q.startswith(p + "/") for q in paths)}


def missing_keys(keys, files, paths_of):
    """The secrets a host declares whose key is not in their file. Only yaml is read; any other format is reported."""
    return sorted(f"{n} ({files[n]}: {k['format']} {k['key']})" for n, k in keys.items()
                  if k["format"] != "yaml" or k["key"] not in paths_of(files[n]))


def encrypted_files():
    """Every sops file in the repo, repo-relative: the ones no host declares are checked too."""
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / "secrets").rglob("*")
                  if p.is_file() and p.name != ".sops.yaml" and sops_recipients(p))


def undecryptable(files, host, recipients_of):
    """The secrets a host declares whose file does not list the host's recipient (an unknown host: all of them)."""
    want = SOPS_RECIPIENTS.get(host)
    return sorted(f"{name} ({f})" for name, f in files.items() if want is None or want not in recipients_of(f))


def host_key_identity(h):
    age, gpg = h["age"], h["gnupg"]
    return (age["sshKeyPaths"] == ["/etc/ssh/ssh_host_ed25519_key"] and gpg["home"] is None
            and (age["keyFile"] is None or age["generateKey"] is True))


def needless(f, hosts, recipients_of):
    """The fleet hosts whose key is a recipient of `f` but which declare none of its secrets."""
    return sorted(n for n, r in SOPS_RECIPIENTS.items() if r in recipients_of(f) and n not in hosts)


def sops_checks(S, nodes):
    """Every secret a host declares is encrypted to that host's key, read from the files' plaintext metadata:
    sops-nix's own build check confirms the key exists in the file, not that the host can decrypt it. The host's key is
    its ssh host key, so that is the identity sops-nix must decrypt with: no gnupg home (its default rsa host-key import
    is inert, the files carry age recipients only); age.keyFile, when set, is the generated extra identity
    (generateKey), whose public half no file lists."""
    cache, key_cache = {}, {}
    def recipients_of(f):
        return cache.setdefault(f, sops_recipients(ROOT / f))
    def paths_of(f):
        return key_cache.setdefault(f, key_paths(ROOT / f))
    check(set(S["hosts"]) == set(nodes), f"every deploy node is checked ({sorted(S['hosts'])})")
    for attr, h in S["hosts"].items():
        bad = undecryptable(h["files"], h["hostName"], recipients_of)
        check(h["files"] and not bad, f"{attr}: each of its {len(h['files'])} sops secrets is in a file encrypted to {h['hostName']} (not: {bad})")
        # sops-nix's validateSopsFiles checks this too, but only in the toplevel's build: on the Pis, at deploy
        bad = missing_keys(h["keys"], h["files"], paths_of)
        check(not bad, f"{attr}: each of its sops secrets names a key its file has (not: {bad})")
        check(host_key_identity(h), f"{attr}: sops-nix decrypts with the ssh host key the recipient is derived from ({h['age']}, gnupg {h['gnupg']})")
    # the converse: a host key on a file whose secrets that host never declares can decrypt them for nothing
    declared = {}
    for h in S["hosts"].values():
        for f in set(h["files"].values()):
            declared.setdefault(f, set()).add(h["hostName"])
    files = encrypted_files()
    check(len(files) >= 12, f"every encrypted file is read ({len(files)})")
    for f in files:
        extra = needless(f, declared.get(f, set()), recipients_of)
        if f in AWAITING:
            host, why = AWAITING[f]
            check(extra == [host], f"{f}: {host} is its only undeclared recipient until {why}; once it declares, drop the entry ({extra})")
            continue
        check(not extra, f"{f}: encrypted only to fleet hosts that declare one of its secrets (also: {extra})")
    added = lambda f: recipients_of(f) | {SOPS_RECIPIENTS["msi-ms7758"]}
    check(needless("secrets/homelab/tailscale.yaml", declared.get("secrets/homelab/tailscale.yaml", set()), added) == ["msi-ms7758"],
          "seeded: tailscale.yaml with msi's recipient added names msi, which declares none of its secrets")
    lenovo_too = lambda f: recipients_of(f) | {SOPS_RECIPIENTS["lenovo-21CB001PMX"]}
    check(needless("secrets/claude/llm-cloud.yaml", declared.get("secrets/claude/llm-cloud.yaml", set()), lenovo_too) == ["lenovo-21CB001PMX"],
          "seeded: a file no host declares (llm-cloud.yaml) fails any host recipient")
    bad = undecryptable(S["seeded"], "black-pi", recipients_of)
    check(bad == ["native_otlp_auth (secrets/claude/native-otlp-auth.yaml)"], f"seeded: black-pi with nativeOtel declares the relay's secret, not encrypted to it ({bad})")
    acer = S["hosts"]["acer-swift"]
    check(not host_key_identity(dict(acer, age=dict(acer["age"], generateKey=False))),
          "seeded: a provisioned age.keyFile (generateKey off) is not the host key identity")
    seed = "secrets/homelab/open-webui.yaml"
    dropped = lambda f: recipients_of(f) - {SOPS_RECIPIENTS["acer-swift"]} if f == seed else recipients_of(f)
    bad = undecryptable(acer["files"], "acer-swift", dropped)
    want = sorted(f"{n} ({f})" for n, f in acer["files"].items() if f == seed)
    check(want and bad == want, f"seeded: open-webui.yaml with acer's recipient dropped fails acer's open-webui keys ({bad})")
    typo = dict(acer["keys"], open_webui_secret_key={"key": "open_webui_secret_kye", "format": "yaml"})
    check(missing_keys(typo, acer["files"], paths_of) == ["open_webui_secret_key (secrets/homelab/open-webui.yaml: yaml open_webui_secret_kye)"],
          "seeded: a misspelt top-level key is reported")
    black = S["hosts"]["black-pi"]
    nested = dict(black["keys"], **{n: dict(k, key=k["key"].replace("/", "/x_")) for n, k in black["keys"].items() if "/" in k["key"]})
    check(any("/" in k["key"] for k in black["keys"].values()) and missing_keys(nested, black["files"], paths_of)
          == sorted(f"{n} ({black['files'][n]}: yaml {k['key']})" for n, k in nested.items() if "/x_" in k["key"]),
          "seeded: black-pi's nested keys under a wrong leaf are reported")
    parent = dict(black["keys"], **{n: dict(k, key=k["key"].split("/")[0]) for n, k in black["keys"].items() if "/" in k["key"]})
    check(missing_keys(parent, black["files"], paths_of) == sorted(f"{n} ({black['files'][n]}: yaml {k['key']})"
          for n, k in parent.items() if "/" in black["keys"][n]["key"]),
          "seeded: a key naming a mapping (black-pi's nested keys cut to their parent) is reported, not taken as a leaf")
    check(missing_keys(dict(acer["keys"], open_webui_secret_key={"key": "sops/mac", "format": "yaml"}), acer["files"], paths_of)
          == ["open_webui_secret_key (secrets/homelab/open-webui.yaml: yaml sops/mac)"],
          "seeded: a key inside the sops: metadata is reported, not taken as a secret")
    check(missing_keys(acer["keys"], dict(acer["files"], open_webui_secret_key="secrets/homelab/absent.yaml"), paths_of)
          == ["open_webui_secret_key (secrets/homelab/absent.yaml: yaml open_webui_secret_key)"],
          "seeded: a file that does not exist has no keys")
    check(key_paths(ROOT / "secrets/.sops.yaml") == set(), "seeded: a file with lines it cannot read (a list) has no keys")
    check(missing_keys(dict(acer["keys"], open_webui_secret_key={"key": "open_webui_secret_key", "format": "binary"}), acer["files"], paths_of)
          == ["open_webui_secret_key (secrets/homelab/open-webui.yaml: binary open_webui_secret_key)"],
          "seeded: a non-yaml format is reported, not read as yaml")
    check(undecryptable(acer["files"], "acer", recipients_of) == sorted(f"{n} ({f})" for n, f in acer["files"].items()),
          "seeded: a host with no recorded recipient fails every secret it declares")


def gap(got, want):
    """What one host list lacks or adds against the other, as `-name` and `+name`."""
    return sorted([f"-{n}" for n in set(want) - set(got)] + [f"+{n}" for n in set(got) - set(want)])


def fleet_addresses(fleet):
    """{hostName: [address, *extraAddresses]} for each host of sam.fleet.hosts."""
    return {n: [h["address"]] + h["extraAddresses"] for n, h in fleet.items()}


def pinned_ips(expected, addresses):
    """The hosts whose pinned addresses differ from sam.fleet's, for every host in both."""
    return sorted(n for n, (names, _) in expected.items() if n in addresses
                  and [x for x in names if re.fullmatch(r"[0-9.]+", x)] != addresses[n])


def keepalive(config_text):
    """ssh -G's ServerAliveInterval and ServerAliveCountMax for github.com under a rendered ssh_config."""
    with tempfile.NamedTemporaryFile("w", suffix=".ssh_config", delete=False) as cfg:
        cfg.write(config_text); path = cfg.name
    try:
        out = subprocess.run(["ssh", "-G", "-F", path, "github.com"], capture_output=True, text=True).stdout
    finally:
        pathlib.Path(path).unlink()
    opts = dict(l.split(" ", 1) for l in out.splitlines() if " " in l)
    return opts.get("serveraliveinterval"), opts.get("serveralivecountmax")


def hosts_table(*args, table=None):
    """scripts/hosts-table.sh ARGS (on TABLE's text when given): (exit code, output lines, stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ)
        if table is not None:
            (pathlib.Path(tmp) / "hosts.nix").write_text(table)
            env["HOSTS_TABLE"] = str(pathlib.Path(tmp) / "hosts.nix")
        r = subprocess.run([str(ROOT / "scripts/hosts-table.sh"), *args], env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.split(), r.stderr


CHECK_LINE = '    @{{quote(justfile_directory() / "scripts/hosts-table.sh")}} check {{quote(HOST)}}'


def unchecked_recipes(justfile):
    """The recipes that require a HOST (deploy-rs targets; `HOST=host` ones default to this machine) whose first line is
    not the hosts-table check."""
    return sorted(name for name, first in re.findall(r"^([a-z-]+) HOST:\n([^\n]*)", justfile, re.M) if first != CHECK_LINE)


def deploy_checks(nodes):
    """`just deploy` accepts exactly the deploy-rs nodes: its first line is the hosts-table check, and the table reads
    exactly the nodes. Seeded both ways: deploy without the check, and a table entry that is no deploy node."""
    justfile = (ROOT / "Justfile").read_text()
    check("deploy" not in unchecked_recipes(justfile) and sorted(hosts_table("nodes")[1]) == sorted(nodes),
          f"`just deploy` accepts exactly the deploy-rs nodes {sorted(nodes)}")
    check("deploy" in unchecked_recipes(justfile.replace("deploy HOST:\n" + CHECK_LINE + "\n", "deploy HOST:\n")),
          "seeded: `just deploy` without the hosts-table check is found")
    table = (ROOT / "flake-modules/hosts.nix").read_text()
    stray = table.replace("  configurations.nixos = {\n",
                          '  configurations.nixos = {\n    stray = { roles = [ "base" ]; deploy.remoteBuild = true; };\n', 1)
    check(stray != table and gap(hosts_table("nodes", table=stray)[1], nodes) == ["+stray"],
          "seeded: a hosts-table entry that is no deploy node breaks the equality")


def table_checks(nodes, host_name):
    """The hosts table as scripts/hosts-table.sh reads it, against the evaluated deploy nodes and hostNames."""
    rc, got, _ = hosts_table("nodes")
    check(rc == 0 and sorted(got) == sorted(nodes), f"hosts-table.sh reads exactly the deploy nodes ({got})")
    rc, dirs, _ = hosts_table("hostnames")
    check(rc == 0 and dict(zip(got, dirs)) == host_name, f"hosts-table.sh's host directories are the hostNames ({dict(zip(got, dirs))})")
    text = (ROOT / "flake-modules/hosts.nix").read_text()
    cut = "".join(l for l in text.splitlines(True) if not l.startswith("    asus-b460m = {"))
    check(cut != text and gap(hosts_table("nodes", table=cut)[1], nodes) == ["-asus-b460m"],
          "seeded: a table without asus-b460m's entry reads without it")
    for name in nodes:
        check(hosts_table("check", name)[0] == 0, f"hosts-table.sh check accepts the deploy node {name}")
    for bad in ("acer", "lenovo-21CB001PMX", "lenovo;true", "", "github.com"):
        rc, _, err = hosts_table("check", bad)
        check(rc == 1 and "not an entry of flake-modules/hosts.nix" in err, f"seeded: hosts-table.sh check refuses {bad!r} ({rc})")
    check(hosts_table("nodes", table="{ }\n")[0] == 2, "seeded: a table with no entry it can read exits 2, not an empty list")
    justfile = (ROOT / "Justfile").read_text()
    recipes = re.findall(r"^([a-z-]+) HOST:", justfile, re.M)
    check(sorted(recipes) == ["checks", "deploy", "dry-activate"] and unchecked_recipes(justfile) == [],
          f"every recipe requiring a HOST starts with the hosts-table check ({recipes}; not: {unchecked_recipes(justfile)})")
    check(unchecked_recipes(justfile.replace("dry-activate HOST:\n" + CHECK_LINE + "\n", "dry-activate HOST:\n")) == ["dry-activate"],
          "seeded: a HOST recipe without the check is found")
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run([shutil.which("just") or "just", "--justfile", str(ROOT / "Justfile"), "--working-directory", tmp,
                            "deploy", f"bogus; touch {tmp}/ran"], capture_output=True, text=True)
        check(r.returncode != 0 and "unknown host 'bogus; touch" in r.stderr and not (pathlib.Path(tmp) / "ran").exists(),
              f"`just deploy` refuses a name outside the table before any other line, and runs nothing it carries ({r.returncode})")


def pin_files(root, hosts):
    """{hostName: the text of hosts/<hostName>/ssh_known_hosts, or None}: modules/core/ssh-known-hosts.nix reads each."""
    return {h: (root / "hosts" / h / "ssh_known_hosts").read_text() if (root / "hosts" / h / "ssh_known_hosts").is_file() else None
            for h in hosts}


DOCS = {
    # the `just deploy` host notes: one `#   <node>  <how>` line per deploy-rs node
    "CLAUDE.md deploy block": ("CLAUDE.md", r"\njust deploy HOST.*?\njust checks HOST", r"^#   ({}) {{2,}}\S", "node"),
    "CLAUDE.md Current hostnames": ("CLAUDE.md", r"\nCurrent hostnames:.*?\n\n", r"`({})`", "host"),
    "docs/architecture.md host table": ("docs/architecture.md", r"\n\| Host \| Mode \|.*?\n\n", r"^\| `({})` \|", "host"),
    "docs/nspawn-workers.md runtime-host rows": ("docs/nspawn-workers.md", r"\n\| Host \| Pool \|.*?\n\n", r"^\| ({}) \|", "runtime-host"),
}


# a power window as the docs write it: "Mon-Fri ~08:30-21:00" (the ~ optional)
# (an en dash or a one-digit hour too; a window in prose, "powers off at 21:00", is not read)
WINDOW = re.compile(r"\b((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)(?:[-–](?:Mon|Tue|Wed|Thu|Fri|Sat|Sun))?) ~?(\d{1,2}:\d\d)[-–](\d{1,2}:\d\d)")


def power_window(power):
    """The doc phrase for a sam.fleet power window, from its wake and off OnCalendar values ("Mon-Fri 08:30")."""
    days, wake = power["wake"].rsplit(" ", 1)
    return f"{days} ~{wake}-{power['off'].rsplit(' ', 1)[1]}"


def named(line, host):
    """The line names the host: its hostName, or its first word (msi, asus) as the docs shorten it."""
    return any(re.search(rf"(?<![\w-]){re.escape(n)}(?![\w-])", line) for n in {host, host.split("-")[0]})


def window_drift(texts, fleet, deploy_block):
    """Power windows the docs state that sam.fleet does not: a window on a line must be the window of every host with
    one it names, and name at least one; and the CLAUDE.md deploy block states each window on that host's row."""
    windows = {h: power_window(v["power"]) for h, v in fleet.items() if v.get("power")}
    out = []
    for path, text in texts.items():
        for n, line in enumerate(text.splitlines(), 1):
            for m in WINDOW.finditer(line):
                said = f"{m[1].replace('–', '-')} ~{m[2].zfill(5)}-{m[3].zfill(5)}"
                hosts = [h for h in windows if named(line, h)]
                if not hosts:
                    out.append(f"{path}:{n}: {said} names no host with a power window")
                out += [f"{path}:{n}: {h}'s window is {windows[h]}, not {said}" for h in hosts if windows[h] != said]
    rows = re.search(r"\njust deploy HOST.*?\njust checks HOST", deploy_block, re.DOTALL)
    for h, w in windows.items():
        row = rows and re.search(rf"^#   {re.escape(h)} {{2,}}.*$", rows[0], re.M)
        if not row or w not in row[0]:
            out.append(f"CLAUDE.md deploy block: {h}'s row does not state its power window {w}")
    return out


def sops_rules(text):
    """({path_regex: [(age key, its comment)]}, [path_regex listed again]) from .sops.yaml's creation rules: a key per
    `- age1…` line or in an `age: k1,k2` string. sops uses the first rule a path matches, so a repeat is not read."""
    rules, repeated, cur = {}, [], None
    for line in text.splitlines():
        if m := re.match(r"\s*- path_regex: (\S+)", line):
            cur = None if m[1] in rules else m[1]
            if cur is None:
                repeated.append(m[1])
            else:
                rules[cur] = []
        elif cur and (m := re.match(r"\s*- (age1[0-9a-z]+)\s*(?:#\s*(.*))?$", line)):
            rules[cur].append((m[1], (m[2] or "").split("(")[0].strip()))
        elif cur and (m := re.match(r"\s*age:\s*['\"]?(age1[0-9a-z]+(?:\s*,\s*age1[0-9a-z]+)*)['\"]?\s*$", line)):
            rules[cur] += [(k.strip(), "") for k in m[1].split(",")]
    return rules, repeated


def secrets_table_drift(sops_text, claude_text, hosts):
    """Rows of CLAUDE.md's secrets table that .sops.yaml does not bear out, and rules it leaves out. Recipients by name:
    a host by its key (SOPS_RECIPIENTS), the key every rule lists as Personal, any other key by its .sops.yaml comment
    ("acer-swift lukas", which the table writes acer `lukas`)."""
    rules, repeated = sops_rules(sops_text)
    if not rules:
        return ["secrets/.sops.yaml: no creation rule read"]
    by_key = {k: n for n, k in hosts.items()}
    personal = set.intersection(*({k for k, _ in r} for r in rules.values()))
    derived = {}
    for regex, keys in rules.items():
        glob = regex.replace("\\.", ".").replace(".*", "*").rstrip("$")
        derived[glob] = {"Personal" if k in personal else by_key.get(k) or c or f"?{k[:12]}" for k, c in keys}

    def host_of(word):
        full = [h for h in hosts if h == word or h.startswith(word + "-")]
        return full[0] if len(full) == 1 else word

    table = re.search(r"\| Path pattern \| Recipients \|.*?\n\n", claude_text, re.DOTALL)
    doc, twice = {}, []
    for row in re.findall(r"^\| `([^`]+)` \| ([^|]+) \|", table[0] if table else "", re.M):
        if row[0] in doc:
            twice.append(row[0])
        names = set()
        for part in re.sub(r"\([^)]*\)", "", row[1]).replace("+", ",").split(","):
            part = part.strip()
            if m := re.fullmatch(r"(\S+) `(\w+)`", part):
                names.add(f"{host_of(m[1])} {m[2]}")
            elif part:
                names.add(host_of(part))
        doc[row[0]] = names
    out = [f"secrets/.sops.yaml: {r} is listed again; sops reads only its first rule" for r in repeated]
    out += [f"secrets table: {g} has two rows" for g in twice]
    out += [f"secrets table: {g} has no .sops.yaml rule" for g in sorted(set(doc) - set(derived))]
    out += [f"secrets table: no row for .sops.yaml's {g}" for g in sorted(set(derived) - set(doc))]
    out += [f"secrets table: {g} lists {sorted(doc[g] - derived[g])} that .sops.yaml does not, and leaves out {sorted(derived[g] - doc[g])}"
            for g in sorted(set(doc) & set(derived)) if doc[g] != derived[g]]
    return out


def undocumented(texts, nodes, host_name, roles):
    """Per document in DOCS, the deploy nodes its host list leaves out: by node name, by hostName, or (runtime-host)
    the hostNames of the nodes with that role."""
    out = {}
    for doc, (path, section, row, kind) in DOCS.items():
        m = re.search(section, texts[path], re.DOTALL)
        block = m.group(0) if m else ""
        want = {n: host_name[n] for n in nodes if kind != "runtime-host" or "runtime-host" in roles[n]}
        out[doc] = sorted(n for n, h in want.items()
                          if not re.search(row.format(re.escape(n if kind == "node" else h)), block, re.MULTILINE))
    return out


def verify_script_checks(known_hosts_text, names):
    """scripts/ssh-known-hosts-verify.sh over fakes: a host that answers with the pinned key is OK (exit 0), with a
    different key DIFF (1), not at all UNREACHABLE (2); a contradicting ~/.ssh/known_hosts entry is named (1)."""
    script = ROOT / "scripts/ssh-known-hosts-verify.sh"
    acer_key = next(l for l in known_hosts_text.splitlines() if l.startswith("acer-swift,")).split(" ", 1)[1]
    other_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ17UFIIh7VzaEykstxZC3QaPDrya+YSS0wMtTAggp4q"  # lenovo's: a real key, the wrong host
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp); fakes = tmp / "bin"; fakes.mkdir()
        (tmp / "known_hosts").write_text(known_hosts_text)
        (fakes / "hostname").write_text("#!/bin/sh\necho test-client\n")
        (fakes / "curl").write_text('#!/bin/sh\nprintf \'{"ssh_keys":["%s"]}\\n\' "${FAKE_GH_KEY:-}"\n')
        (fakes / "ssh").write_text("#!/bin/sh\n[ -n \"${FAKE_SSH_KEY:-}\" ] || exit 255\necho \"$FAKE_SSH_KEY root@fake\"\n")
        for f in fakes.iterdir():
            f.chmod(0o755)
        gh_key = next(l for l in known_hosts_text.splitlines() if l.startswith("github.com ")).split(" ", 1)[1]
        env = dict(os.environ, PATH=f"{fakes}:{os.environ['PATH']}", KNOWN_HOSTS=str(tmp / "known_hosts"),
                   USER_KNOWN_HOSTS=str(tmp / "user_known_hosts"), FAKE_GH_KEY=gh_key)

        def run(**extra):
            return subprocess.run([str(script), "acer-swift"], env=dict(env, **extra), capture_output=True, text=True)

        r = run(FAKE_SSH_KEY=acer_key)
        check(r.returncode == 0 and "OK   acer-swift live" in r.stdout and "OK   acer-swift sops-recipient" in r.stdout and "OK   github.com" in r.stdout,
              "verify: a host answering with its pinned key, github matching the publisher: OK, exit 0")
        r = run(FAKE_SSH_KEY=other_key)
        check(r.returncode == 1 and "DIFF acer-swift" in r.stdout, "verify: a host answering with another key: DIFF, exit 1")
        r = run()
        check(r.returncode == 2 and "UNREACHABLE acer-swift" in r.stdout, "verify: a host that does not answer: UNREACHABLE, exit 2 (unknown is never a pass)")
        r = run(FAKE_SSH_KEY=acer_key, FAKE_GH_KEY="")
        check(r.returncode == 2 and "UNCHECKED github.com" in r.stdout, "verify: the publisher API not answering: UNCHECKED, exit 2")
        (tmp / "user_known_hosts").write_text(f"192.168.10.110 {other_key}\n")
        r = run(FAKE_SSH_KEY=acer_key)
        check(r.returncode == 1 and "CONTRADICTION 192.168.10.110:" in r.stdout and "ssh-keygen -R 192.168.10.110" in r.stdout,
              "verify: a first-use entry in the user's known_hosts that contradicts a pin is named with its ssh-keygen -R, exit 1")
        (tmp / "user_known_hosts").write_text(f"acer-swift {acer_key}\n")
        r = run(FAKE_SSH_KEY=acer_key)
        check(r.returncode == 0 and "CONTRADICTION" not in r.stdout, "verify: a user entry equal to the pin is not a contradiction")

        def checked(**extra):
            out = subprocess.run([str(script)], env=dict(env, **extra), capture_output=True, text=True).stdout
            return {m for m in re.findall(r"^(?:OK|DIFF|UNCHECKED|UNREACHABLE) +([A-Za-z0-9-]+)\b", out, re.M)} - {"github"}
        check(gap(checked(), names) == [], f"verify: given no host, it checks every deploy node's host ({sorted(checked())})")
        table = (ROOT / "flake-modules/hosts.nix").read_text()
        (tmp / "hosts.nix").write_text("".join(l for l in table.splitlines(True) if not l.startswith("    asus-b460m = {")))
        check(gap(checked(HOSTS_TABLE=str(tmp / "hosts.nix")), names) == ["-asus-b460m"],
              "seeded: given no host, it follows the table: an entry removed there is not checked")
        r = subprocess.run([str(script)], env=dict(env, HOSTS_TABLE=str(tmp / "absent.nix")), capture_output=True, text=True)
        check(r.returncode == 2 and "UNCHECKED: the hosts table could not be read" in r.stdout,
              f"seeded: an unreadable table is UNCHECKED, exit 2, not a pass over no hosts ({r.returncode})")


def bare_rollbacks(texts):
    """Docs lines that tell `nixos-rebuild … --rollback` without --no-reexec: nixos-rebuild then re-executes itself from
    <nixpkgs/nixos>, which these flake-only hosts lack on NIX_PATH, and fails having changed nothing."""
    return [f"{path}:{n}" for path, text in texts.items() for n, line in enumerate(text.splitlines(), 1)
            if re.search(r"nixos-rebuild (switch|boot|test) --rollback", line) and "--no-reexec" not in line]


def main():
    P = gate_probe.section("known-hosts")
    hosts = P["pinned"]["lenovo"]
    check(set(hosts) == set(EXPECTED), f"exactly the verified hosts are pinned (got {sorted(hosts)})")
    for name, (names, fp) in EXPECTED.items():
        entry = hosts.get(name) or {}
        key = entry.get("publicKey") or ""
        check(key.startswith("ssh-ed25519 ") and fingerprint(key) == fp,
              f"{name}: an ed25519 key whose fingerprint is the verified {fp}")
        want = names + (LOOPBACK if name == "lenovo-21CB001PMX" else [])
        check(entry.get("hostNames") == want, f"{name}: hostNames are exactly {want} on lenovo (got {entry.get('hostNames')})")
        check(not entry.get("publicKeyFile") and "placeholder" not in key.lower() and "TODO" not in key,
              f"{name}: a literal verified key, no file reference or placeholder")
    sops = (ROOT / "secrets/.sops.yaml").read_text()
    for name, recipient in SOPS_RECIPIENTS.items():
        age = ssh_to_age(hosts[name]["publicKey"])
        check(age == recipient and re.search(rf"- {re.escape(recipient)}\s+# {re.escape(name)}\b", sops) is not None,
              f"{name}: the pinned key is the host's sops recipient in secrets/.sops.yaml (evidence independent of ssh)")
    acer = P["pinned"]["acer-swift"]
    check(acer["acer-swift"]["hostNames"] == EXPECTED["acer-swift"][0] + LOOPBACK
          and acer["lenovo-21CB001PMX"]["hostNames"] == EXPECTED["lenovo-21CB001PMX"][0],
          "a host pins localhost to its own key only (acer's entry carries loopback on acer, lenovo's does not)")
    known = P["knownHostsFile"]
    lines = [l for l in known.splitlines() if l.strip()]
    check(len(lines) == len(EXPECTED), f"/etc/ssh/ssh_known_hosts has one line per host ({len(lines)})")
    for name, (names, _) in EXPECTED.items():
        line = next((l for l in lines if l.startswith(names[0] + ",") or l.startswith(names[0] + " ")), None)
        check(line is not None and all(n in line.split(" ", 1)[0].split(",") for n in names),
              f"{name}: the generated line lists every name and address")
    for host in ("lenovo", "acer-swift"):
        rendered = P["sshConfig"][host]
        strict = re.search(r"Host \*\n\s*StrictHostKeyChecking yes\n\s*UpdateHostKeys no", rendered)
        check(strict is not None and strict.start() < rendered.index("# Generated options"),
              f"{host}: the rendered ssh_config fails closed for every host, ahead of nixpkgs' generated Host * block")
        # the gpg-agent "Match host * exec" line is dropped: it only pokes the agent's tty, which is not under test
        plain = "\n".join(l for l in rendered.splitlines() if not l.startswith("Match host * exec"))
        with tempfile.NamedTemporaryFile("w", suffix=".ssh_config", delete=False) as cfg:
            cfg.write(plain); path = cfg.name
        try:
            run = subprocess.run(["ssh", "-G", "-F", path, "unknown-host.example"], capture_output=True, text=True)
        finally:
            pathlib.Path(path).unlink()
        eff = run.stdout
        check(run.returncode == 0 and "stricthostkeychecking true" in eff and "updatehostkeys false" in eff
              and "globalknownhostsfile /etc/ssh/ssh_known_hosts" in eff,
              f"{host}: ssh -G on the rendered file resolves to strict checking against the pinned file")
        check(keepalive(plain) == ("20", "60"),
              f"{host}: ssh to github.com sends a keepalive every 20 s, as a long pre-push gate needs ({keepalive(plain)})")
    without = re.sub(r"Host github\.com\n(?:[ \t]+\S.*\n)+", "", plain)
    check(keepalive(without) == ("0", "3"), f"seeded: without the github.com block the push gets no keepalive ({keepalive(without)})")
    for node in ("lenovo", "acer-swift", "black-pi"):
        opts = P["sshOpts"][node]
        check(opts == ["-o", "StrictHostKeyChecking=yes"], f"deploy-rs node {node} refuses unknown or changed host keys")
    deploy_checks(P["deployNodes"])
    nodes = P["deployNodes"]
    host_name = {n: P["sops"]["hosts"][n]["hostName"] for n in nodes}
    names = host_name.values()
    table_checks(nodes, host_name)
    verify_script_checks(known, names)
    check(gap(set(EXPECTED) - {"github"}, names) == [], f"EXPECTED pins exactly the deploy nodes' hosts ({gap(set(EXPECTED) - {'github'}, names)})")
    check(gap(SOPS_RECIPIENTS, names) == [], f"SOPS_RECIPIENTS names exactly the deploy nodes' hosts ({gap(SOPS_RECIPIENTS, names)})")
    seeded = {n: v for n, v in EXPECTED.items() if n != "asus-b460m"}
    check(gap(set(seeded) - {"github"}, names) == ["-asus-b460m"], "seeded: EXPECTED without asus-b460m fails the deploy-node check")
    addresses = fleet_addresses(P["fleet"])
    check(pinned_ips(EXPECTED, addresses) == [], f"every pinned address is sam.fleet's for a fleet host ({pinned_ips(EXPECTED, addresses)})")
    check(pinned_ips(EXPECTED, dict(addresses, **{"asus-b460m": ["192.168.10.99"]})) == ["asus-b460m"],
          "seeded: a fleet address that moved fails the pinned address")
    order = [host_name[n] for n in sorted(nodes)]
    unpin = (f"modules/core/ssh-known-hosts.nix pins {' '.join(sorted(set(names) - {'asus-b460m'}))}, not the deploy nodes"
             f" of flake-modules/hosts.nix ({' '.join(order)}): another module replaced programs.ssh.knownHosts.")
    uncache = "modules/core/store-cache.nix: black-pi serves a store cache, so its public key belongs in caches there."
    F = P["failing"]
    check(unpin not in F["lenovo"] and uncache not in F["lenovo"], "lenovo fails neither fleet-list assertion")
    check(unpin in F["unpinned"], f"seeded: lenovo without asus-b460m's pin fails the deploy-node assertion ({F['unpinned']})")
    check(uncache in F["uncached"], f"seeded: black-pi serving a store cache with no key listed fails ({F['uncached']})")
    # the docs' power windows and the CLAUDE.md secrets table, against sam.fleet and secrets/.sops.yaml
    docs = {str(p.relative_to(ROOT)): p.read_text() for p in [ROOT / "CLAUDE.md", ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]}
    drift = window_drift(docs, P["fleet"], docs["CLAUDE.md"])
    check(drift == [] and any(v.get("power") for v in P["fleet"].values()),
          f"the docs' power windows are sam.fleet's (wake and off): {drift}")
    seeded = dict(docs, **{"docs/x.md": "Run it in msi's Mon-Fri 09:00-21:00 window\n"})
    check(any("msi-ms7758's window is Mon-Fri ~08:30-21:00, not Mon-Fri ~09:00-21:00" in d for d in window_drift(seeded, P["fleet"], docs["CLAUDE.md"])),
          "seeded: a doc giving msi a 09:00 wake fails")
    cut = re.sub(r"(#   asus-b460m .*?); only in its Mon-Fri ~08:30-21:00 power window", r"\1", docs["CLAUDE.md"])
    check(any("asus-b460m's row does not state its power window" in d for d in window_drift(docs, P["fleet"], cut)),
          "seeded: the CLAUDE.md deploy row of a host with a window, without it, fails")
    sops = (ROOT / "secrets/.sops.yaml").read_text()
    drift = secrets_table_drift(sops, docs["CLAUDE.md"], SOPS_RECIPIENTS)
    check(drift == [], f"CLAUDE.md's secrets table is secrets/.sops.yaml's rules and recipients: {drift}")
    cut = docs["CLAUDE.md"].replace("acer `lukas`, black-pi, naked-pi (msi is wired)", "acer `lukas`, naked-pi (msi is wired)")
    check(any("homelab/wifi.yaml" in d and "black-pi" in d for d in secrets_table_drift(sops, cut, SOPS_RECIPIENTS)),
          "seeded: a table row leaving out a recipient .sops.yaml lists fails")
    extra = sops.replace("  - path_regex: homelab/open-webui\\.yaml$\n    key_groups:\n      - age:\n",
                         "  - path_regex: homelab/open-webui\\.yaml$\n    key_groups:\n      - age:\n"
                         f"          - {SOPS_RECIPIENTS['msi-ms7758']}  # msi-ms7758\n")
    check(extra != sops and any("homelab/open-webui.yaml" in d and "msi-ms7758" in d for d in secrets_table_drift(extra, docs["CLAUDE.md"], SOPS_RECIPIENTS)),
          "seeded: a .sops.yaml rule with a recipient the table does not name fails")
    row = re.search(r"^\| `homelab/grafana.yaml` .*$", docs["CLAUDE.md"], re.M)[0]
    stale = docs["CLAUDE.md"].replace(row, row.replace("black-pi", "msi-ms7758") + "\n" + row)
    check(any("homelab/grafana.yaml has two rows" in d for d in secrets_table_drift(sops, stale, SOPS_RECIPIENTS)),
          "seeded: a stale second row for the same path fails, not read past")
    again = sops + "  - path_regex: homelab/grafana\\.yaml$\n    key_groups:\n      - age:\n          - age1x\n"
    check(any("listed again" in d for d in secrets_table_drift(again, docs["CLAUDE.md"], SOPS_RECIPIENTS)),
          "seeded: a path_regex listed twice in .sops.yaml fails (sops reads only the first)")
    check(any("not Mon-Fri ~09:00-21:00" in d for d in window_drift({"docs/x.md": "msi: Mon–Fri ~9:00–21:00\n"}, P["fleet"], docs["CLAUDE.md"])),
          "seeded: a window with en dashes and a one-digit hour is read, and its drift found")
    texts = {path: (ROOT / path).read_text() for path, *_ in DOCS.values()}
    gaps = undocumented(texts, nodes, host_name, P["roles"])
    for doc, missing in gaps.items():
        check(not missing, f"{doc} lists every deploy node (not: {missing})")
    cut = dict(texts, **{"docs/architecture.md": texts["docs/architecture.md"].replace("| `asus-b460m` |", "| asus |")})
    check(undocumented(cut, nodes, host_name, P["roles"])["docs/architecture.md host table"] == ["asus-b460m"],
          "seeded: the architecture host table without asus-b460m fails")
    # alloy-otlp keeps host.name only for a fleet host: alloy-otlp.nix renders @hosts@ from sam.fleet.hosts
    def alloy_hosts(text):
        return re.findall(r'IsMatch\(resource\.attributes\["host\.name"\], "\^\(([^)]*)\)\$"\)', text)
    alloy = (ROOT / "modules/homelab/monitoring/alloy-otlp.alloy").read_text()
    check(len(alloy_hosts(alloy)) == 2 and set(alloy_hosts(alloy)) == {"@hosts@"},
          f"alloy-otlp's host.name allowlists are both rendered from sam.fleet ({alloy_hosts(alloy)})")
    check(set(alloy_hosts(alloy.replace("@hosts@", "acer-swift", 1))) != {"@hosts@"},
          "seeded: a hand-listed host.name allowlist fails")
    sops_checks(P["sops"], P["deployNodes"])
    services = (ROOT / "modules/core/services.nix").read_text()
    check("knownHosts" not in services, "the old github pin in services.nix is gone: one module owns host keys")
    module = (ROOT / "modules/core/ssh-known-hosts.nix").read_text()
    check(module.count("SHA256:") == 1 and EXPECTED["github"][1] in module, "github.com's key carries its fingerprint in the module")
    files = pin_files(ROOT, names)
    check(all(files.values()) and all(EXPECTED[h][1] in files[h] for h in files if h in EXPECTED),
          f"every deploy node's key is in its own hosts/<dir>/ssh_known_hosts, beside its verified fingerprint ({sorted(files)})")
    check(pin_files(ROOT, [*names, "seventh"])["seventh"] is None, "seeded: a host with no hosts/<dir>/ssh_known_hosts has no pin")
    docs = (ROOT / "docs/ssh-host-keys.md").read_text()
    check(all(fp.split(":", 1)[1] in docs and names[0] in docs for names, fp in EXPECTED.values()) and "ssh-to-age" in docs,
          "docs/ssh-host-keys.md lists every pinned host with its fingerprint and the sops-recipient evidence")
    check("GlobalKnownHostsFile=/dev/null" in docs and "accept-new" not in docs and "/tmp/kh" not in docs,
          "the recovery path bypasses the stale global pin with a console-verified temporary file, never accept-new")
    for word in ("onboard", "rotation", "recover", "reinstall", "ssh-keyscan"):
        check(word in docs.lower(), f"the runbook covers {word}")
    print("FAILED" if FAILED else "all checks passed")
    rollback_docs = {str(p.relative_to(ROOT)): p.read_text() for p in [*sorted(ROOT.glob("*.md")), *sorted((ROOT / "docs").glob("*.md"))]}
    check(bare_rollbacks(rollback_docs) == [], f"every documented rollback uses --no-reexec ({bare_rollbacks(rollback_docs)})")
    check(bare_rollbacks({"docs/x.md": "ssh deploy@acer-swift sudo nixos-rebuild switch --rollback\n"}) == ["docs/x.md:1"],
          "seeded: a doc giving `nixos-rebuild switch --rollback` without --no-reexec fails")
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
