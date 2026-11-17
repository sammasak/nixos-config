#!/usr/bin/env python3
"""Typed interfaces (#295 items 4 and 8): no option is typed types.attrs, whose merge keeps one definition's keys and
drops the rest's silently (nixpkgs lib/types.nix), and no read of a declared sam.* option carries an `or` fallback,
which turns a renamed or removed option into the fallback value instead of an evaluation error. Seeded snippets
of both shapes must be caught and their allowed neighbours (attrsOf, a dynamic attrsOf lookup) must not."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# a sam.* option path read through config or osConfig (also a guest's …config.sam…), then `or`, across newlines;
# a ${…} segment is an attrsOf lookup, where `or` is the only way to read a missing key, so it stops the match
FALLBACK = re.compile(r"\b(?:osConfig|config)\.sam(?:\.[A-Za-z0-9_'-]+)+\s+or\b")
UNTYPED = re.compile(r"\btypes\.attrs\b(?!Of)")
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def hits(text):
    return [m.group(0).split()[0] for m in FALLBACK.finditer(text)] + [m.group(0) for m in UNTYPED.finditer(text)]


seeded = {
    "isDesktop = osConfig.sam.desktop.enable or false;": True,
    "machines = (osConfig.sam.herdr.machines\n    or [ ]);": True,
    "keys = config.containers.x.config.sam.userConfig.sshKeys or [ ];": True,
    "userConfig = mkOption { type = types.attrs; };": True,
    "type = lib.types.attrs;": True,
    "type = types.attrsOf types.str;": False,
    "a = (config.sam.fleet.hosts.${n} or { }).address;": False,
    "x = config.sops.secrets.foo.path or null;": False,
    "x = config.sam.desktop.enable;": False,
}
for text, bad in seeded.items():
    check(bool(hits(text)) == bad, f"{'caught' if bad else 'allowed'}: {text!r}")

files = [p for d in ("modules", "flake-modules", "lib", "hosts", "tests") for p in (ROOT / d).rglob("*.nix")]
found = [f"{p.relative_to(ROOT)}: {h}" for p in files for h in hits(p.read_text())]
check(len(files) > 100 and not found, f"no types.attrs and no sam.* `or` fallback in {len(files)} .nix files ({found})")

sys.exit(1 if failed else 0)
