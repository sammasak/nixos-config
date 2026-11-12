"""The developer-environment core (modules/workers/core.nix) rejects a wrong configuration at evaluation: each case is
one small NixOS evaluation of only that module on a stub host. A valid host passes, and the agent's command line
survives quotes, backslashes and newlines through the guest's login shell (fish and bash)."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

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
# the same, of the module under test only: every message ASSERTED expects is its own, and the host's other
# assertions are what make a case cost seconds
OWN = ('map (a: a.message) (builtins.filter (a: !a.assertion) (builtins.concatMap (d: d.value) (builtins.filter '
       '(d: builtins.match ".*/modules/workers/core.nix" d.file != null) sys.options.assertions.definitionsWithLocations)))')

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
FLEET_INSTANCE = "{ sam.workers.instances.t = { }; }"
FLEET_CASES = [
    ("claude without the token secret", "{ sam.hostSecrets.enable = lib.mkForce false; sam.workers.instances.t = { }; }", "claude instance's calls are signed with the host's sops secret"),
    ("github without a gh login", '{ sam.workers.instances.t.egress.github.repos = [ "o/r" ]; }', "signed with the token in sam.workers.ghHostsFile"),
    ("github keeping the ssh key", '{ sam.workers = { ghHostsFile = "/home/lukas/hosts.yml"; instances.t = { egress.github.repos = [ "o/r" ]; credentials = [ "id_ed25519" ]; }; }; }',
     "gets neither id_ed25519 nor gh-hosts.yml"),
]
# msi with two instances behind the GitHub proxy and one without: the proxy's Caddyfile is in the store every guest reads
GITHUB = r"""
let
  flake = builtins.getFlake (toString %(root)s);
  c = (flake.nixosConfigurations.msi-ms7758.extendModules { modules = [ ({ lib, ... }: {
    sam.workers = {
      ghHostsFile = "/home/lukas/hosts.yml";
      instances = lib.mkForce { gh.egress.github.repos = [ "o/r.s" ]; gh2.egress.github.repos = [ "x/y" ]; plain = { }; };
    };
  }) ]; }).config;
  config = flake.inputs.nixpkgs.lib.last (flake.inputs.nixpkgs.lib.splitString " " c.systemd.services.dev-env-egress.serviceConfig.ExecStart);
in {
  failing = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  binds = builtins.mapAttrs (_: w: builtins.attrNames w.bindMounts) c.containers;
  egress = builtins.mapAttrs (_: w: w.bindMounts."/run/egress".hostPath or null) c.containers;
  links = builtins.mapAttrs (_: w: builtins.filter (r: builtins.match ".*id_ed25519.*" r != null) w.config.systemd.tmpfiles.rules) c.containers;
  inherit config;
  caddy = builtins.readFile config;
}
"""

# What the msi guest of FLEET_INSTANCE gets for nested sandboxes (modules/workers/nested-sandbox.nix), read from the rendered
# files; the assertions ride along so one evaluation serves both checks
FLEET_FACTS = r"""
let
  c = ((builtins.getFlake (toString %(root)s)).nixosConfigurations.msi-ms7758.extendModules { modules = [ { sam.workers.instances.t = { }; } ]; }).config;
  g = c.containers.t.config;
  d = builtins.unsafeDiscardStringContext;
in {
  assertions = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  managed = d g.environment.etc."claude-code/managed-settings.json".text;
  containers = d (builtins.readFile g.environment.etc."containers/containers.conf".source);
  storage = d (builtins.readFile g.environment.etc."containers/storage.conf".source);
  hostUntouched = !(c.environment.etc ? "claude-code/managed-settings.json") && !c.virtualisation.podman.enable;
}
"""

# The two wrappers with stubs that print their argv in place of bwrap and crun (jq stays real): the store paths of both
SCRIPTS = r"""
let
  flake = builtins.getFlake (toString %(root)s);
  stub = pkgs: name: pkgs.writeShellScriptBin name ''printf '%%s\n' "$@"'';
  sys = flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${flake}/modules/workers/nested-sandbox.nix"
      { boot.isContainer = true; system.stateVersion = "25.11";
        nixpkgs.overlays = [ (_: prev: { bubblewrap = stub prev "bwrap"; crun = stub prev "crun"; }) ]; }
    ];
  };
  c = sys.config;
  drv = s: builtins.head (builtins.attrNames (builtins.getContext s));
in {
  bwrap = drv c.environment.etc."claude-code/managed-settings.json".text;
  crun = drv (builtins.head c.virtualisation.containers.containersConf.settings.engine.runtimes.crun);
}
"""

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


FAST = {}


def prefetch(exprs):
    """Evaluates every expression in one process; one that throws (or all, if that process fails) is left to run_eval()
    to run on its own, so its check reports the error as before."""
    tried = " ".join(f"(let v = ({e}); r = builtins.tryEval (builtins.deepSeq v v); in if r.success then r.value else null)" for e in exprs)
    out = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", f"[ {tried} ]"], capture_output=True, text=True)
    if out.returncode == 0:
        FAST.update((e, v) for e, v in zip(exprs, json.loads(out.stdout)) if v is not None)
    else:
        print(f"note: the one-process evaluation failed, each case runs on its own ({out.stderr.strip()[-300:]})")


def run_eval(expr):
    if expr in FAST:
        return subprocess.CompletedProcess([], 0, json.dumps(FAST[expr], ensure_ascii=False), "")
    return subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expr], capture_output=True, text=True)


def stub_expr(case, what=FAILING):
    return EXPR % {"root": json.dumps(ROOT), "base": BASE, "case": case, "what": what}


def nix_eval(case, what=FAILING):
    return run_eval(stub_expr(case, what))


def nix_string(s):
    return json.dumps(s).replace("${", "\\${")


GUEST = "let g = sys.config.containers.ok.config; in { inherit (g.nix) nixPath; channel = g.nix.channel.enable; registry = g.nix.settings.flake-registry; }"


def fleet(case, template=FLEET):
    return template % {"root": json.dumps(ROOT), "case": case}


def check_nested(facts):
    managed = json.loads(facts["managed"]) if facts.get("managed") else {}
    conf = facts.get("containers", "")
    check(re.fullmatch(r"/nix/store/[^/]+-bwrap-subset-proc/bin/bwrap-subset-proc", managed.get("sandbox", {}).get("bwrapPath", "")) is not None
          and "enabled" not in managed.get("sandbox", {}),
          f"a guest's managed Claude settings point bwrapPath at the wrapper and leave the sandbox switch alone ({facts.get('managed')})")
    check('runtime = "crun"' in conf and re.search(r'^crun = \["/nix/store/[^/]+-crun-subset-pid/bin/crun-subset-pid"\]$', conf, re.M)
          and 'cgroup_manager = "cgroupfs"' in conf and 'events_logger = "file"' in conf,
          f"a guest's containers.conf keeps the runtime named crun, points it at the wrapper, cgroupfs and file events ({conf})")
    check('driver = "vfs"' in facts.get("storage", ""), "a guest's podman storage is vfs")
    check(facts.get("hostUntouched") is True, "the host itself gets neither the managed Claude settings nor podman")


def check_scripts():
    """Runs both wrappers against stubs that print their argv."""
    out = run_eval(SCRIPTS % {"root": json.dumps(ROOT)})
    if out.returncode != 0:
        check(False, f"the wrapper scripts evaluate ({out.stderr.strip()[-300:]})")
        return
    drvs = json.loads(out.stdout)
    exe = {}
    for name, drv in drvs.items():
        real = subprocess.run(["nix-store", "--realise", drv], capture_output=True, text=True)
        exe[name] = pathlib.Path(real.stdout.split()[0]) / "bin" / ("bwrap-subset-proc" if name == "bwrap" else "crun-subset-pid") if real.returncode == 0 else None
    check(all(exe.values()), "both wrapper scripts build (shellcheck included)")
    if not all(exe.values()):
        return

    def argv(script, *args):
        run = subprocess.run([str(script), *args], capture_output=True, text=True)
        return run.returncode, run.stdout.splitlines(), run.stderr

    rc, got, _ = argv(exe["bwrap"], "--unshare-user", "--cap-drop", "ALL", "--proc", "/proc", "--dev", "/dev", "--", "make", "-j2")
    inner = got.index("--") if "--" in got else -1
    check(rc == 0 and got[:3] == ["--unshare-user", "--cap-drop", "ALL"] and got[3:5] == ["--uid", "0"] and "--proc" not in got
          and got[-2:] == ["make", "-j2"] and got[inner + 2:inner + 4] == ["-p", "-c"] and "subset=pid" in got[inner + 4]
          and "--no-new-privs" in got[inner + 4] and got[inner + 5] == "bash",
          f"bwrap-subset-proc rewrites Claude's shape: mapped root, the host /proc bound, a bash -p mount step before the command ({got})")
    rc, got, _ = argv(exe["bwrap"], "--unshare-user", "--proc", "/proc", "--dev", "/dev")
    check(rc == 0 and got == ["--unshare-user", "--proc", "/proc", "--dev", "/dev"], f"no separator after --proc: passed through unchanged ({got})")
    rc, got, _ = argv(exe["bwrap"], "--proc", "/proc", "--", "tool", "--", "z", "--proc", "/proc")
    check(rc == 0 and got[-5:] == ["tool", "--", "z", "--proc", "/proc"] and got.count("--") == 2,
          f"a -- inside the command's own arguments is left alone ({got})")
    rc, got, _ = argv(exe["bwrap"], "--version")
    check(rc == 0 and got == ["--version"], f"bwrap-subset-proc passes other invocations through ({got})")

    with tempfile.TemporaryDirectory() as bundle:
        cfg = pathlib.Path(bundle, "config.json")
        cfg.write_text(json.dumps({"mounts": [{"destination": "/dev", "type": "tmpfs", "options": ["nosuid"]},
                                              {"destination": "/proc", "type": "proc", "options": ["nosuid", "noexec"]}]}))
        rc, got, _ = argv(exe["crun"], "--root", "/run/x", "--bundle", bundle, "create", "id")
        argv(exe["crun"], "run", "-b", bundle, "id")
        opts = {m["destination"]: m["options"] for m in json.loads(cfg.read_text())["mounts"]}
        check(rc == 0 and got == ["--root", "/run/x", "--bundle", bundle, "create", "id"] and opts["/proc"].count("subset=pid") == 1
              and opts["/dev"] == ["nosuid"], f"crun-subset-pid adds subset=pid to the /proc mount once, however often it runs ({opts}, {got})")
        before = cfg.read_text()
        argv(exe["crun"], "delete", "--bundle", bundle, "id")
        check(cfg.read_text() == before, "crun-subset-pid leaves the bundle alone for other subcommands")
        rc, _, err = argv(exe["crun"], "create", "--bundle", bundle + "/missing", "id")
        check(rc == 1 and "cannot add subset=pid" in err, f"crun-subset-pid refuses a bundle it cannot rewrite ({rc}, {err.strip()})")


def main():
    prefetch([stub_expr("{ }"), stub_expr("{ }", GUEST), stub_expr("{ }", DECLARATION), *(stub_expr(case, OWN) for _, case, _ in ASSERTED),
              fleet("{ }"), fleet(FLEET_INSTANCE, FLEET_FACTS), SCRIPTS % {"root": json.dumps(ROOT)}, *(fleet(case) for _, case, _ in FLEET_CASES),
              GITHUB % {"root": json.dumps(ROOT)}])
    out = nix_eval("{ }")
    check(out.returncode == 0 and json.loads(out.stdout) == [], f"a valid host fails no assertion ({out.stdout.strip() or out.stderr.strip()[-600:]})")
    out = nix_eval("{ }", GUEST)
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got.get("channel") is False and len(got.get("nixPath", [])) == 1 and got["nixPath"][0].startswith("nixpkgs=/nix/store/")
          and got.get("registry") == "",
          f"a guest resolves <nixpkgs> to the store's nixpkgs, with no channels or global registry to fetch ({got or out.stderr.strip()[-300:]})")
    out = nix_eval("{ }", DECLARATION)
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got == {"storeFree": True, "live": True, "restarts": True},
          f"the declaration unit holds no store path, a resize or prompt edit leaves it, a model change moves it ({got or out.stderr.strip()[-300:]})")
    for name, case, want in ASSERTED:
        out = nix_eval(case, OWN)
        got = json.loads(out.stdout) if out.returncode == 0 else [out.stderr.strip()[-600:]]
        check(any(want in m for m in got), f"{name}: rejected with \"{want}\" (got {got})")
    # a type error ends an evaluation, so each TYPED case is a process of its own (about 230 MB): two at a time,
    # after the batch (2.5 GB peak) is done, as environments share the host's memory
    with ThreadPoolExecutor(2) as pool:
        typed = list(pool.map(lambda c: nix_eval(c[1], "sys.config.system.build.toplevel.drvPath"), TYPED))
    for (name, case, want), out in zip(TYPED, typed):
        check(out.returncode != 0 and want in out.stderr, f"{name}: a type error naming \"{want}\" ({out.stderr.strip()[-300:]})")

    out = run_eval(fleet("{ }"))
    check(out.returncode == 0 and json.loads(out.stdout) == [], f"msi-ms7758 as committed fails no assertion ({out.stdout.strip() or out.stderr.strip()[-600:]})")
    out = run_eval(fleet(FLEET_INSTANCE, FLEET_FACTS))
    facts = json.loads(out.stdout) if out.returncode == 0 else {}
    check(facts.get("assertions") == [], f"msi-ms7758 with a claude instance fails no assertion ({facts.get('assertions', out.stderr.strip()[-600:])})")
    check_nested(facts)
    check_scripts()
    for name, case, want in FLEET_CASES:
        out = run_eval(fleet(case))
        check(want in out.stdout + out.stderr, f"fleet {name}: rejected with \"{want}\" ({(out.stdout + out.stderr).strip()[-300:]})")
    out = run_eval(GITHUB % {"root": json.dumps(ROOT)})
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got.get("failing") == [], f"msi-ms7758 with an egress.github instance and a gh login fails no assertion ({got.get('failing', out.stderr.strip()[-600:])})")
    binds = got.get("binds", {})
    creds = {"/var/lib/host-credentials/id_ed25519", "/var/lib/host-credentials/gh-hosts.yml"}
    check(not creds & set(binds.get("gh", creds)) and "/run/egress" in binds.get("gh", []) and creds <= set(binds.get("plain", [])),
          f"an egress.github instance binds its egress directory and no GitHub credential; one without keeps both ({binds})")
    egress = got.get("egress", {})
    check(egress != {} and all(path == f"/run/dev-env-egress/{n}" for n, path in egress.items()),
          f"each instance's /run/egress is its own /run/dev-env-egress/<name> ({egress})")
    links = got.get("links", {})
    check(links.get("gh") == [] and links.get("gh2") == [] and links.get("plain"), f"only the guest without egress.github links id_ed25519 ({links})")
    caddy = got.get("caddy", "")
    sites = {b.split("\n", 2)[1].strip(): b for b in caddy.split("http:// {")[1:]}
    gh = sites.get("bind unix//run/dev-env-egress/gh/github.sock", "")
    want = [r"path_regexp ^/repos/(?i:o/r\.s)(/.*)?$", r"path_regexp ^/(?i:o/r\.s)(\.git)?/(info/refs|git-upload-pack|git-receive-pack)$",
            "@admin path_regexp (?i)^/repos/[^/]+/[^/]+/(rulesets|", "handle @admin {", "handle @odd {", "respond 403"]
    check(all(w in gh for w in want) and "x/y" not in gh, f"gh's GitHub site allows o/r.s alone, escaped and anchored, behind the admin and odd-URI denies ({[w for w in want if w not in gh]})")
    check("bind unix//run/dev-env-egress/plain/github.sock" not in sites and "/graphql" not in caddy and "bind unix//run/dev-env-egress/gh2/github.sock" in sites,
          f"no GitHub site for an instance without repos, no GraphQL unless asked for ({sorted(sites)})")
    check(got.get("config", "").startswith("/nix/store/") and "/run/secrets" not in caddy,
          f"the proxy's Caddyfile ({got.get('config')}) names no path under /run/secrets")

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
