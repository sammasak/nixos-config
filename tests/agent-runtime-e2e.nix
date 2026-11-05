# M4 end-to-end pilot (#141): the whole user workflow composed from the merged pieces, in one QEMU VM.
# A typed template (#134) becomes an ephemeral nspawn instance (#135/#137) through the shipped
# agent-runtime-instance lifecycle (#138), is made a Herdr agent of the host by agent-runtime-herdr
# (#139), takes one handoff, runs real Rust work, exports, and tears down with nothing left; plus a
# failure matrix. Real systemd-nspawn and a real herdr server; no host switch.
# nix build .#packages.x86_64-linux.agent-runtime-e2e
{ pkgs, lib, rfProto, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "rust-worker" ];
          maxConcurrentInstances = 2;
          reserve = { memoryMiB = 1200; diskMiB = 256; };
        };
        sam.agentRuntime.templates.rust-worker = {
          role = { name = "rust-worker"; harness = "claude-code"; };
          repositories.rf-proto = {
            github = "sammasak/rf-proto";
            ref = { type = "commit"; value = rfProto.rev; };
            lock = rfProto;
            path = "/workspace/rf-proto";
            writable = true;
          };
          skillsSource = skills;
          skills.rust-engineering = { };
          packages = with pkgs; [ bash coreutils findutils gnugrep gawk util-linux glibc.bin cargo rustc gcc ];
          filesystem = {
            workspaceBudget = { sizeMiB = 256; inodes = 20000; };
            home = { sizeMiB = 64; inodes = 5000; };
            tmp = { sizeMiB = 128; inodes = 20000; };
            cache = { sizeMiB = 128; inodes = 20000; };
            output = { sizeMiB = 32; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 512; tasksMax = 512; timeoutMinutes = 30; };
        };
      }
    ];
  };
  hostPolicy = evaluated.hostPolicy;
  manifest = "${evaluated.manifestDir}/rust-worker.json";
  m = evaluated.manifestData.rust-worker;
  fs = m.filesystem;
  I = lib.getExe runtime.tools.instance;
  H = lib.getExe (import ../modules/agent-runtime/herdr { inherit pkgs; });
  env = pkgs.buildEnv { name = "agent-runtime-e2e-env"; paths = evaluated.templates.rust-worker.packages; };

  # Inside the instance (uid 1000, no caps): the real Rust work and the export contract.
  work = pkgs.writeShellScript "e2e-work" ''
    set -euo pipefail
    export PATH=${env}/bin HOME=${fs.home.path} TMPDIR=${fs.tmp.path} CARGO_HOME=${fs.cache.path}/cargo
    cd ${fs.workspace}/rf-proto
    cargo test --offline 2>&1 | tee ${fs.output.path}/cargo-test.log
    test "''${PIPESTATUS[0]}" = 0
    bin=$(find target/debug/deps -maxdepth 1 -type f -perm -u+x -name 'rf_proto-*' | head -1)
    cp "$bin" ${fs.output.path}/rf_proto-test
    cp /etc/agent-runtime/template.json ${fs.output.path}/template.json
    (cd ${fs.output.path} && sha256sum rf_proto-test template.json > SHA256SUMS)
  '';

  # The Herdr pane process: the runtime's host-side supervisor. It reports lifecycle through a status
  # file the adapter follows, waits for one handoff on its PTY, then drives the real instance to its
  # outcome. The payload runs in the container; this never holds a Herdr socket.
  pane = pkgs.writeShellScript "e2e-pane" ''
    set -uo pipefail
    export PATH=${pkgs.coreutils}/bin
    id=$1 sf=$2
    echo started >> "$sf"; echo idle >> "$sf"
    read -r handoff || true
    echo "handoff: $handoff" > /tmp/e2e-$id.handoff
    echo working >> "$sf"
    if ${I} start "$id" --wait -- ${work}; then echo finished >> "$sf"; else echo finished >> "$sf"; fi
  '';
  sleeper = pkgs.writeShellScript "e2e-sleeper" ''
    export PATH=${pkgs.coreutils}/bin; echo ready > ${fs.workspace}/ready; sleep 600
  '';
  # a fast payload that produces a verifiable output bundle without the full cargo build, for the
  # export-interruption case where the run itself is not what is under test
  lightwork = pkgs.writeShellScript "e2e-lightwork" ''
    set -euo pipefail
    export PATH=${pkgs.coreutils}/bin
    echo "e2e artifact" > ${fs.output.path}/result.txt
    (cd ${fs.output.path} && sha256sum result.txt > SHA256SUMS)
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-e2e";
  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    # the VM has no network: the locked source, the skills tree and the package closure must be in its
    # store so `create` can assign and materialize offline (the manifest only names them as strings)
    virtualisation.additionalPaths = [ rfProto skills env ];
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
    DIGEST = "${m.digests.template}"
    POLICY = "${hostPolicy}"
    V = "/var/lib/agent-runtime"

    def ist(i, *a):
        return machine.succeed(f"${I} {' '.join(a)} {i}" if a else f"${I} status {i}")

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    def create(i):
        machine.succeed(f"${I} create {i} --template {M} --host {POLICY} --task sammasak/rf-proto#1")

    def clean(i):
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! losetup -l -n -O BACK-FILE | grep -q '{V}/{i}/'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"! machinectl list --no-legend | grep -q 'agent-runtime-{i} '")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    machine.systemctl("start herdr.service")
    machine.wait_until_succeeds("herdr agent list", timeout=30)
    print("=== versions ==="); print(machine.succeed("uname -r; systemctl --version | head -1; herdr --version"))
    print(f"template digest {DIGEST}; source rf-proto ${rfProto.rev}")

    with subtest("E2E: create -> Herdr agent -> one handoff -> real cargo test -> export -> teardown clean"):
        t0 = time.monotonic_ns()
        create("e2e")
        s = st("e2e")
        # telemetry/correlation: the structured record carries runtime id, host, template digest, task, source commit
        assert s["state"] == "created" and s["id"] == "e2e" and s["host"], s
        assert s["template"]["digests"]["template"] == DIGEST, s
        assert s["task"] == "sammasak/rf-proto#1", s
        src = json.loads(machine.succeed(f"cat {V}/e2e/run/run.json"))
        assert src["sources"]["rf-proto"]["resolved"]["rev"] == "${rfProto.rev}", src
        # register as a Herdr agent of the host; the pane supervises the instance
        machine.succeed(f"${H} attach e2e {M} sammasak/rf-proto#1 /tmp/e2e.status -- ${pane} e2e /tmp/e2e.status")
        machine.wait_until_succeeds("${H} status --json | jq -e '.[] | select(.runtime_id==\"e2e\" and .status==\"idle\")'", timeout=60)
        agents = json.loads(machine.succeed("herdr agent list"))["result"]["agents"]
        rt = [a for a in agents if a.get("name") == "rt-e2e"]
        assert rt and "sammasak/rf-proto#1" in rt[0]["title"] and DIGEST[:12] in rt[0]["title"], agents
        reg = json.loads(machine.succeed("${H} status --json"))
        assert any(r["runtime_id"] == "e2e" and r["task_ref"] == "sammasak/rf-proto#1" for r in reg), reg
        # one handoff to the idle runtime drives the real run
        machine.succeed("${H} deliver e2e 'run the assigned task'")
        machine.wait_until_succeeds("test -f /tmp/e2e-e2e.handoff", timeout=30)
        machine.wait_until_succeeds("${I} status e2e | jq -e '.state == \"succeeded\"'", timeout=180)
        s = st("e2e")
        assert s["result"]["exitStatus"] == 0, s
        # metrics/telemetry: every correlation field, the startup window, the run cost and the peak are
        # recorded (journald + the status record; no new dashboard, see the runbook). OTel is not wired.
        assert s["createdAt"] and s["started"]["startedAt"] and s["uidBase"], s
        measures = {"startup_window": [s["createdAt"], s["started"]["startedAt"]],
                    "runtimeUSec": s["result"]["runtimeUSec"], "memPeakBytes": s["result"]["memoryPeakBytes"]}
        print("E2E outcome:", s["state"], "runtimeUSec", s["result"]["runtimeUSec"], "memPeak", s["result"]["memoryPeakBytes"])
        print(machine.succeed("${I} logs e2e")[-800:])
        # export: a verifiable bundle
        print(machine.succeed("${I} export e2e"))
        b = f"{V}/exports/e2e"
        machine.succeed(f"test -f {b}/output/rf_proto-test -a -f {b}/output/SHA256SUMS -a -f {b}/sources/rf-proto.patch -a -f {b}/bundle.json")
        machine.succeed(f"cd {b}/output && sha256sum -c SHA256SUMS")
        # teardown: Herdr, then the instance; nothing left in either. The cleanup result is recorded.
        tc = time.monotonic_ns()
        print(machine.succeed("${H} detach e2e"))
        machine.succeed("${I} destroy e2e --discard")
        clean("e2e")
        assert "rt-e2e" not in machine.succeed("herdr agent list")
        assert json.loads(machine.succeed("${H} status --json"))[0]["status"] == "torn_down"
        measures["cleanup"] = "clean"
        measures["cleanup_ms"] = (time.monotonic_ns() - tc) // 1000000
        measures["e2e_total_ms"] = (time.monotonic_ns() - t0) // 1000000

    with subtest("id bound: the Herdr adapter refuses an id longer than 29 (rt-<id> caps at 32)"):
        # The durable guarantee: any Herdr-visible runtime id is at most 29 chars, enforced by the adapter.
        # On this head the lifecycle tool itself still accepts up to 42; #155 (unmerged) narrows the
        # lifecycle bound to the same 29, after which an over-long `create` fails at the tool too.
        long = "r" + "0" * 29  # 30 chars
        create(long)
        rc, out = machine.execute(f"${H} attach {long} {M} sammasak/rf-proto#1 /tmp/l.status -- /bin/true 2>&1")
        print("adapter on a 30-char id:", rc, out.strip())
        assert rc == 64 and "at most 29" in out, (rc, out)
        machine.succeed(f"${I} destroy {long} --discard")
        clean(long)

    with subtest("failure: admission refuses a third instance over maxConcurrentInstances=2"):
        create("fa"); create("fb")
        machine.succeed("${I} start fa -- ${sleeper}")
        machine.succeed("${I} start fb -- ${sleeper}")
        machine.wait_until_succeeds(f"test -e {V}/fa/vol/workspace/workspace/ready -a -e {V}/fb/vol/workspace/workspace/ready", timeout=60)
        rc, out = machine.execute(f"${I} create fc --template {M} --host {POLICY} --task sammasak/rf-proto#1 2>&1")
        print("3rd create:", rc, out.strip()[-200:])
        assert rc == 10 and "instances 2 of 2 live" in out, (rc, out)
        machine.succeed(f"test ! -e {V}/fc")
        for i in ("fa", "fb"):
            machine.succeed(f"${I} cancel {i}; ${I} destroy {i} --discard")
            clean(i)

    with subtest("failure: kill mid-run is a failed outcome (signal), torn down clean, with a recovery bundle"):
        create("fk")
        machine.succeed("${I} start fk -- ${sleeper}")
        machine.wait_until_succeeds(f"test -e {V}/fk/vol/workspace/workspace/ready", timeout=60)
        machine.succeed("systemctl kill --signal=SIGKILL --kill-whom=all agent-runtime-fk.service || pkill -9 -f 'machine=agent-runtime-fk' || true")
        # the unit's ExecStopPost records the outcome, so a SIGKILL is a definite `failed` (signal), never
        # the `ambiguous` of a supervisor/host crash that leaves no outcome recorded
        machine.wait_until_succeeds("${I} status fk | jq -e '.state == \"failed\"'", timeout=60)
        s = st("fk")
        assert s["state"] == "failed" and s["result"]["serviceResult"] == "signal", s
        print("kill outcome:", s["state"], s["result"]["serviceResult"])
        print(machine.succeed("${I} export fk"))
        machine.succeed(f"test -f {V}/exports/fk/bundle.json")
        machine.succeed("${I} destroy fk"); clean("fk")

    with subtest("failure: Herdr down during deliver is refused (69); local status answers idle; nothing re-assigned"):
        create("fh")
        machine.succeed(f"${H} attach fh {M} sammasak/rf-proto#1 /tmp/fh.status -- ${pane} fh /tmp/fh.status")
        machine.wait_until_succeeds("${H} status --json | jq -e '.[] | select(.runtime_id==\"fh\" and .status==\"idle\")'", timeout=60)
        rec_before = json.loads(machine.succeed("${H} status --json | jq -c '.[] | select(.runtime_id==\"fh\")'"))
        deliveries_before = len(rec_before["deliveries"])
        machine.succeed("herdr server stop || systemctl stop herdr.service")
        machine.wait_until_fails("herdr agent list", timeout=20)
        rc, out = machine.execute("${H} deliver fh 'should not land' 2>&1")
        print("deliver with Herdr down:", rc, out.strip())
        assert rc == 69 and "unreachable" in out, (rc, out)  # the adapter's "herdr unreachable" exit
        rec_down = json.loads(machine.succeed("${H} status --json | jq -c '.[] | select(.runtime_id==\"fh\")'"))
        assert rec_down["status"] == "idle", rec_down  # the local registry answers idle with Herdr down
        assert len(rec_down["deliveries"]) == deliveries_before, rec_down  # nothing was assigned
        machine.systemctl("start herdr.service")
        machine.wait_until_succeeds("herdr agent list", timeout=30)
        machine.succeed("${H} reconcile")
        machine.succeed("${H} detach fh || true")
        machine.succeed("${I} cancel fh; ${I} destroy fh --discard"); clean("fh")

    with subtest("failure: a busy mount fails teardown (exit 1) and keeps the reservation; a second destroy releases it"):
        # a created (never-started) instance has its volumes mounted but no `starting` marker, so destroy
        # goes straight to teardown -- the export gate (conflict 12) never fires, and the busy umount is
        # the only thing that can fail. Holding its workspace mount open forces that path.
        create("ft")
        machine.succeed("${I} status ft | jq -e '.state == \"created\"'")
        machine.succeed(f"systemd-run --unit=ft-holder --property=Type=exec --working-directory={V}/ft/vol/workspace sleep 600")
        rc, out = machine.execute("${I} destroy ft 2>&1")
        print("destroy with a busy mount:", rc, out.strip()[-160:])
        assert rc == 1 and "is busy" in out, (rc, out)
        machine.succeed(f"test -e {V}/ft")  # the reservation (state dir) is kept, the instance stays counted
        machine.succeed("${I} status ft | jq -e '.state == \"created\"'")
        machine.succeed("systemctl stop ft-holder")
        machine.succeed("${I} destroy ft"); clean("ft")

    with subtest("failure: an interrupted export leaves no partial bundle; a clean re-export is verified"):
        create("fx")
        machine.succeed("${I} start fx --wait -- ${lightwork}")
        assert st("fx")["state"] == "succeeded", st("fx")
        # SIGKILL the export mid-run: the atomic mv into exports/<id> is the last step and never runs, so
        # there is no partial final bundle to serve. export writes to a temp dir first (mktemp .fx.XXXXXX).
        machine.execute("${I} export fx & p=$!; kill -9 $p 2>/dev/null; wait $p 2>/dev/null; true")
        machine.succeed(f"test ! -e {V}/exports/fx")  # the kill left no committed export
        # a clean re-export produces a verified bundle (export is recoverable: a fresh temp, a fresh commit)
        machine.succeed("${I} export fx")
        b = f"{V}/exports/fx"
        machine.succeed(f"test -f {b}/output/SHA256SUMS -a -f {b}/bundle.json")
        machine.succeed(f"cd {b}/output && sha256sum -c SHA256SUMS")
        machine.succeed("${I} destroy fx --discard"); clean("fx")

    with subtest("host unchanged, nothing of any instance left behind"):
        machine.succeed("test -z \"$(ls {V} 2>/dev/null | grep -v '^exports$' || true)\"")
        machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
        machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")
    print("=== measurements ==="); print(json.dumps(measures, indent=2))
  '';
}
