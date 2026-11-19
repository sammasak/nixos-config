#!/usr/bin/env python3
"""The running NixOS generation as node-exporter textfile metrics, at every activation
(modules/homelab/monitoring/node-exporter.nix). The port of the shell writer it replaced: on the same inputs it writes
the same nixos.prom byte for byte (scripts/test-nixos-textfile.py, scripts/fixtures/nixos-textfile-parity.json).

A link is SYSTEM's when its activate script is SYSTEM's: deploy-rs points the profile at an activatable-* buildEnv
around the toplevel, never at the toplevel itself. The generation is the profile's when it is SYSTEM, else the newest
matching link (a boot or rollback into an older one); none for a specialisation or a test switch.

Where the shell went quiet, this fails out loud. A missing toplevel or nixos-version (the shell wrote version="" or
stopped and left the previous file, unseen behind the activation's `|| true`) writes nixos.prom with only
homelab_nixos_textfile_failed{reason=...} 1 and exits 1; a file it cannot write exits 1 with the error on stderr.

Usage: nixos-textfile DIR SYSTEM PROFILES"""

import glob
import os
import re
import sys
import tempfile
from collections.abc import Sequence

FAILED = "homelab_nixos_textfile_failed"


class TextfileError(Exception):
    pass


def generation(system: str, profiles: str) -> str:
    key = os.path.realpath(os.path.join(system, "activate"))
    current = os.path.join(profiles, "system")
    gen = ""
    if os.path.realpath(os.path.join(current, "activate")) == key:
        try:
            gen = os.path.basename(os.readlink(current))
        except OSError:
            gen = ""
    else:
        # as the shell's loop: the first matching link sets it, a later one replaces it only when both are numbers
        # and it is greater (the shell's `[ -gt ]` refuses anything else)
        for link in sorted(glob.glob(os.path.join(glob.escape(profiles), "system-*-link"))):
            if os.path.realpath(os.path.join(link, "activate")) != key:
                continue
            n = os.path.basename(link).removeprefix("system-").removesuffix("-link")
            have = gen.removeprefix("system-")
            if not gen or (re.fullmatch(r"-?[0-9]+", n) and re.fullmatch(r"-?[0-9]+", have) and int(n) > int(have)):
                gen = "system-" + n
    return gen.removeprefix("system-").removesuffix("-link")


def lines(system: str, profiles: str) -> list[str]:
    if not os.path.isdir(system):
        raise TextfileError("system-missing")
    try:
        with open(os.path.join(system, "nixos-version")) as f:
            version = f.read().rstrip("\n")
    except OSError:
        raise TextfileError("version-unreadable") from None
    toplevel = os.path.basename(system).split("-", 1)[0]
    out = [f'homelab_nixos_info{{version="{version}",toplevel="{toplevel}"}} 1']
    gen = generation(system, profiles)
    if gen:
        out.append(f"homelab_nixos_generation {gen}")
    return out


def write(directory: str, text: str) -> None:
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".nixos.prom.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            os.fchmod(f.fileno(), 0o644)
        os.replace(tmp, os.path.join(directory, "nixos.prom"))
    except BaseException:
        os.unlink(tmp)
        raise


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 3:
        print("usage: nixos-textfile DIR SYSTEM PROFILES", file=sys.stderr)
        return 2
    directory, system, profiles = args[0], os.path.realpath(args[1]), args[2]
    try:
        try:
            write(directory, "\n".join(lines(system, profiles)) + "\n")
            return 0
        except TextfileError as e:
            print(f"nixos-textfile: {e} ({system})", file=sys.stderr)
            write(directory, f'{FAILED}{{reason="{e}"}} 1\n')
            return 1
    except OSError as e:
        print(f"nixos-textfile: cannot write {directory}/nixos.prom: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
