"""A test's section of scripts/gate-probe.nix: the probe nixos:qa built once (GATE_PROBE), or, for a test run on
its own, a probe of that section alone. As a command it prints the section, for the shell gates."""
import json
import os
import subprocess
import sys


def section(name):
    path = os.environ.get("GATE_PROBE") or subprocess.run(
        ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr",
         f'(import ./scripts/gate-probe.nix {{ only = [ "{name}" ]; }}).json'],
        check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
    with open(path) as f:
        return json.load(f)[name]


if __name__ == "__main__":
    print(json.dumps(section(sys.argv[1])))
