"""The developer-environment core (modules/workers/core.nix) rejects a wrong configuration at evaluation: each case is
one small NixOS evaluation of only that module on a stub host. A valid host passes, and the agent's command line
survives quotes, backslashes and newlines through the guest's login shell (fish and bash)."""
import json
import os
import pathlib
import http.client
import re
import socket
import shutil
import subprocess
import sys
import tempfile
import time
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
    ("reserve above pool", '{ services.devEnvironments.instances.ok.memory.reserved = "9G"; }', "adds up to 9216M, more than pool.memory 8192M"),
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
    ("size syntax", '{ services.devEnvironments.instances.ok.memory.reserved = "6GB"; }', "instances.ok.memory.reserved' is not of type"),
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
  evalCache = builtins.filter (n: builtins.match ".*/eval-cache.*" n != null) (builtins.attrNames c.containers.t.bindMounts);
  nixDrv = g.nix.package.drvPath;
  gcroots = d c.systemd.services.dev-environments-gcroots.script;
  stateDir = c.services.devEnvironments.stateDir;
  alert = d (builtins.readFile c.services.devEnvironments.alert);
  onFailure = { container = c.systemd.services."container@t".onFailure; egress = c.systemd.services.dev-env-egress.onFailure or null; };
}
"""

# The two wrappers with stubs that print their argv in place of bwrap and crun (jq stays real): the store paths of both
SCRIPTS = r"""
let
  flake = builtins.getFlake (toString %(root)s);
  stub = pkgs: name: pkgs.writeShellScriptBin name ''printf '%%s\n' "$@"; echo "env:$BASH_ENV"'';
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
  live = base == with_ ({ lib, ... }: { services.devEnvironments.instances.ok = { memory.reserved = "1G"; cpu.reserved = 1; prompt = lib.mkForce "other"; }; });
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
# what a job in the guest can read of its limits, next to the host-side values they must equal
LIMITS = ('{ text = sys.config.containers.ok.config.environment.etc."dev-environment".text; '
          'swap = sys.config.systemd.slices.environments.sliceConfig.MemorySwapMax; inherit (sys.config.nix.settings) max-jobs cores; }')


def fleet(case, template=FLEET):
    return template % {"root": json.dumps(ROOT), "case": case}


# (method, path, allowed) against the repository o/r.s; allowed requests reach the dead upstream and fail with 502, the rest are 403
GITHUB_CASES = [
    ("GET", "/repos/o/r.s/pulls", True), ("HEAD", "/repos/o/r.s/issues", True), ("GET", "/repos/o/r.s/compare/main...feat/x", True),
    ("POST", "/repos/o/r.s/pulls", True), ("PATCH", "/repos/o/r.s/pulls/12", True), ("POST", "/repos/o/r.s/issues", True),
    ("POST", "/repos/o/r.s/issues/12/comments", True), ("PATCH", "/repos/o/r.s/issues/comments/99", True),
    ("POST", "/repos/o/r.s/issues/12/labels", True), ("POST", "/repos/o/r.s/pulls/12/requested_reviewers", True),
    ("GET", "/o/r.s/info/refs?service=git-receive-pack", True), ("POST", "/o/r.s.git/git-receive-pack", True),
    ("GET", "/repos/o/r.s/actions/secrets", False), ("GET", "/repos/o/r.s/./pulls", False), ("GET", "/repos/o/r.s/%2e%2e/pulls", False),
    ("GET", "/repos/o/other/pulls", False), ("PUT", "/repos/o/r.s/pulls/12/merge", False), ("POST", "/repos/o/r.s/merges", False),
    ("POST", "/repos/o/r.s/git/refs", False), ("PATCH", "/repos/o/r.s/git/refs/heads/main", False),
    ("DELETE", "/repos/o/r.s/git/refs/heads/main", False), ("PUT", "/repos/o/r.s/contents/x", False),
    ("DELETE", "/repos/o/r.s/contents/x", False), ("POST", "/repos/o/r.s/actions/workflows/ci.yml/dispatches", False),
    ("POST", "/repos/o/r.s/actions/runs/5/rerun", False), ("POST", "/repos/o/r.s/dispatches", False),
    ("POST", "/repos/o/r.s/releases", False), ("POST", "/repos/o/r.s/branches/main/rename", False),
    ("POST", "/repos/o/r.s/pulls/12/reviews", False), ("PUT", "/repos/o/r.s/pulls/12/update-branch", False),
    ("POST", "/repos/o/r.s/pages", False), ("DELETE", "/repos/o/r.s/issues/12", False), ("POST", "/graphql", False),
]


def check_github_proxy(site):
    """Runs the generated site of one instance in Caddy with its upstreams pointed at a closed port: no network is needed."""
    caddy = shutil.which("caddy")
    if caddy is None:
        check(False, "caddy is on PATH for the GitHub proxy behaviour test")
        return
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    body = site.split("\n", 2)[2]
    body = re.sub(r"https://(api\.)?github\.com", "http://127.0.0.1:1", body)
    with tempfile.TemporaryDirectory() as d:
        conf = pathlib.Path(d, "Caddyfile")
        conf.write_text("{\n admin off\n auto_https off\n}\nhttp://127.0.0.1:%d {\n%s" % (port, body))
        proc = subprocess.Popen([caddy, "run", "--adapter", "caddyfile", "--config", str(conf)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(50):
                try:
                    socket.create_connection(("127.0.0.1", port), 0.2).close()
                    break
                except OSError:
                    time.sleep(0.1)
            wrong = []
            for method, path, allowed in GITHUB_CASES:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request(method, path)
                status = conn.getresponse().status
                conn.close()
                if (status != 403) != allowed:
                    wrong.append(f"{method} {path} -> {status}")
            check(not wrong, f"the GitHub site lets agents do issue, comment, label and pull request work and git, and refuses merges, refs, contents, workflows, releases, reviews and dot segments ({wrong})")
        finally:
            proc.terminate()
            proc.wait(5)


def check_eval_cache(facts):
    """The directory the guests' Nix keeps its evaluation cache in is the one bound per instance."""
    real = subprocess.run(["nix-store", "--realise", facts.get("nixDrv", "")], capture_output=True, text=True)
    nix = next((o for o in real.stdout.split() if os.access(f"{o}/bin/nix", os.X_OK)), None) if real.returncode == 0 else None
    bound = [pathlib.PurePath(n).name for n in facts.get("evalCache", [])]
    with tempfile.TemporaryDirectory() as d:
        flake = pathlib.Path(d, "flake")
        flake.mkdir()
        flake.joinpath("flake.nix").write_text("{ outputs = _: { x = 1; }; }")
        env = {**os.environ, "HOME": d, "XDG_CACHE_HOME": f"{d}/cache"}
        run = subprocess.run([f"{nix}/bin/nix", "eval", "--extra-experimental-features", "nix-command flakes", f"path:{flake}#x"],
                             capture_output=True, text=True, env=env) if nix else None
        made = sorted(p.name for p in pathlib.Path(d, "cache", "nix").glob("eval-cache-v*")) if run and run.returncode == 0 else []
    check(made != [] and made == bound, f"the guests' Nix writes its evaluation cache to {made} and that directory is the one bound per instance ({bound})")


def check_gcroots(facts):
    """Runs the root refresh against a scratch state directory and roots."""
    store = pathlib.Path(os.path.realpath(shutil.which("bash") or "")).parents[1]
    if store.parent != pathlib.Path("/nix/store"):
        check(False, "a store path to root exists for the gcroots test")
        return
    with tempfile.TemporaryDirectory() as d:
        state, roots = pathlib.Path(d, "state"), pathlib.Path(d, "roots")
        script = facts["gcroots"].replace(facts["stateDir"], str(state)).replace("/nix/var/nix/gcroots/per-container", str(roots))
        gc = state / "n" / "home" / "proj" / ".devenv" / "gc"
        gc.mkdir(parents=True)
        (gc / "shell").symlink_to(store)
        stub = pathlib.Path(d, "stub")
        stub.mkdir()
        stub.joinpath("find").write_text("#!/bin/sh\nexit 1\n")
        stub.joinpath("find").chmod(0o755)
        (roots / "n").mkdir(parents=True)
        (roots / "n" / "home-stale").symlink_to(store)

        def refresh(path=os.environ["PATH"]):
            return subprocess.run(["bash", "-e", "-c", script], capture_output=True, text=True, env={**os.environ, "PATH": path})

        run = refresh()
        names = sorted(p.name for p in (roots / "n").iterdir())
        check(run.returncode == 0 and len(names) == 1 and names[0].startswith("home-") and names[0] != "home-stale"
              and (roots / "n" / names[0]).resolve() == store.resolve(),
              f"the root refresh adds a root for each devenv link and drops the stale one ({run.returncode}, {names}, {run.stderr.strip()[-200:]})")
        (roots / "n" / "home-stale").symlink_to(store)
        run = refresh(f"{stub}:{os.environ['PATH']}")
        check(run.returncode != 0 and (roots / "n" / "home-stale").is_symlink(),
              f"a scan that fails fails the refresh, and with it the garbage collection, and drops no root ({run.returncode})")
        check("find \"$home\" -ignore_readdir_race" in facts["gcroots"], "the scan ignores a directory a running guest deletes under it")


ACT = "{ inherit (sys.config.services.devEnvironments) stateDir; text = sys.config.system.activationScripts.devEnvironments.text; }"
RETIRED = '{ services.devEnvironments.retired = [ "gone" "live" "link" ]; }'
PAUSED_ONE = '{ services.devEnvironments.instances.idle.paused = true; }'
PAUSED = '{ services.devEnvironments.instances = { a = { }; b = { }; c.paused = true; d.paused = true; }; }'
PAUSED_FACTS = r"""{
  low = sys.config.systemd.slices.environments.sliceConfig.MemoryLow;
  containers = builtins.attrNames sys.config.containers;
  units = builtins.filter (n: builtins.match ".*[-@][cd](\\.service)?" n != null) (builtins.attrNames sys.config.systemd.services);
  declared = builtins.listToAttrs (map (n: { name = n; value = sys.config.systemd.services ? "${sys.config.services.devEnvironments.unitPrefix}-${n}"; }) [ "ok" "a" "b" "c" "d" ]);
}"""


def userns(*argv, **kw):
    return subprocess.run(["unshare", "-r", "--map-auto", *argv], capture_output=True, text=True,
                          env={**os.environ, "PATH": f"/run/wrappers/bin:{os.environ['PATH']}"}, **kw)


def activation_run(text, state, active=()):
    """Runs the activation script as the host runs it (an ERR trap marks a failed snippet, as /activate does) as root in
    a user namespace with the subuid range mapped, so the instance's user is a second uid that root-only directories
    shut out. Returns the exit status and a listing of what is under the state directory: path, mode, uid:gid."""
    stubs = pathlib.Path(state, "stubs")
    stubs.mkdir(exist_ok=True)
    stubs.joinpath("active").write_text("".join(f"container@{n}.service\n" for n in active))
    systemctl = stubs / "systemctl"
    systemctl.write_text(f'#!/bin/sh\ngrep -qx "$3" {stubs}/active\n')
    systemctl.chmod(0o755)
    text = re.sub(r"/nix/store/\S+/bin/systemctl", str(systemctl), text)
    text = text.replace("/nix/var/nix/profiles/per-container", f"{state}/profiles").replace("/nix/var/nix/gcroots/per-container", f"{state}/gcroots")
    text = re.sub(r"-o \S+ -g \S+", "-o 1000 -g 100", re.sub(r"chown -h \S+:\S+", "chown -h 1000:100", text))
    harness = f"_status=0; trap '_status=1' ERR; set -E\n{text}\nrc=$_status; cd {state}/files && find . -mindepth 1 -printf '%P %m %U:%G\\n' | sort; exit $rc"
    run = userns("bash", "-c", harness)
    return run.returncode, dict((line.split()[0], tuple(line.split()[1:])) for line in run.stdout.splitlines() if line), run.stderr


def check_activation():
    """The activation script, executed: a fresh host, a second run, a planted symlink, retired instances."""
    texts = {}
    for key, case in (("fresh", "{ }"), ("retired", RETIRED), ("paused", PAUSED_ONE)):
        out = nix_eval(case, ACT)
        texts[key] = json.loads(out.stdout) if out.returncode == 0 else None
        if texts[key] is None:
            check(False, f"the activation script evaluates ({out.stderr.strip()[-300:]})")
            return
    # what the script creates belongs to uids only the namespace can remove
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        os.chmod(tmp, 0o755)
        state = pathlib.Path(tmp, "state")
        try:

            def fresh_state():
                userns("rm", "-rf", str(state))
                (state / "files").mkdir(parents=True)
                return str(state / "files")

            def run(key, **kw):
                text = texts[key]["text"].replace(texts[key]["stateDir"], str(state / "files"))
                return activation_run(text, state, **kw)

            fresh_state()
            rc, tree, err = run("fresh")
            want = {"": None, ".nix-cache": ("700", "1000:100"), "ssh_host_ed25519_key": ("600", None), "known_hosts": ("644", None),
                    "ok": ("700", "0:0"), "ok/home": ("700", "1000:100"), "ok/home/.cache": ("755", "1000:100"), "ok/eval-cache": ("700", "1000:100")}
            bad = [p for p, w in want.items() if p and (p not in tree or any(x is not None and x != y for x, y in zip(w, tree[p])))]
            check(rc == 0 and not bad, f"a fresh host's activation exits 0 and leaves each directory with its mode and owner (rc {rc}, wrong {bad}, {err.strip()[-300:]})")
            rc2, tree2, err2 = run("fresh")
            check(rc2 == 0 and tree2 == tree, f"a second activation changes nothing and exits 0 (rc {rc2}, {err2.strip()[-300:]})")

            files = pathlib.Path(fresh_state())
            victim = pathlib.Path(tmp, "victim")
            victim.mkdir(mode=0o700)
            (files / "ok" / "home").mkdir(parents=True)
            (files / "ok" / "home" / ".cache").symlink_to(victim)
            before = victim.stat()
            rc, tree, err = run("fresh")
            after = victim.stat()
            check(rc == 0 and (before.st_mode, before.st_uid, before.st_gid) == (after.st_mode, after.st_uid, after.st_gid),
                  f"a ~/.cache symlink planted in the home leaves its target's mode and owner alone ({oct(before.st_mode)} to {oct(after.st_mode)}, rc {rc}, {err.strip()[-200:]})")

            files = pathlib.Path(fresh_state())
            for n in ("gone", "live", "kept"):
                (files / n / "home").mkdir(parents=True)
                (files / n / "home" / "work").write_text("unpushed")
                (state / "profiles" / n).mkdir(parents=True)
            (files / "link").symlink_to(victim)
            rc, tree, err = run("retired", active=["live"])
            trash = [p for p in tree if p.startswith(".trash/gone-") and p.count("/") == 1]
            check(rc == 0 and "gone" not in tree and len(trash) == 1 and (files / trash[0] / "home/work").read_text() == "unpushed"
                  and "live" in tree and "kept" in tree and (files / "link").is_symlink() and victim.is_dir()
                  and not (state / "profiles" / "gone").exists() and (state / "profiles" / "live").exists(),
                  f"a retired home moves to the trash and its profiles go, unless its container is active; a symlink is left (rc {rc}, {sorted(tree)}, {err.strip()[-200:]})")
            rc2, tree2, err2 = run("retired", active=["live"])
            check(rc2 == 0 and tree2 == tree, f"retiring again changes nothing and exits 0 (rc {rc2}, {err2.strip()[-200:]})")

            files = pathlib.Path(fresh_state())
            (files / "idle" / "home").mkdir(parents=True)
            (files / "idle" / "home" / "work").write_text("kept")
            (state / "profiles" / "idle").mkdir(parents=True)
            rc, tree, err = run("paused")
            check(rc == 0 and (files / "idle" / "home" / "work").exists() and (state / "profiles" / "idle").exists() and "idle/eval-cache" in tree,
                  f"a paused instance is not retired: its home and profiles stay and activation still prepares its directories (rc {rc}, {err.strip()[-200:]})")
        finally:
            userns("rm", "-rf", str(state))


ALERTS = (r'{ onFailure = sys.config.systemd.services."container@ok".onFailure; watch = sys.config.systemd.services ? dev-env-watch;'
          r' unit = sys.config.systemd.units."dev-env-alert@.service".text or null;'
          " script = sys.config.systemd.services.dev-env-watch.script or null; }")


def check_alerts(facts):
    """The units that fail into the alert program, and the watch script run against a fake counter, df and alert program."""
    check(facts.get("onFailure") == {"container": ["dev-env-alert@%n.service"], "egress": ["dev-env-alert@%n.service"]},
          f"a runtime host's container and egress units alert when they fail ({facts.get('onFailure')})")
    off = nix_eval("{ }", ALERTS)
    got = json.loads(off.stdout) if off.returncode == 0 else {}
    check(got.get("onFailure") == [] and got.get("watch") is False, f"with no alert program an instance has no OnFailure and no watch unit ({got})")
    on = nix_eval('{ services.devEnvironments.alert = "/alert"; }', ALERTS)
    got = json.loads(on.stdout) if on.returncode == 0 else {}
    check(got.get("onFailure") == ["dev-env-alert@%n.service"] and got.get("watch") is True, f"with one, the container unit alerts and the watch unit exists ({got})")
    # %I would unescape the unit name and read dev/env/egress.service
    check(re.search(r"^ExecStart=\S+ %i$", got.get("unit") or "", re.M) is not None, f"the alert unit is handed its instance with %i ({(got.get('unit') or '')[-200:]})")
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        for name, body in (("alert", 'echo "$1" >> "$0.log"; [ ! -e "$0.fail" ]'), ("df", '[ ! -e "$0.broken" ] || exit 1; printf "Avail\nG\n" | sed "s/G/$(cat "$0.free")G/"')):
            (d / name).write_text(f"#!/bin/sh\n{body}\n")
            (d / name).chmod(0o755)
        events = d / "memory.events"
        script = (got.get("script") or "").replace("/alert", str(d / "alert")).replace("/sys/fs/cgroup/environments.slice/memory.events", str(events))
        script = script.replace("/var/lib/dev-environments", str(d / "state"))
        (d / "state").mkdir()
        (d / "sd").mkdir()

        def watch(oom, free, fail=False, broken=False):
            events.write_text(f"low 0\nhigh 0\nmax 0\noom 0\noom_kill {oom}\n")
            (d / "df.free").write_text(str(free))
            for flag, on_ in (("alert.fail", fail), ("df.broken", broken)):
                (d / flag).unlink(missing_ok=True)
                if on_:
                    (d / flag).touch()
            log = d / "alert.log"
            log.unlink(missing_ok=True)
            run = subprocess.run(["bash", "-e", "-c", script], env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "STATE_DIRECTORY": str(d / "sd")}, capture_output=True, text=True)
            return run.returncode, log.read_text().splitlines() if log.exists() else []

        first, second, third = watch(3, 500), watch(3, 500), watch(5, 500)
        check(first == (0, []) and second == (0, []) and third[0] == 0 and len(third[1]) == 1 and "2 process(es)" in third[1][0],
              f"the watch script alerts once when oom_kill rises and not for a counter it has seen ({first}, {second}, {third})")
        lost = watch(9, 500, fail=True)
        retried = watch(9, 500)
        check(lost[0] != 0 and len(lost[1]) == 1 and retried[0] == 0 and len(retried[1]) == 1 and "4 process(es)" in retried[1][0],
              f"a failed send keeps the counter, so the next run sends it again ({lost}, {retried})")
        reset = watch(2, 500)
        check(reset[0] == 0 and len(reset[1]) == 1 and "2 process(es)" in reset[1][0], f"a counter that went down is read from zero ({reset})")
        low = watch(2, 4)
        again = watch(2, 4)
        check(low[0] == 0 and len(low[1]) == 2 and all("G free" in m for m in low[1]) and again == (0, []),
              f"a low disk alerts once an hour for the state directory and /nix ({low}, {again})")
        for marker in (d / "sd").glob("disk-*"):
            marker.unlink()
        failed = watch(2, 4, fail=True)
        check(failed[0] != 0 and len(failed[1]) == 2 and not list((d / "sd").glob("disk-*")),
              f"a failed disk alert does not skip the other directory and is retried ({failed})")
        for marker in (d / "sd").glob("disk-*"):
            marker.unlink()
        broken = watch(2, 4, broken=True)
        check(broken == (0, []), f"a df that fails raises no alert ({broken})")


def check_paused():
    """A paused instance has no container and no unit (a changed container unit that its declaration's removal stops
    fails the switch), and reserves nothing."""
    own = nix_eval(PAUSED, OWN)
    got = json.loads(own.stdout) if own.returncode == 0 else ["eval failed: " + own.stderr.strip()[-200:]]
    check(got == [], f"two paused instances leave the pool-fit assertion satisfied (5 declared, 3 active, 2G each, in 8G) ({got})")
    out = nix_eval(PAUSED, PAUSED_FACTS)
    facts = json.loads(out.stdout) if out.returncode == 0 else {}
    check(facts.get("low") == 3 * 2**31 and facts.get("containers") == ["a", "b", "ok"] and facts.get("units") == []
          and facts.get("declared") == {"ok": True, "a": True, "b": True, "c": False, "d": False},
          f"paused instances have no container, no unit of any kind, and leave the slice's MemoryLow ({facts or out.stderr.strip()[-300:]})")


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
        lines = run.stdout.splitlines()
        argv.env = lines.pop()[len("env:"):] if lines else ""
        return run.returncode, lines, run.stderr

    rc, got, _ = argv(exe["bwrap"], "--unshare-user", "--cap-drop", "ALL", "--proc", "/proc", "--dev", "/dev", "--", "make", "-j2")
    inner = got.index("--") if "--" in got else -1
    check(rc == 0 and got[:3] == ["--unshare-user", "--cap-drop", "ALL"] and got[3:5] == ["--uid", "0"] and "--proc" not in got
          and got[-2:] == ["make", "-j2"] and got[inner + 2:inner + 4] == ["-p", "-c"] and "subset=pid" in got[inner + 4]
          and "--no-new-privs" in got[inner + 4] and got[inner + 5] == "bash",
          f"bwrap-subset-proc rewrites Claude's shape: mapped root, the host /proc bound, a bash -p mount step before the command ({got})")
    remount = pathlib.Path(argv.env).read_text() if argv.env else ""
    check("subset=pid" in remount and "/proc/self/stat" in remount,
          f"the rewritten command's bash is given a BASH_ENV that remounts subset=pid for its own pid namespace ({argv.env})")
    rc, got, _ = argv(exe["bwrap"], "--unshare-user", "--proc", "/proc", "--dev", "/dev")
    check(rc == 0 and got == ["--unshare-user", "--proc", "/proc", "--dev", "/dev"] and argv.env == "",
          f"no separator after --proc: passed through unchanged, no BASH_ENV ({got})")
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
    prefetch([stub_expr("{ }"), stub_expr("{ }", GUEST), stub_expr("{ }", LIMITS), stub_expr("{ }", ALERTS), stub_expr('{ services.devEnvironments.alert = "/alert"; }', ALERTS), stub_expr("{ }", ACT), stub_expr(RETIRED, ACT), stub_expr(PAUSED_ONE, ACT), stub_expr(PAUSED, OWN), stub_expr(PAUSED, PAUSED_FACTS), stub_expr("{ }", DECLARATION), *(stub_expr(case, OWN) for _, case, _ in ASSERTED),
              fleet("{ }"), fleet(FLEET_INSTANCE, FLEET_FACTS), SCRIPTS % {"root": json.dumps(ROOT)}, *(fleet(case) for _, case, _ in FLEET_CASES),
              GITHUB % {"root": json.dumps(ROOT)}])
    out = nix_eval("{ }")
    check(out.returncode == 0 and json.loads(out.stdout) == [], f"a valid host fails no assertion ({out.stdout.strip() or out.stderr.strip()[-600:]})")
    out = nix_eval("{ }", GUEST)
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    check(got.get("channel") is False and len(got.get("nixPath", [])) == 1 and got["nixPath"][0].startswith("nixpkgs=/nix/store/")
          and got.get("registry") == "",
          f"a guest resolves <nixpkgs> to the store's nixpkgs, with no channels or global registry to fetch ({got or out.stderr.strip()[-300:]})")
    out = nix_eval("{ }", LIMITS)
    got = json.loads(out.stdout) if out.returncode == 0 else {}
    want = {"memory_reserved": str(2 << 30), "pool_memory": str(8 << 30), "pool_swap": str(got.get("swap")), "cpu_weight": "200",
            "nix_max_jobs": str(got.get("max-jobs")), "nix_cores": str(got.get("cores"))}
    have = dict(l.split("=", 1) for l in got.get("text", "").splitlines() if "=" in l)
    check(have == want, f"/etc/dev-environment gives the guest its reserve, the pool, its CPU weight and the build bounds ({have or out.stderr.strip()[-300:]})")
    check_activation()
    check_paused()
    blocked = '{ services.devEnvironments.blockedNetworks = [ "192.168.1.0/24" ]; networking.nftables.enable = lib.mkForce false; %s }'
    for v6, want in (("", True), ("networking.enableIPv6 = false;", False)):
        out = nix_eval(blocked % v6, "sys.config.networking.firewall.extraCommands")
        cmds = json.loads(out.stdout) if out.returncode == 0 else ""
        check(out.returncode == 0 and ("ip6tables -w -I INPUT -i ve-+ -j dev-env-input" in cmds and "ip6tables -w -I FORWARD -i ve-+ -j DROP" in cmds
              and "ip6tables -w -A dev-env-input -p ipv6-icmp -j RETURN" in cmds) == want and "iptables -w -I INPUT -i ve-+ -j dev-env-input" in cmds,
              f"blockedNetworks drops new IPv6 connections from the instance interfaces: {want} ({cmds[-200:] or out.stderr.strip()[-300:]})")
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
    check_alerts(facts)
    check_eval_cache(facts)
    check_gcroots(facts)
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
    check_github_proxy(gh)
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
