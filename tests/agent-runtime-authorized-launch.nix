# #170: the authorized-launch wrapper through the real sudo path, in one QEMU VM. A tiny,
# offline, credential-free template (a `true`-like probe) is created, then started as root by
# a non-root coordinator through `sudo agent-runtime-authorized-start <id>` and nothing wider.
# Proves the narrowing: the wrapper starts only a created, eligible, digest-matched instance
# with its OWN manifest entrypoint, and a start-level payload the coordinator might pass is not
# in sudoers at all. Offline: the closure is shipped into the VM.
#   nix build .#packages.x86_64-linux.agent-runtime-authorized-launch-test
{ pkgs, lib, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  # the entrypoint the manifest declares (first package): touch a marker and exit 0
  probe = pkgs.writeShellScriptBin "agent-launch-probe" ''
    touch "$AGENT_RUNTIME_OUTPUT/launched"
    echo "authorized-launch probe ran as $(id -u):$(id -g)"
  '';
  # a run that stays up until cancelled: marks that it started, then sleeps past any test step
  slowProbe = pkgs.writeShellScriptBin "agent-launch-slow" ''
    touch "$AGENT_RUNTIME_OUTPUT/started"
    sleep 600
    touch "$AGENT_RUNTIME_OUTPUT/finished"
  '';
  template = entry: {
    role = { name = "quality"; harness = "codex"; };
    skillsSource = skills;
    skills.lean-code = { };
    packages = [ entry pkgs.bash pkgs.coreutils ];
    filesystem = {
      workspaceBudget = { sizeMiB = 16; inodes = 1000; };
      home = { sizeMiB = 16; inodes = 1000; };
      tmp = { sizeMiB = 16; inodes = 1000; };
      cache = { sizeMiB = 16; inodes = 1000; };
      output = { sizeMiB = 16; inodes = 1000; };
    };
    resources = { cpus = 1; memoryMiB = 64; tasksMax = 64; timeoutMinutes = 5; };
  };
  tiny = template probe;
  slow = template slowProbe;
  # host policy and templates, shared by the standalone manifest eval (for the shipped closure)
  # and the node config (which also enables authorizedLaunch through the real module).
  baseRt = {
    sam.agentRuntime = {
      host = {
        enable = true;
        eligibleTemplates = [ "tiny" "slow" ];
        maxConcurrentInstances = 1;
        reserve = { memoryMiB = 256; diskMiB = 512; };
      };
      templates = { inherit tiny slow; };
    };
  };
  evaluated = runtime.evalManifests { modules = [ baseRt ]; };
  m = evaluated.manifestData.tiny;
  M = "${evaluated.manifestDir}/tiny.json";
  MS = "${evaluated.manifestDir}/slow.json";
  env = pkgs.buildEnv {
    name = "agent-runtime-authorized-launch-env";
    paths = evaluated.templates.tiny.packages ++ evaluated.templates.slow.packages;
  };
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-authorized-launch";
  nodes.machine = {
    imports = [ ../modules/agent-runtime/host.nix baseRt ];
    sam.agentRuntime.authorizedLaunch = {
      enable = true;
      user = "coordinator";
    };
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    # offline VM: skills, the template packages (the entrypoint) and the manifest must be in its store
    virtualisation.additionalPaths = [ skills env evaluated.manifestDir ];
    users.users.coordinator = { isNormalUser = true; };
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq ];
  };
  testScript = ''
    import json

    M = "${M}"
    MS = "${MS}"
    HOST = "/etc/agent-runtime/host.json"
    V = "/var/lib/agent-runtime"
    SENTINEL = "/etc/agent-runtime-host-sentinel"

    machine.wait_for_unit("multi-user.target")
    print("template digest ${m.digests.template}; entrypoint ${m.entrypoint}")

    # the exact store paths the system installed: W is the one sudoers command, I is NOT granted
    W = machine.succeed("readlink -f $(command -v agent-runtime-authorized-start)").strip()
    I = machine.succeed("readlink -f $(command -v agent-runtime-instance)").strip()
    print("wrapper", W, "\ninstance", I)
    machine.succeed(f"echo untouched > {SENTINEL}")

    def st(i):
        return json.loads(machine.succeed(f"{I} status {i}"))

    def coord(cmd):
        # the coordinator user, non-interactive sudo: NOPASSWD only for the wrapper's exact path
        return f"runuser -u coordinator -- sudo -n {cmd}"

    # config drift: what the host trusts, hashed before every subtest and compared after the last
    def trusted():
        return machine.succeed(
            f"readlink -f {HOST}; sha256sum $(readlink -f {HOST}) /etc/sudoers {M} {MS} {W} {I}"
        )
    before = trusted()

    def clean(i):
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    with subtest("least privilege: the coordinator's sudo grants exactly the wrapper, nothing else"):
        listing = machine.succeed("runuser -u coordinator -- sudo -n -l")
        granted = [l.strip() for l in listing.splitlines() if l.strip().startswith("(")]
        assert granted == [f"(root) NOPASSWD: {W}"], listing
        machine.fail("id -nG coordinator | grep -qw wheel")
        # as root only: the wrapper as another user or group is not granted
        for runas in ["-u nobody", "-u coordinator", "-g wheel"]:
            rc, out = machine.execute(f"runuser -u coordinator -- sudo -n {runas} {W} good")
            assert rc != 0, (runas, rc, out)
        for cmd in [f"{I} status good", f"{I} create x --template {M} --host {HOST} --task t-x",
                    "true", "/bin/sh -c id", f"{I} cancel good", f"{I} destroy good --discard"]:
            rc, out = machine.execute(coord(cmd))
            assert rc != 0, (cmd, rc, out)
        machine.succeed(f"test ! -e {V}/x")

    with subtest("valid: the wrapper starts a created, eligible instance and it succeeds"):
        machine.succeed(f"{I} create good --template {M} --host {HOST} --task sammasak/nixos-config#170")
        assert st("good")["state"] == "created", st("good")
        out = machine.succeed(coord(f"{W} good"))
        print(out)
        assert '"decision":"authorized"' in out, out
        assert st("good")["state"] == "succeeded", st("good")
        # the payload was the manifest entrypoint: its marker landed in the output volume
        machine.succeed(f"test -f {V}/good/vol/output/launched")
        machine.succeed(f"{I} destroy good --discard")
        clean("good")

    with subtest("no payload injection: a start-level sudo command is simply not granted"):
        machine.succeed(f"{I} create inj --template {M} --host {HOST} --task t-inj")
        rc, out = machine.execute(coord(f"{I} start inj -- /bin/sh -c 'touch /host-pwned'"))
        assert rc != 0, (rc, out)
        machine.succeed("test ! -e /host-pwned")
        assert st("inj")["state"] == "created", st("inj")
        machine.succeed(f"{I} destroy inj --discard")
        clean("inj")

    with subtest("forged id: a non-existent id and a path-escape id both refuse, starting nothing"):
        rc, out = machine.execute(coord(f"{W} no-such-id"))
        assert rc != 0 and '"decision":"refused"' in out, (rc, out)
        rc, out = machine.execute(coord(f"{W} ../escape"))
        assert rc != 0, (rc, out)

    with subtest("stale approval: a template made non-eligible after create is refused"):
        machine.succeed(f"{I} create stale --template {M} --host {HOST} --task t-stale")
        orig = machine.succeed(f"readlink -f {HOST}").strip()
        machine.succeed(f"jq '.eligibleTemplates = []' {orig} > /tmp/noelig.json")
        machine.succeed(f"rm {HOST} && cp /tmp/noelig.json {HOST}")
        rc, out = machine.execute(coord(f"{W} stale"))
        machine.succeed(f"rm {HOST} && ln -s {orig} {HOST}")
        assert rc != 0 and "not eligible" in out, (rc, out)
        assert st("stale")["state"] == "created", st("stale")
        machine.succeed(f"{I} destroy stale --discard")
        clean("stale")

    with subtest("forged approval: a tampered recorded digest no longer matches the manifest"):
        machine.succeed(f"{I} create forge --template {M} --host {HOST} --task t-forge")
        machine.succeed(f"jq '.template.digests.template = \"{'0' * 64}\"' {V}/forge/instance.json > /tmp/forge.json")
        machine.succeed(f"cp /tmp/forge.json {V}/forge/instance.json")
        rc, out = machine.execute(coord(f"{W} forge"))
        assert rc != 0 and "do not match" in out, (rc, out)
        assert st("forge")["state"] == "created", st("forge")
        machine.succeed(f"{I} destroy forge --discard")
        clean("forge")

    with subtest("duplicate idempotent: a second wrapper run starts nothing and exits 0"):
        machine.succeed(f"{I} create dup --template {M} --host {HOST} --task t-dup")
        machine.succeed(coord(f"{W} dup"))
        s1 = st("dup")
        assert s1["state"] == "succeeded", s1
        inv = s1["started"]["invocation"]
        out = machine.succeed(coord(f"{W} dup"))
        assert '"decision":"noop"' in out, out
        s2 = st("dup")
        assert s2["started"]["invocation"] == inv, (s1, s2)
        machine.succeed(f"{I} destroy dup --discard")
        clean("dup")

    with subtest("cancellation: root cancels a wrapper-started run; it is cleaned up and never re-started"):
        machine.succeed(f"{I} create slow --template {MS} --host {HOST} --task t-slow")
        # the coordinator's sudo call blocks for the run (--wait); run it detached and keep its exit code
        machine.succeed(
            "systemd-run --unit=coord-slow --property=RemainAfterExit=yes --property=Type=exec "
            "--setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin "
            f"sh -c '{coord(W + ' slow')} >/tmp/slow.out 2>&1; echo $? >/tmp/slow.rc'"
        )
        machine.wait_until_succeeds(
            f"{I} status slow | jq -e '.state == \"running\"' || test -s /tmp/slow.rc", timeout=120)
        print(machine.succeed("cat /tmp/slow.out /tmp/slow.rc 2>/dev/null || true"))
        assert st("slow")["state"] == "running", (st("slow"), machine.succeed(f"{I} logs slow || true"))
        machine.wait_until_succeeds(f"test -f {V}/slow/vol/output/started", timeout=60)
        machine.succeed(f"{I} cancel slow")
        machine.wait_until_succeeds("test -s /tmp/slow.rc", timeout=120)
        rc = int(machine.succeed("cat /tmp/slow.rc").strip())
        assert rc != 0, (rc, machine.succeed("cat /tmp/slow.out"))
        assert st("slow")["state"] == "cancelled", st("slow")
        machine.succeed(f"test ! -e {V}/slow/vol/output/finished")
        # the cancelled run is acted on: a second wrapper call is a no-op, it never restarts it
        out = machine.succeed(coord(f"{W} slow"))
        assert '"decision":"noop"' in out, out
        assert st("slow")["state"] == "cancelled", st("slow")
        machine.succeed(f"{I} destroy slow --discard")
        clean("slow")

    with subtest("audit: every decision is in the journal, not only the caller's stdout"):
        lines = machine.succeed("journalctl -b -t agent-runtime-authorized-start -o cat").splitlines()
        seen = {(r["id"], r["decision"]) for r in map(json.loads, lines)}
        for want in [("good", "authorized"), ("stale", "refused"), ("forge", "refused"),
                     ("dup", "authorized"), ("dup", "noop"), ("slow", "authorized"), ("slow", "noop")]:
            assert want in seen, (want, sorted(seen))

    with subtest("no config drift: host policy, sudoers, manifests and tools are as installed"):
        assert trusted() == before, (before, trusted())

    with subtest("cleanup: no instance is left and the host sentinel is untouched"):
        machine.succeed(f"test -z \"$(ls -A {V} 2>/dev/null | grep -v '^exports$' || true)\"")
        assert machine.succeed(f"cat {SENTINEL}").strip() == "untouched"
  '';
}
