"""acer's ak (modules/homelab/authentik.nix): upstream's lifecycle/ak through systemd-run as user authentik, with the
server unit's sandbox and state directory, a memory cap, and its env file by path; the -E names are the unit's
environment keys less the prometheus multiproc dir."""
import shlex
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("authentik")
check(P["ak"] is not None, "acer's systemPackages carry ak")
text = open(f"{P['ak']}/bin/ak").read() if P["ak"] else ""
argv = shlex.split(text.replace("\\\n", " ").partition("exec ")[2])
props = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-p"]
env = {argv[i + 1].partition("=")[0] for i, a in enumerate(argv[:-1]) if a == "-E"}

check('lifecycle/ak "$@"' in text, "ak hands its arguments to upstream's lifecycle/ak unsplit")
check("--pty" in argv and "--pipe" in argv, "systemd-run picks a tty or pipes per stdio")
check("--uid=authentik" in argv and "--gid=authentik" in argv, "ak runs as authentik")
for p in ["EnvironmentFile=/run/secrets/rendered/authentik.env", "ProtectSystem=strict", "PrivateTmp=1",
          "StateDirectory=authentik", "StateDirectoryMode=0750", "CapabilityBoundingSet=", "MemoryMax=1G"]:
    check(p in props, f"ak sets {p} {props}")
check("PROMETHEUS_MULTIPROC_DIR" in P["envKeys"] and "PROMETHEUS_MULTIPROC_DIR" not in text,
      "ak leaves out the server's prometheus multiproc dir")
check(env == set(P["envKeys"]) - {"PROMETHEUS_MULTIPROC_DIR"}, f"ak's -E names are the unit's environment {sorted(env)}")

sys.exit(1 if failed else 0)
