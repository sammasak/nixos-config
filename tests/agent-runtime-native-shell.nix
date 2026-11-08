# devenv-platform#93, mode (a), in one QEMU VM: the native-shell template
# (modules/agent-runtime/templates/native-shell.nix) through the shipped instance lifecycle. The pinned
# repository's own devShell is realized on the host from its own flake.lock and only read by the
# instance; the repository's own gate runs inside it. Offline: no network, no nix daemon, no
# credential in the instance.
#   nix build .#packages.x86_64-linux.agent-runtime-native-shell-test
{ pkgs, lib, rfProto, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      ../modules/agent-runtime/templates/native-shell.nix
      {
        sam.agentRuntime.pinnedSources = { rf-proto = rfProto; inherit skills; };
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "native-shell" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
      }
    ];
  };
  tpl = evaluated.templates.native-shell;
  shell = (import ../modules/agent-runtime/native-shell.nix { inherit lib pkgs; }) { src = rfProto; };
  manifest = "${evaluated.manifestDir}/native-shell.json";
  I = lib.getExe runtime.tools.instance;
  run = lib.getExe (builtins.head tpl.packages);
  env = pkgs.buildEnv { name = "agent-runtime-native-shell-env"; paths = tpl.packages; };
  repo = tpl.repositories.rf-proto.path;
  # a disposable sentinel in the store the instance reads: it must stay unwritable and unchanged
  sentinel = pkgs.writeText "native-shell-sentinel" "sentinel #93\n";
  sh = pkgs.writeShellScript;

  # what the instance holds and what it is denied: the shell's tools only via its env file, the store
  # read-only, no nix, no daemon socket, no network, no root
  probe = sh "native-shell-probe" ''
    set -u
    fail=0
    chk() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fail=1; fi; }
    chk test -f ${repo}/flake.lock
    chk test "$(ls /sys/class/net)" = lo
    chk test "$(id -u)" != 0
    chk test ! -e /run/agent-runtime/credentials
    chk test ! -S /nix/var/nix/daemon-socket/socket
    if command -v nix >/dev/null 2>&1; then echo "FAIL nix on PATH"; fail=1; else echo "ok   no nix on PATH"; fi
    if command -v cargo >/dev/null 2>&1; then echo "FAIL cargo on PATH before the shell is sourced"; fail=1; else echo "ok   no cargo before the shell"; fi
    # the sentinel and the store: every write and remount is refused
    if (echo x >>${sentinel}) 2>/dev/null; then echo "FAIL wrote the sentinel"; fail=1; else echo "ok   sentinel append refused"; fi
    if touch /nix/store/native-shell-planted 2>/dev/null; then echo "FAIL created a store path"; fail=1; else echo "ok   store create refused"; fi
    if mount -o remount,rw /nix/store 2>/dev/null; then echo "FAIL remounted the store rw"; fail=1; else echo "ok   store remount refused"; fi
    if mount -o remount,rw / 2>/dev/null; then echo "FAIL remounted / rw"; fail=1; else echo "ok   root remount refused"; fi
    # shellcheck source=/dev/null
    . ${shell.env}
    chk test "$(command -v cargo)" != ""
    echo "shell cargo: $(cargo --version) at $(command -v cargo)"
    exit $fail
  '';
  # MODEL-FREE fixture, labelled as such: a broken source (a syntax error in lib.rs), then the runner.
  # The editing shell must still work (the tools answer), and the gate must fail on the source.
  broken = sh "native-shell-broken" ''
    set -u
    printf '\npub fn broken( {\n' >>${repo}/src/lib.rs
    . ${shell.env}
    cargo --version >"$AGENT_RUNTIME_OUTPUT/shell-still-works.txt" 2>&1 || { echo "the shell broke"; exit 90; }
    exec ${run}
  '';
  # Sample compiler process cgroups continuously while the transient unit exists. A separate
  # wait-for-pgrep followed by a second pgrep can miss a short-lived rustc process between calls.
  cgroupSampler = sh "native-shell-cgroup-sampler" ''
    set -u
    output=$1
    unit=$2
    deadline=$((SECONDS + 1200))
    unit_cgroup=
    : >"$output"
    while (( SECONDS < deadline )); do
      rel=$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null || true)
      if [ -n "$rel" ] && [ -d "/sys/fs/cgroup$rel" ]; then
        unit_cgroup="/sys/fs/cgroup$rel"
        break
      fi
      sleep 0.01
    done
    [ -n "$unit_cgroup" ] || { echo "unit cgroup did not appear: $unit" >&2; exit 1; }
    while [ -d "$unit_cgroup" ] && (( SECONDS < deadline )); do
      for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        IFS= read -r comm <"$comm_file" || continue
        case "$comm" in
          cargo|rustc|clippy-driver)
            pid=''${comm_file#/proc/}
            pid=''${pid%/comm}
            cgroups=$(cat "/proc/$pid/cgroup" 2>/dev/null) || continue
            printf '%s\t%s\t%s\n' "$comm" "$pid" "$cgroups" >>"$output"
            ;;
        esac
      done
      sleep 0.01
    done
    [ ! -d "$unit_cgroup" ] || { echo "unit cgroup outlived timeout: $unit" >&2; exit 1; }
    : >"$output.done"
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-native-shell";
  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 12288;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ rfProto skills env evaluated.manifestDir probe broken sentinel cgroupSampler ];
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq findutils ];
  };
  testScript = ''
    import json
    M = "${manifest}"
    POLICY = "${evaluated.hostPolicy}"
    V = "/var/lib/agent-runtime"
    TASK = "sammasak/devenv-platform#93"

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    def out(i, f):
        return machine.succeed(f"cat {V}/{i}/vol/output/{f}").strip()

    def steps(i):
        return [json.loads(l) for l in out(i, "steps.jsonl").splitlines()]

    def done(i):
        machine.succeed(f"${I} destroy {i} --discard")
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    store_before = int(machine.succeed("ls /nix/store | wc -l"))
    sentinel_sum = machine.succeed("sha256sum ${sentinel}").split()[0]
    print("shell provenance:", machine.succeed("cat ${shell.info}"))

    with subtest("the instance reads the host-realized shell; no nix, no socket, no network; store and sentinel unwritable"):
        machine.succeed(f"${I} create probe --template {M} --host {POLICY} --task {TASK}")
        machine.execute("${I} start probe --wait -- ${probe}")
        s = st("probe")
        print("probe:", json.dumps(s.get("result")))
        print(machine.succeed("journalctl -u agent-runtime-probe.service --no-pager -o cat | grep -E '^(ok|FAIL|shell cargo)' || true"))
        assert s["state"] == "succeeded", s
        done("probe")

    with subtest("the repository's own gate runs inside the instance with the pinned shell: cold then warm pass, all exit 0"):
        machine.succeed(f"${I} create gate --template {M} --host {POLICY} --task {TASK}")
        machine.succeed("rm -f /tmp/gate-cgroups.tsv /tmp/gate-cgroups.tsv.done; nohup ${cgroupSampler} /tmp/gate-cgroups.tsv agent-runtime-gate.service >/tmp/gate-cgroup-sampler.log 2>&1 </dev/null &")
        machine.succeed("${I} start gate -- ${run} --passes 2")
        machine.wait_until_succeeds("test -f /tmp/gate-cgroups.tsv.done", timeout=1200)
        samples = machine.succeed("cat /tmp/gate-cgroups.tsv").splitlines()
        print("build process cgroup samples:", sorted(set(samples)))
        assert samples and all("agent-runtime-gate.service" in line for line in samples), samples
        machine.wait_until_succeeds("${I} status gate | jq -e '.state | IN(\"succeeded\", \"failed\", \"timed-out\", \"oom-killed\")'", timeout=1100)
        s = st("gate")
        print("gate:", json.dumps(s.get("result")))
        for x in steps("gate"):
            print(f"  pass {x['pass']}: {' '.join(x['argv'])} -> exit {x['exit']} in {x['ms']} ms")
        print("versions:", out("gate", "versions.json"))
        print("volumes:", json.dumps({k: v for k, v in json.loads(out("gate", "result.json")).items() if k in ("usedMiB", "inodes")}))
        assert s["state"] == "succeeded", s
        assert len(steps("gate")) == 6 and all(x["exit"] == 0 for x in steps("gate")), steps("gate")
        assert json.loads(out("gate", "versions.json"))["cargoPath"].startswith("/nix/store/"), out("gate", "versions.json")
        assert json.loads(out("gate", "shell.json"))["source"]["rev"] == "${rfProto.rev}"
        machine.succeed("${I} export gate")
        done("gate")

    with subtest("a broken source: the editing shell still works and the gate fails on the source, not the shell"):
        machine.succeed(f"${I} create broken --template {M} --host {POLICY} --task {TASK}")
        machine.execute("${I} start broken --wait -- ${broken}")
        s = st("broken")
        print("broken:", json.dumps(s.get("result")))
        print("shell after the edit:", out("broken", "shell-still-works.txt"))
        for x in steps("broken"):
            print(f"  {' '.join(x['argv'])} -> exit {x['exit']}")
        assert s["state"] == "failed", s
        assert out("broken", "shell-still-works.txt").startswith("cargo "), out("broken", "shell-still-works.txt")
        assert all(x["exit"] != 0 for x in steps("broken")), steps("broken")
        machine.succeed("${I} export broken")
        export_dir = st("broken")["export"]["dir"]
        machine.succeed(f"grep -q 'pub fn broken' {export_dir}/sources/rf-proto.patch")
        done("broken")

    with subtest("clean teardown: no mounts, units or state; the store did not grow; the sentinel is unchanged"):
        machine.succeed("! findmnt -rn | grep -q agent-runtime")
        machine.succeed(f"test -z \"$(ls -A {V} | grep -v '^exports$')\"")
        store_after = int(machine.succeed("ls /nix/store | wc -l"))
        print("store paths before/after:", store_before, store_after)
        assert store_after == store_before, (store_before, store_after)
        assert machine.succeed("sha256sum ${sentinel}").split()[0] == sentinel_sum
  '';
}
