"""The developer-environment core (modules/workers/core.nix) rejects a wrong configuration at evaluation: each case is
one small NixOS evaluation of only that module on a stub host, run one at a time. A valid host passes, and the agent's
command line survives quotes, backslashes and newlines through the guest's login shell (fish and bash)."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = os.getcwd()
failed = 0

BASE = r"""
{ lib, pkgs, ... }: {
  boot.isContainer = true;
  system.stateVersion = "25.11";
  networking.hostName = "box";
  services.openssh.enable = true;
  programs.ssh.knownHosts.box = { hostNames = [ "box" ]; publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ17UFIIh7VzaEykstxZC3QaPDrya+YSS0wMtTAggp4q"; };
  users.users.alice = { isNormalUser = true; uid = 1000; linger = true; };
  services.devEnvironments = {
    user = "alice";
    guestModules = [ { system.stateVersion = "25.11"; } ];
    pool.memory = "8G";
    sessionSurface = { name = "surface"; script = w: pkgs.writeShellScriptBin "surface-${w.name}" "true"; };
    instances.ok = { model = "sonnet"; prompt = "Fix it's \"quoted\"\nand go."; };
  };
}
"""

EXPR = r"""
let
  flake = builtins.getFlake (toString %(root)s);
  sys = flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ "${flake}/modules/workers/core.nix" (%(base)s) ({ lib, ... }: %(case)s) ];
  };
in %(what)s
"""
FAILING = "map (a: a.message) (builtins.filter (a: !a.assertion) sys.config.assertions)"

# (name, module, expected message substring); each must fail an assertion
ASSERTED = [
    ("model without an agent", '{ services.devEnvironments.instances.ok = { agent = "none"; prompt = lib.mkForce null; }; }', 'ok.model is set but agent is "none"'),
    ("prompt without an agent", '{ services.devEnvironments.instances.ok = { agent = "none"; model = lib.mkForce null; }; }', 'ok.prompt is set but agent is "none"'),
    ("prompt without a surface", "{ services.devEnvironments.sessionSurface = lib.mkForce null; }", "prompt needs a sessionSurface"),
    ("reserve above max", '{ services.devEnvironments.instances.ok.memory = { reserved = "4G"; max = "3G"; }; }', "reserved 4096M is above max 3072M"),
    ("max above pool", '{ services.devEnvironments.instances.ok.memory.max = "9G"; }', "memory.max 9216M is above pool.memory 8192M"),
    ("reserves above pool", "{ services.devEnvironments.instances = { a = { }; b = { }; c = { }; d = { }; }; }", "adds up to 10240M, more than pool.memory 8192M"),
    ("hash collision", "{ services.devEnvironments.instances = { eal = { }; ea1 = { }; }; }", "two names hash to one address"),
    ("host's own name", "{ networking.hostName = lib.mkForce \"ok\"; programs.ssh.knownHosts.box.hostNames = [ \"ok\" ]; }", "the name is this host's own"),
    ("networking.hosts clash", '{ networking.hosts."192.168.1.5" = [ "ok.box" ]; }', "networking.hosts already maps the name"),
    ("container declared twice", "{ containers.ok.extraFlags = [ ]; }", "containers.ok is also declared elsewhere"),
    ("subnet on an interface", '{ networking.interfaces.eth0.ipv4.addresses = [ { address = "10.233.7.1"; prefixLength = 24; } ]; }', "10.233.0.0/16 holds an address of this host (10.233.7.1)"),
    ("retired and declared", '{ services.devEnvironments.retired = [ "ok" ]; }', "retired: ok is also declared in instances"),
    ("blocked networks on nftables", '{ networking.nftables.enable = true; services.devEnvironments.blockedNetworks = [ "192.168.1.0/24" ]; }', "blockedNetworks needs the iptables"),
    ("unknown user", '{ services.devEnvironments = { user = lib.mkForce "bob"; uid = 1000; }; }', "bob is not a normal user"),
    ("uid differs", "{ services.devEnvironments.uid = 1001; }", "uid 1001 is not users.users.alice.uid"),
    ("no linger", "{ users.users.alice.linger = lib.mkForce false; }", "needs users.users.alice.linger = true"),
    ("jump to an unknown host", '{ services.devEnvironments.jumpHosts.far = "nowhere"; }', "nowhere must be pinned"),
    ("jump prefix", '{ services.devEnvironments.jumpHosts.Far = "box"; }', "jumpHosts.Far: the prefix is"),
    ("guest without sshd", "{ services.devEnvironments.guestModules = [ { services.openssh.enable = lib.mkForce false; } ]; }", "a guest module disabled sshd"),
    ("unknown credential", '{ services.devEnvironments.instances.ok.credentials = [ "nope" ]; }', "credentials names one that"),
    ("credential name", '{ services.devEnvironments.credentials."a b" = "/etc/x"; }', 'credentials.a b: a file name'),
]

# (name, module, expected stderr substring); each must fail the evaluation on its type
TYPED = [
    ("name pattern", "{ services.devEnvironments.instances.Bad = { }; }", "pattern [a-z][a-z0-9-]{0,10}"),
    ("name length", "{ services.devEnvironments.instances.abcdefghijkl = { }; }", "pattern [a-z][a-z0-9-]{0,10}"),
    ("unknown agent", '{ services.devEnvironments.instances.ok.agent = "gpt"; }', "is not of type `one of \"none\", \"claude\", \"codex\""),
    ("size syntax", '{ services.devEnvironments.instances.ok.memory.max = "6GB"; }', "instances.ok.memory.max' is not of type"),
    ("model charset", '{ services.devEnvironments.instances.ok.model = "a b"; }', "instances.ok.model' is not of type"),
    ("empty prompt", '{ services.devEnvironments.instances.ok.prompt = ""; }', "instances.ok.prompt' is not of type"),
    ("zero cores", "{ services.devEnvironments.instances.ok.cpu.reserved = 0; }", "cpu.reserved' is not of type"),
    ("relative key", '{ services.devEnvironments.clientKey = "id_ed25519"; }', "clientKey' is not of type"),
    ("cidr syntax", '{ services.devEnvironments.blockedNetworks = [ "10.0.0.0" ]; }', "blockedNetworks"),
    ("state dir outside /var/lib", '{ services.devEnvironments.stateDir = "/home"; }', "stateDir' is not of type"),
    ("retired name", '{ services.devEnvironments.retired = [ "Bad" ]; }', "retired.\"[definition 1-entry 1]\"' is not of type"),
]

# the fleet adapter (modules/workers/default.nix) on msi with an instance of the test's own (the host may declare none): lazy, so still cheap
FLEET = r"""
let c = ((builtins.getFlake (toString %(root)s)).nixosConfigurations.msi-ms7758.extendModules { modules = [ ({ lib, ... }: %(case)s) ]; }).config;
in map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions)
"""
FLEET_CASES = [
    ("claude without the token secret", "{ sam.hostSecrets.enable = lib.mkForce false; sam.workers.instances.t = { }; }", "claude instance logs in with the host's sops secret"),
]

# the unit whose change restarts an instance: no nixpkgs bump, resize or prompt edit may change it, a model change must
DECLARATION = r"""
let
  unit = c: c.systemd.units."dev-env-ok.service".text;
  with_ = m: unit (sys.extendModules { modules = [ m ]; }).config;
  base = unit sys.config;
in {
  storeFree = builtins.length (builtins.split "/nix/store" base) == 1;
  live = base == with_ ({ lib, ... }: { services.devEnvironments.instances.ok = { memory.max = "5G"; cpu.reserved = 1; prompt = lib.mkForce "other"; }; });
  restarts = base != with_ ({ lib, ... }: { services.devEnvironments.instances.ok.model = lib.mkForce "opus"; });
}
"""

NASTY = ["it's", "a\\b", "two\nlines", '$HOME;"x" (y)']
VALID_ARGV = r"""{
  services.devEnvironments = {
    shell = "%(shell)s";
    agents.nasty.command = %(argv)s;
    instances.n = { agent = "nasty"; model = "m"; };
  };
}"""


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def nix_eval(case, what=FAILING):
    expr = EXPR % {"root": json.dumps(ROOT), "base": BASE, "case": case, "what": what}
    return subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expr], capture_output=True, text=True)


def nix_string(s):
    return json.dumps(s).replace("${", "\\${")


def main():
    out = nix_eval("{ }")
    check(out.returncode == 0 and json.loads(out.stdout) == [], f"a valid host fails no assertion ({out.stdout.strip() or out.stderr.strip()[-600:]})")
    out = nix_eval("{ }", "let g = sys.config.containers.ok.config; in { inherit (g.nix) nixPath; channel = g.nix.channel.enable; "
                   "registry = g.nix.settings.flake-registry; }")
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got.get("channel") is False and len(got.get("nixPath", [])) == 1 and got["nixPath"][0].startswith("nixpkgs=/nix/store/")
          and got.get("registry") == "",
          f"a guest resolves <nixpkgs> to the store's nixpkgs, with no channels or global registry to fetch ({got or out.stderr.strip()[-300:]})")
    out = nix_eval("{ }", DECLARATION)
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got == {"storeFree": True, "live": True, "restarts": True},
          f"the declaration unit holds no store path, a resize or prompt edit leaves it, a model change moves it ({got or out.stderr.strip()[-300:]})")
    for name, case, want in ASSERTED:
        out = nix_eval(case)
        got = json.loads(out.stdout) if out.returncode == 0 else [out.stderr.strip()[-600:]]
        check(any(want in m for m in got), f"{name}: rejected with \"{want}\" (got {got})")
    for name, case, want in TYPED:
        out = nix_eval(case, "sys.config.system.build.toplevel.drvPath")
        check(out.returncode != 0 and want in out.stderr, f"{name}: a type error naming \"{want}\" ({out.stderr.strip()[-300:]})")

    out = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", FLEET % {"root": json.dumps(ROOT), "case": "{ }"}],
                         capture_output=True, text=True)
    check(out.returncode == 0 and json.loads(out.stdout) == [], f"msi-ms7758 as committed fails no assertion ({out.stdout.strip() or out.stderr.strip()[-600:]})")
    for name, case, want in FLEET_CASES:
        out = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", FLEET % {"root": json.dumps(ROOT), "case": case}],
                             capture_output=True, text=True)
        check(want in out.stdout + out.stderr, f"fleet {name}: rejected with \"{want}\" ({(out.stdout + out.stderr).strip()[-300:]})")

    real = {s: shutil.which(s) for s in ("fish", "bash")}
    for shell in ("fish", "bash"):
        argv = "[ " + " ".join(nix_string(a) for a in ["claude", *NASTY]) + " ]"
        case = VALID_ARGV % {"shell": shell, "argv": argv}
        out = subprocess.run(["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr",
                              EXPR % {"root": json.dumps(ROOT), "base": BASE, "case": case,
                                      "what": "sys.config.system.build.devEnvironments.n.start"}],
                             capture_output=True, text=True)
        if out.returncode != 0:
            check(False, f"{shell}: the agent script builds ({out.stderr.strip()[-600:]})")
            continue
        script = out.stdout.strip()
        with tempfile.TemporaryDirectory() as d:
            stub = pathlib.Path(d, shell)
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o755)
            define = "function claude; printf '%s\\0' $argv; end" if shell == "fish" else "claude() { printf '%s\\0' \"$@\"; }"
            flags = ["--no-config"] if shell == "fish" else ["--norc", "--noprofile"]
            run = subprocess.run([real[shell], *flags, "-c", f"{define}; source {script}"], capture_output=True, text=True,
                                 env={"PATH": f"{d}:{os.environ['PATH']}", "HOME": d})
        got = run.stdout.split("\0")[:-1]
        check(got == [*NASTY, "--model", "m"], f"{shell}: the agent's argv survives the login shell verbatim (got {got!r}, {run.stderr.strip()[:200]})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
