#!/usr/bin/env python3
"""The flake's output kinds against scripts/flake-output-kinds.json, the list the gate's nixos-flake-check step knows
(devenv.nix): a kind the step does not know fails that step only after every output evaluated, minutes into the full
gate. Reads the kinds alone, in seconds: no host, package or check is evaluated. A kind is counted as `nix flake show`
lists it, so one with no leaf (apps = { x86_64-linux = { }; }) is not.

Usage: test-flake-output-kinds.py    run from the checkout to test"""

import json
import pathlib
import subprocess
import sys

KINDS = pathlib.Path("scripts/flake-output-kinds.json")
EXPR = """
let
  o = (builtins.getFlake (toString ./.)).outputs;
  empty = v: builtins.isAttrs v && (v == { } || builtins.all (x: x == { }) (builtins.attrValues v));
in
builtins.filter (k: !empty o.${k}) (builtins.attrNames o)
"""

known = json.loads(KINDS.read_text())
if known != sorted(known):
    print(f"FAIL: {KINDS} is not sorted: the step compares it with `jq -c keys`, which sorts")
    sys.exit(1)
out = subprocess.run(["nix", "eval", "--json", "--impure", "--no-write-lock-file", "--expr", EXPR],
                     capture_output=True, text=True)
if out.returncode != 0:
    print(out.stderr, file=sys.stderr)
    print("FAIL: the flake's output names do not evaluate")
    sys.exit(1)
kinds = json.loads(out.stdout)
new, gone = sorted(set(kinds) - set(known)), sorted(set(known) - set(kinds))
if new or gone:
    print(f"FAIL: flake outputs are {json.dumps(kinds)}; {KINDS} has {json.dumps(known)}: "
          f"new {new}, gone {gone}. Teach devenv.nix's nixos-flake-check step the kind, then list it there")
    sys.exit(1)
print(f"PASS: the flake's output kinds are the {len(kinds)} the gate's nixos-flake-check step knows")
