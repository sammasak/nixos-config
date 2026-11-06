# The #165 pilot template through the E2E path, in one QEMU VM: the template module acer-swift
# imports (modules/agent-runtime/templates/rust-pilot.nix), unchanged, with the shipped preflight,
# Herdr adapter and pane. The host policy is VM-sized (a reserve that fits a 5 GiB VM); acer-swift's
# own policy is pinned by `checks.agent-runtime-acer-pilot`. Real systemd-nspawn, a real herdr server,
# no network inside the instance, no credential.
#   nix build .#packages.x86_64-linux.agent-runtime-pilot-test
{ pkgs, lib, factum, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      ../modules/agent-runtime/templates/rust-pilot.nix
      {
        sam.agentRuntime.pinnedSources = { inherit factum skills; };
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "rust-pilot" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
      }
    ];
  };
  m = evaluated.manifestData.rust-pilot;
  manifest = "${evaluated.manifestDir}/rust-pilot.json";
  I = lib.getExe runtime.tools.instance;
  P = lib.getExe runtime.tools.preflight;
  pane = lib.getExe runtime.tools.pane;
  H = lib.getExe (import ../modules/agent-runtime/herdr { inherit pkgs; });
  env = pkgs.buildEnv { name = "agent-runtime-pilot-env"; paths = evaluated.templates.rust-pilot.packages; };
  run = lib.getExe (builtins.head evaluated.templates.rust-pilot.packages);
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-pilot";
  nodes.machine = {
    # the instance's 3 GiB cap plus the VM policy's reserve and the OS
    virtualisation.memorySize = 5120;
    virtualisation.cores = 2;
    # the five volumes (3.4 GiB) plus the reserve
    virtualisation.diskSize = 8192;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    # offline VM: the locked source, skills, packages and the manifest must already be in its store
    virtualisation.additionalPaths = [ factum skills env evaluated.manifestDir ];
    environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq herdr ];
    systemd.services.herdr = {
      description = "Herdr server of the host";
      environment = { HOME = "/root"; SHELL = "${pkgs.bash}/bin/bash"; };
      serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
    };
  };
  testScript = ''
    import json, time
    M = "${manifest}"
    POLICY = "${evaluated.hostPolicy}"
    V = "/var/lib/agent-runtime"
    TASK = "sammasak/nixos-config#165"

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    def clean(i):
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! losetup -l -n -O BACK-FILE | grep -q '{V}/{i}/'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"! machinectl list --no-legend | grep -q 'agent-runtime-{i} '")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    machine.systemctl("start herdr.service")
    machine.wait_until_succeeds("herdr agent list", timeout=30)
    print("template digest ${m.digests.template}; source factum ${factum.rev}")

    with subtest("preflight: go on a ready host, and a no-go names its check"):
        out = machine.succeed(f"${P} --host {POLICY} --template {M}")
        print(out)
        assert "preflight: go" in out and "FAIL" not in out, out
        machine.succeed("sysctl -w vm.panic_on_oom=2")
        rc, out = machine.execute(f"${P} --host {POLICY} --template {M}")
        machine.succeed("sysctl -w vm.panic_on_oom=0")
        print(out)
        assert rc == 1 and "FAIL panic-on-oom" in out and "preflight: NO-GO" in out, (rc, out)

    with subtest("pilot: create -> Herdr agent -> one handoff -> offline cargo test of factum -> export -> teardown clean"):
        t0 = time.monotonic_ns()
        machine.succeed(f"${I} create pilot --template {M} --host {POLICY} --task {TASK}")
        s = st("pilot")
        assert s["state"] == "created" and s["template"]["digests"]["template"] == "${m.digests.template}", s
        src = json.loads(machine.succeed(f"cat {V}/pilot/run/run.json"))
        assert src["sources"]["factum"]["resolved"]["rev"] == "${factum.rev}", src
        # once created, the reservation holds the only slot: the preflight is no-go on capacity, nothing runs yet
        rc, out = machine.execute(f"${P} --host {POLICY} --template {M}")
        assert rc == 1 and "FAIL capacity: 1 of 1" in out and "pilot" in out, (rc, out)
        machine.succeed(f"${H} attach pilot {M} {TASK} /tmp/pilot.status -- ${pane} pilot /tmp/pilot.status -- ${run}")
        machine.wait_until_succeeds("${H} status --json | jq -e '.[] | select(.runtime_id==\"pilot\" and .status==\"idle\")'", timeout=60)
        assert any(a.get("name") == "rt-pilot" for a in json.loads(machine.succeed("herdr agent list"))["result"]["agents"])
        machine.succeed("${H} deliver pilot 'run the assigned task'")
        machine.wait_until_succeeds("${I} status pilot | jq -e '.state | IN(\"running\", \"succeeded\", \"failed\")'", timeout=120)
        s = st("pilot")
        uid_base = s["uidBase"]
        assert uid_base >= 1048576 and s["started"]["uidMap"], s  # guest root is never host root
        machine.wait_until_succeeds("${I} status pilot | jq -e '.state != \"running\"'", timeout=3600)
        s = st("pilot")
        print(machine.succeed("${I} logs pilot")[-2500:])
        assert s["state"] == "succeeded" and s["result"]["exitStatus"] == 0, s
        measures = {"runtimeUSec": s["result"]["runtimeUSec"], "memoryPeakBytes": s["result"]["memoryPeakBytes"],
                    "startup_window": [s["createdAt"], s["started"]["startedAt"]]}
        print(machine.succeed("${I} export pilot"))
        b = f"{V}/exports/pilot"
        machine.succeed(f"cd {b}/output && sha256sum -c SHA256SUMS")
        result = json.loads(machine.succeed(f"cat {b}/output/result.json"))
        assert result["exit"] == 0 and result["rev"] == "${factum.rev}", result
        testlog = machine.succeed(f"cat {b}/output/cargo-test.log")
        # the lib tests: one test binary, every test passing (243 at this rev)
        assert "test result: FAILED" not in testlog and testlog.count("test result: ok") == 1, testlog[-2000:]
        passed = int(testlog.split("test result: ok. ")[1].split(" passed")[0])
        assert passed >= 200, testlog[-2000:]
        # the run changes no tracked file: the fixture lockfile it writes is gitignored, so the patch is empty
        patch = machine.succeed(f"cat {b}/sources/factum.patch")
        assert patch.strip() == "", patch[:2000]
        measures["usedMiB"] = result["usedMiB"]; measures["inodes"] = result["inodes"]; measures["tests_passed"] = passed
        machine.succeed("${H} detach pilot")
        machine.succeed("${I} destroy pilot --discard")
        clean("pilot")
        assert "rt-pilot" not in machine.succeed("herdr agent list")
        measures["total_ms"] = (time.monotonic_ns() - t0) // 1000000
        print("PILOT MEASURES", json.dumps(measures))

    with subtest("after the pilot: the preflight is go again, nothing of the instance left"):
        out = machine.succeed(f"${P} --host {POLICY} --template {M}")
        assert "preflight: go" in out, out
        machine.succeed(f"test -z \"$(ls -A {V} | grep -v '^exports$')\"")
  '';
}
