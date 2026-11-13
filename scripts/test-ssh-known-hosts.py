#!/usr/bin/env python3
"""Wiring test for modules/core/ssh-known-hosts.nix (nixos-config#86): the pinned host keys are the verified ones
(fingerprints recorded here and in docs/ssh-host-keys.md), every name and address of each host is covered, a host
pins loopback to its own key only, every client fails closed, deploy-rs too, the old github pin is gone, and every
sops secret a host declares is in a file encrypted to that host's key."""
import os
import pathlib
import re
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
    "black-pi": (["black-pi", "192.168.10.137", "192.168.10.136"], "SHA256:i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY"),
    "naked-pi": (["naked-pi", "192.168.10.127", "192.168.10.138", "192.168.10.180"], "SHA256:auOEtU3d4yfB4U6iB7WIt0gSCLwK7hCDPorJAwVs0sY"),
}
# every fleet host decrypts its sops secrets with its ssh host key: the key's age form must be that host's recipient
SOPS_RECIPIENTS = {
    "lenovo-21CB001PMX": "age13lj7pyzzspnk8ck3rg5kgh63ekm7k9j5cyzl8awzr37hnr34r94qugqc4y",
    "acer-swift": "age1uu9y3sfr4htk4rrsw66df5gn2xt3t3mykm52ljxlctj37yuza5mqpxlyuk",
    "msi-ms7758": "age1g0k9vwsduy0sclensm38ksxgj5pkjds4r4su5dqufee6lxtl0gzsmvcx4r",
    "black-pi": "age16l5rqqh0xv9r6rcuyyz2s9ca5ex25azg9dp4z460zh2r3eqwd3ps9yx7tn",
    "naked-pi": "age1kdjqlt6s6fklcdjm2y9dggyvc9nmpcglsu3gduzudcl85ur8jdwqz26wer",
}
LOOPBACK = ["localhost", "127.0.0.1", "::1"]


def check(condition, message):
    global FAILED
    if not condition:
        FAILED = True
        print(f"FAIL: {message}")
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


def undecryptable(files, host, recipients_of):
    """The secrets a host declares whose file does not list the host's recipient (an unknown host: all of them)."""
    want = SOPS_RECIPIENTS.get(host)
    return sorted(f"{name} ({f})" for name, f in files.items() if want is None or want not in recipients_of(f))


def sops_checks(S):
    """Every secret a host declares is encrypted to that host's key, read from the files' plaintext metadata:
    sops-nix's own build check confirms the key exists in the file, not that the host can decrypt it."""
    cache = {}
    def recipients_of(f):
        return cache.setdefault(f, sops_recipients(ROOT / f))
    check(set(S["hosts"]) == {"lenovo", "acer-swift", "msi-ms7758", "black-pi", "naked-pi"}, f"every fleet host is checked ({sorted(S['hosts'])})")
    for attr, h in S["hosts"].items():
        bad = undecryptable(h["files"], h["hostName"], recipients_of)
        check(h["files"] and not bad, f"{attr}: each of its {len(h['files'])} sops secrets is in a file encrypted to {h['hostName']} (not: {bad})")
    bad = undecryptable(S["seeded"], "black-pi", recipients_of)
    check(bad == ["native_otlp_auth (secrets/claude/native-otlp-auth.yaml)"], f"seeded: black-pi with nativeOtel declares the relay's secret, not encrypted to it ({bad})")
    acer = S["hosts"]["acer-swift"]
    dropped = lambda f: recipients_of(f) - {SOPS_RECIPIENTS["acer-swift"]} if f == "secrets/homelab/k3s.yaml" else recipients_of(f)
    bad = undecryptable(acer["files"], "acer-swift", dropped)
    check(bad == ["k3s/cluster_token (secrets/homelab/k3s.yaml)"], f"seeded: k3s.yaml with acer's recipient dropped fails acer's k3s token ({bad})")
    check(undecryptable(acer["files"], "acer", recipients_of) == sorted(f"{n} ({f})" for n, f in acer["files"].items()),
          "seeded: a host with no recorded recipient fails every secret it declares")


def verify_script_checks(known_hosts_text):
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
    check(P["defaults"]["strict"] is True and P["defaults"]["enable"] is True,
          "the module is one switch (enable) plus one for strictness, both on by default")
    for node in ("lenovo", "acer-swift", "black-pi"):
        opts = P["sshOpts"][node]
        check(opts == ["-o", "StrictHostKeyChecking=yes"], f"deploy-rs node {node} refuses unknown or changed host keys")
    pattern = re.search(r'\[arg\("HOST", pattern="([^"]+)"\)\]\ndeploy HOST:',
                        re.sub(r'\[doc\([^\n]*\)\]\n', "", (ROOT / "Justfile").read_text()))
    check(pattern is not None and sorted(pattern.group(1).split("|")) == sorted(P["deployNodes"]),
          f"`just deploy` accepts exactly the deploy-rs nodes {sorted(P['deployNodes'])}")
    verify_script_checks(known)
    sops_checks(P["sops"])
    services = (ROOT / "modules/core/services.nix").read_text()
    check("knownHosts" not in services, "the old github pin in services.nix is gone: one module owns host keys")
    module = (ROOT / "modules/core/ssh-known-hosts.nix").read_text()
    check(module.count("SHA256:") == len(EXPECTED) and all(fp in module for _, fp in EXPECTED.values()),
          "every pinned key carries its verified fingerprint in the module")
    docs = (ROOT / "docs/ssh-host-keys.md").read_text()
    check(all(fp.split(":", 1)[1] in docs and names[0] in docs for names, fp in EXPECTED.values()) and "ssh-to-age" in docs,
          "docs/ssh-host-keys.md lists every pinned host with its fingerprint and the sops-recipient evidence")
    check("GlobalKnownHostsFile=/dev/null" in docs and "accept-new" not in docs and "/tmp/kh" not in docs,
          "the recovery path bypasses the stale global pin with a console-verified temporary file, never accept-new")
    for word in ("onboard", "rotation", "recover", "reinstall", "ssh-keyscan"):
        check(word in docs.lower(), f"the runbook covers {word}")
    print("FAILED" if FAILED else "all checks passed")
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
