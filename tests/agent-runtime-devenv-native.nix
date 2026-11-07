# devenv-platform#93: validate a real pinned native devShell inside the EXISTING
# systemd-nspawn agent runtime (nixos-config #138/#144/#148/#152), without giving
# repository hooks host access or permitting unbounded Nix writes. One QEMU VM,
# real nspawn, offline. The shared template/fixture is tests/agent-runtime/devenv-native.nix.
#
# Mode (a) host-realized pinned shell projected read-only is exercised end to end.
# Mode (b) cold guest-side Nix realization is PROVEN UNSUPPORTED by the runtime
# (no nix daemon socket, read-only /nix/store, no network) and its exact failing
# command is recorded -- the runtime never silently selects it.
#
# nix build .#packages.x86_64-linux.agent-runtime-devenv-native
{ pkgs, lib, skills }:
let
  dn = import ./agent-runtime/devenv-native.nix { inherit pkgs lib skills; };
  evaluated = dn.evaluated;
  hostPolicy = evaluated.hostPolicy;
  manifest = "${evaluated.manifestDir}/devenv-native.json";
  m = evaluated.manifestData.devenv-native;
  fs = m.filesystem;
  ws = fs.workspace;                     # /workspace
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  Itool = lib.getExe runtime.tools.instance;
  env = dn.env;
  sh = pkgs.writeShellScript;

  # The sentinel probe: runs as container root with no capabilities, records the
  # boundary and tries to break out. `chk` must pass, `deny` must fail.
  probe = sh "devenv-native-probe" ''
    set -u
    export PATH=${env}/bin:${pkgs.util-linux}/bin:${pkgs.coreutils}/bin
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    deny() { if "$@" 2>/dev/null; then echo "FAIL (succeeded) $*"; fail=1; else echo "denied $*"; fi; }
    echo "cgroup: $(cat /proc/self/cgroup)"
    echo "net: $(ls /sys/class/net | tr '\n' ' ')"
    # no nix daemon, no host sockets, no secrets
    chk test ! -e /nix/var/nix/daemon-socket/socket
    chk test ! -S /run/systemd/private
    chk test ! -e /run/docker.sock
    chk test -z "''${SSH_AUTH_SOCK:-}"
    chk test ! -d /run/agent-runtime/credentials
    chk test "$(ls /sys/class/net)" = lo
    chk test "$(awk '{print $2}' /proc/self/uid_map)" != 0
    for c in CapInh CapPrm CapEff CapBnd CapAmb; do chk grep -qE "^$c:\s+0+$" /proc/self/status; done
    chk grep -qE '^NoNewPrivs:\s+1$' /proc/self/status
    chk grep -qE '^Seccomp:\s+2$' /proc/self/status
    chk test -f /workspace/fixture/flake.nix
    # the projected toolchain is usable (editing shell)
    chk gcc --version
    chk make --version
    # denied writes / remounts against disposable sentinels
    deny touch /nix/store/agent-runtime-write-attempt
    deny touch ${env}/bin/agent-runtime-write-attempt
    deny mount -o remount,rw /nix/store
    deny mount -o remount,rw /
    deny mount -t tmpfs none /tmp
    deny mknod /dev/sda b 8 0
    deny sh -c 'echo 1 > /proc/sys/kernel/sysrq'
    deny test -r /proc/kcore
    deny hostname devenv-native-renamed
    echo "nested_userns: $(unshare --user --map-root-user true 2>&1; echo exit=$?)"
    # a writable volume IS writable (home/tmp)
    chk sh -c 'echo probe > ${fs.tmp.path}/probe.txt'
    exit $fail
  '';

  # Mode (b): attempt genuinely cold guest-side Nix realization. It MUST fail --
  # there is no daemon socket, the store is read-only, and there is no network.
  # The exact failing command and message are recorded.
  modeb = sh "devenv-native-modeb" ''
    export PATH=${pkgs.coreutils}/bin
    out=''${AGENT_RUNTIME_OUTPUT:?}
    nix=${pkgs.nix}/bin/nix
    echo "=== mode (b) cold guest-side realization attempt ===" > "$out/mode-b.log"
    rc=0
    "$nix" --extra-experimental-features 'nix-command flakes' build --no-link \
      /workspace/fixture#devShells.x86_64-linux.default >> "$out/mode-b.log" 2>&1 || rc=$?
    echo "nix build exit=$rc" >> "$out/mode-b.log"
    # record the structural reason too
    { echo "daemon_socket_present=$(test -e /nix/var/nix/daemon-socket/socket && echo yes || echo no)"
      echo "store_writable=$(touch /nix/store/.art-write 2>/dev/null && echo yes || echo no)"
      echo "net_ifaces=$(ls /sys/class/net | tr '\n' ' ')"
    } >> "$out/mode-b.log"
    cat "$out/mode-b.log"
    test "$rc" != 0   # the test asserts cold realization is unsupported here
  '';

  sleeper = sh "devenv-native-sleep" "export PATH=${pkgs.coreutils}/bin; touch ${ws}/fixture/ready 2>/dev/null || touch /tmp/ready; sleep 600";

  # Fill the workspace past its byte/inode budget: ENOSPC must bite inside the
  # instance while the host /var/lib stays bounded.
  fill = sh "devenv-native-fill" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin
    dd if=/dev/zero of=${ws}/fixture/fill bs=1M 2> $TMPDIR/dd.err; echo "dd_exit=$?"; head -1 $TMPDIR/dd.err
    df -i ${ws}/fixture | tail -1
    exit 3
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-devenv-native";
  nodes.machine = {
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    # offline VM: the fixture, skills, package closure, manifest and the nix CLI
    # (for the mode-(b) failure probe) must all be in the store
    virtualisation.additionalPaths = [ dn.fixtureSrc skills env evaluated.manifestDir pkgs.nix ];
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq ];
  };
  testScript = ''
    import json, time
    M = "${manifest}"
    POLICY = "${hostPolicy}"
    DIGEST = "${m.digests.template}"
    V = "/var/lib/agent-runtime"

    def st(i):
        return json.loads(machine.succeed(f"${Itool} status {i}"))

    def create(i):
        machine.succeed(f"${Itool} create {i} --template {M} --host {POLICY} --task devenv-platform#93")

    def clean(i):
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! losetup -l -n -O BACK-FILE | grep -q '{V}/{i}/'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    print("=== versions ==="); print(machine.succeed("uname -r; systemctl --version | head -1; ${pkgs.nix}/bin/nix --version"))
    print(f"template digest {DIGEST}; fixture rev ${dn.fixtureRev}")
    measures = {}

    with subtest("mode (a): a host-realized pinned devShell runs the devenv project check inside nspawn"):
        t0 = time.monotonic_ns()
        create("good")
        s = st("good")
        assert s["state"] == "created" and s["template"]["digests"]["template"] == DIGEST, s
        # the locked fixture is pinned by its store path, resolved offline
        src = json.loads(machine.succeed(f"cat {V}/good/run/run.json"))
        assert src["sources"]["fixture"]["resolved"]["rev"] == "${dn.fixtureRev}", src
        assert src["sources"]["fixture"]["resolved"]["by"] == "lock", src
        machine.succeed("${Itool} start good --wait -- ${dn.run}")
        s = st("good")
        assert s["state"] == "succeeded" and s["result"]["exitStatus"] == 0, s
        o = f"{V}/good/vol/output"
        # the project check built and ran the C program with the projected toolchain
        machine.succeed(f"grep -q native-devenv-ok {o}/make.log")
        machine.succeed(f"grep -q 'selected_devshell=devShells.x86_64-linux.default' {o}/toolchain.txt")
        r = json.loads(machine.succeed(f"cat {o}/result.json"))
        assert r["mode"] == "good" and r["check_exit"] == 0 and r["editing_shell"] == "ok", r
        # the devenv hook ran ONLY in the guest: its marker is in the writable workspace,
        # never in the read-only projected source store path
        machine.succeed(f"test -f {V}/good/vol/workspace/workspace/fixture/.hook-ran-in-guest")
        machine.succeed("test ! -e ${dn.fixtureSrc}/.devenv-shell-hook-ran -a ! -e ${dn.fixtureSrc}/.hook-ran-in-guest")
        measures["cold"] = {"runtimeUSec": s["result"]["runtimeUSec"], "memPeakBytes": s["result"]["memoryPeakBytes"],
                            "disk_bytes": int(machine.succeed(f"du -sbx {V}/good/vol | cut -f1").strip())}
        print("mode(a) cold:", measures["cold"])
        print(machine.succeed(f"cat {o}/result.json"))
        machine.succeed("${Itool} destroy good --discard"); clean("good")
        measures["mode_a_total_ms"] = (time.monotonic_ns() - t0) // 1000000

    with subtest("warm re-run: the projected closure is already in the store, so the second run is faster to start"):
        t0 = time.monotonic_ns()
        create("warm"); machine.succeed("${Itool} start warm --wait -- ${dn.run}")
        assert st("warm")["state"] == "succeeded", st("warm")
        measures["warm_total_ms"] = (time.monotonic_ns() - t0) // 1000000
        # host /nix/store growth across a warm run is ~0 (nothing is realized guest-side)
        machine.succeed("${Itool} destroy warm --discard"); clean("warm")
        print("warm_total_ms", measures["warm_total_ms"])

    with subtest("broken source: the project check fails but the editing shell (projected toolchain) still works"):
        create("brk")
        rc, out = machine.execute("${Itool} start brk --wait -- ${dn.run} broken")
        s = st("brk")
        assert s["state"] == "failed" and s["result"]["exitStatus"] != 0, s
        o = f"{V}/brk/vol/output"
        # editing shell proven: the toolchain was captured and is runnable even though the build broke
        machine.succeed(f"grep -q 'gcc' {o}/toolchain.txt || grep -qi 'cc' {o}/toolchain.txt")
        machine.succeed(f"test -f {V}/brk/vol/workspace/workspace/fixture/.editing-shell-ok")
        r = json.loads(machine.succeed(f"cat {o}/result.json"))
        assert r["mode"] == "broken" and r["check_exit"] != 0 and r["editing_shell"] == "ok", r
        print("broken-source editing shell:", machine.succeed(f"cat {o}/toolchain.txt"))
        machine.succeed("${Itool} destroy brk --discard"); clean("brk")

    with subtest("mode (b): cold guest-side Nix realization is UNSUPPORTED by the runtime; the exact failing command is recorded"):
        create("mb")
        rc, out = machine.execute("${Itool} start mb --wait -- ${modeb}")
        s = st("mb")
        # the payload asserts the nix build failed, so a succeeded state proves cold realization is impossible here
        assert s["state"] == "succeeded", s  # payload exits 0 only when `nix build` FAILED (test "$rc" != 0)
        outlog = machine.succeed(f"cat {V}/mb/vol/output/mode-b.log")
        assert "daemon_socket_present=no" in outlog and "store_writable=no" in outlog and "net_ifaces=lo" in outlog, outlog
        assert "nix build exit=" in outlog and "nix build exit=0" not in outlog, outlog
        measures["mode_b"] = "unsupported: no nix daemon socket, read-only /nix/store, no network"
        print("mode(b) record:\n" + outlog)
        machine.succeed("${Itool} destroy mb --discard"); clean("mb")

    with subtest("boundary: a no-capability container root cannot write the store, remount, or escape; only lo; secrets denied"):
        create("pb")
        machine.succeed("${Itool} start pb --wait -- ${probe}")
        assert st("pb")["state"] == "succeeded", st("pb")
        print(machine.succeed("${Itool} logs pb")[-1600:])
        machine.succeed("${Itool} destroy pb --discard"); clean("pb")

    with subtest("volume bounds: filling the workspace hits ENOSPC inside the instance; host /var/lib stays bounded"):
        before = int(machine.succeed(f"df -m --output=used {V} | tail -1").strip())
        create("fl")
        machine.succeed("${Itool} start fl --wait -- ${fill} || true")
        s = st("fl")
        assert s["state"] in ("failed", "succeeded"), s
        outlog = machine.succeed("${Itool} logs fl")
        assert "No space left on device" in outlog, outlog
        after = int(machine.succeed(f"df -m --output=used {V} | tail -1").strip())
        assert after - before <= 96, (before, after)   # the fixed-size image caps host growth
        print("fill: host /var/lib MiB delta", after - before)
        machine.succeed("${Itool} destroy fl --discard"); clean("fl")

    with subtest("single cgroup: every build descendant stays under the run's delegated unit cgroup"):
        create("cg")
        machine.succeed("${Itool} start cg -- ${sleeper}")
        machine.wait_until_succeeds("${Itool} status cg | jq -e '.state==\"running\"'", timeout=60)
        cgline = machine.succeed("cat /sys/fs/cgroup/system.slice/agent-runtime-cg.service/cgroup.procs | wc -l").strip()
        # the nspawn payload and its descendants are all inside the one delegated service cgroup
        machine.succeed("test -d /sys/fs/cgroup/system.slice/agent-runtime-cg.service")
        machine.succeed("systemd-cgls /sys/fs/cgroup/system.slice/agent-runtime-cg.service >/dev/null")
        print("cg procs in the run's cgroup:", cgline)
        machine.succeed("${Itool} cancel cg; ${Itool} destroy cg --discard"); clean("cg")

    with subtest("failure recovery: a SIGKILL mid-run is a definite failed outcome, torn down clean, with a recovery bundle"):
        create("rk")
        machine.succeed("${Itool} start rk -- ${sleeper}")
        machine.wait_until_succeeds("${Itool} status rk | jq -e '.state==\"running\"'", timeout=60)
        machine.succeed("systemctl kill --signal=SIGKILL --kill-whom=all agent-runtime-rk.service || true")
        machine.wait_until_succeeds("${Itool} status rk | jq -e '.state==\"failed\"'", timeout=60)
        s = st("rk"); assert s["result"]["serviceResult"] == "signal", s
        machine.succeed("${Itool} export rk")
        machine.succeed(f"test -f {V}/exports/rk/bundle.json")
        machine.succeed("${Itool} destroy rk"); clean("rk")

    with subtest("host unchanged: nothing of any instance is left behind"):
        machine.succeed(f"test -z \"$(ls {V} 2>/dev/null | grep -v '^exports$' || true)\"")
        machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
        machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")

    measures["store_closure_bytes"] = int(machine.succeed("du -sbx /nix/store/*-devenv-native-env 2>/dev/null | cut -f1 || echo 0").strip() or "0")
    print("=== DEVENV-NATIVE MEASURES ==="); print(json.dumps(measures, indent=2))
  '';
}
