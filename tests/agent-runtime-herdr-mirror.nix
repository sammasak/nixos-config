# #169 option (b): the Herdr STATUS MIRROR. The credentialed coder run stays the direct root
# `agent-runtime-instance start --credential` (no pane, no new privilege); this proves it can be made
# to SHOW in Herdr through the shipped `agent-runtime-herdr` adapter alone, with a dummy token.
#
# What it proves, fail-closed:
#   - root writes a world-readable (0644) `mirror.status` holding only {state, outcome, reason};
#   - the mirror follower (the unprivileged Herdr user) maps it to Herdr: WORKING during the run,
#     IDLE (done) after a success, BLOCKED (with the non-secret reason) after a forced failure,
#     reading ONLY that file — never the instance tool (root), never sudo, never the credential;
#   - the credential is a SEPARATE 0400 file the unprivileged user cannot read;
#   - `deliver` to a mirror is REFUSED (exit 75) before any Herdr call: a mirror starts nothing;
#   - the dummy token appears in NO Herdr state, pane title, `herdr agent get`, mirror.status or log.
# Real herdr server and CLI, real systemd-nspawn, in QEMU only:
#   nix build .#packages.x86_64-linux.agent-runtime-herdr-mirror-test
{ pkgs, lib, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "mirror-probe" ];
          maxConcurrentInstances = 2;
          reserve = { memoryMiB = 256; diskMiB = 512; };
        };
        sam.agentRuntime.templates.mirror-probe = {
          role = { name = "mirror-probe"; harness = "claude-code"; };
          skillsSource = skills;
          skills.lean-code = { };
          packages = with pkgs; [ bash coreutils ];
          # small budgets: the default workspaceBudget (4096 MiB) would exceed the VM disk at admission,
          # and the default inode counts (100000/200000) will not fit mkfs.ext4 in these tiny images
          filesystem = {
            workspaceBudget = { sizeMiB = 64; inodes = 8000; };
            home = { sizeMiB = 16; inodes = 2000; };
            tmp = { sizeMiB = 16; inodes = 2000; };
            cache = { sizeMiB = 16; inodes = 2000; };
            output = { sizeMiB = 16; inodes = 2000; };
          };
          resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 5; };
        };
      }
    ];
  };
  tpl = evaluated.templates.mirror-probe;
  manifest = "${evaluated.manifestDir}/mirror-probe.json";
  I = lib.getExe runtime.tools.instance;
  adapter = import ../modules/agent-runtime/herdr { inherit pkgs; };
  env = pkgs.buildEnv { name = "mirror-probe-env"; paths = tpl.packages; };

  # benign payloads, run as the mapped unprivileged agent uid inside the instance; neither reads the
  # credential. The sleep gives a window to observe `working` before the outcome lands.
  okRun = pkgs.writeShellScript "mirror-ok" ''
    sleep 6
    echo "mirror ok run done"
  '';
  badRun = pkgs.writeShellScript "mirror-bad" ''
    sleep 2
    echo "mirror bad run failing"
    exit 1
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-herdr-mirror";
  nodes.machine = {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ skills env evaluated.manifestDir okRun badRun ];
    environment.systemPackages = with pkgs; [ herdr jq adapter procps util-linux gnugrep coreutils ];
    # an ordinary (non-root) account, to prove the mirror is world-readable and the credential is not
    users.users.mirror = { isNormalUser = true; };
    systemd.services.herdr = {
      description = "Herdr server of the physical host";
      environment = { HOME = "/root"; SHELL = "${pkgs.bash}/bin/bash"; };
      serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
    };
    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    import json

    M = "${manifest}"
    POLICY = "${evaluated.hostPolicy}"
    REF = "sammasak/nixos-config#169"
    TOKEN = "sk-ant-oat01-DUMMY-mirror-169-secret"

    def rec(i):
        return json.loads(machine.succeed(f"cat /var/lib/agent-runtime-herdr/{i}.json"))

    def pane(i):
        return rec(i)["herdr"]["pane_id"]

    def fg(i):
        return machine.succeed(
            f"herdr pane process-info --pane {pane(i)} | jq -r '.result.process_info.foreground_processes[0].cmdline // empty'"
        ).strip()

    def agent_get(i):
        return machine.succeed(f"herdr agent get {pane(i)} > /tmp/get.{i} 2>&1; cat /tmp/get.{i}")

    def hs(i):
        return json.loads(agent_get(i))["result"]["agent"]["agent_status"]

    def wait_hs(i, state, timeout=40):
        # Herdr reports an idle-but-unseen agent as `done`; both mean idle here
        want = '["idle","done"]' if state == "idle" else f'["{state}"]'
        try:
            machine.wait_until_succeeds(
                f"herdr agent get {pane(i)} | jq -e --argjson w '{want}' '.result.agent.agent_status as $s | $w | index($s)'",
                timeout=timeout,
            )
        except Exception:
            print(f"--- diagnose {i}", machine.execute(f"herdr agent get {pane(i)} 2>&1; cat /var/lib/agent-runtime-herdr/{i}.json; cat /run/agent-runtime/{i}/mirror.status 2>&1; journalctl -b -o cat -u agent-runtime-herdr-follow-{i} | tail -20")[1])
            raise

    machine.wait_for_unit("multi-user.target")
    machine.systemctl("start herdr.service")
    machine.wait_until_succeeds("herdr agent list", timeout=30)
    print("=== versions ===\n" + machine.succeed("herdr --version; uname -r"))
    # a dummy subscription token in the shape of the SOPS claude_oauth_token, nothing real
    machine.succeed(f"printf '%s' '{TOKEN}' > /root/dummy-token && chmod 600 /root/dummy-token")

    with subtest("mirror attach starts nothing; the direct root run shows working, then idle (done)"):
        machine.succeed(f"${I} create ok --template {M} --host {POLICY} --task {REF}")
        # attach the mirror BEFORE the start, pointing at the path root will write
        print(machine.succeed(f"agent-runtime-herdr attach ok {M} {REF} /run/agent-runtime/ok/mirror.status --mirror"))
        r = rec("ok")
        assert r["mirror"] is True, r
        # the pane foreground is the benign placeholder, NOT a run of the instance
        foreground = fg("ok")
        print("mirror pane foreground:", foreground)
        assert "sleep" in foreground, foreground
        assert "agent-runtime-instance" not in foreground and "agent-runtime-pane" not in foreground, foreground
        # with no mirror.status yet, Herdr shows the agent as unknown
        print("before the run:", hs("ok"))
        assert hs("ok") == "unknown", hs("ok")

        # the direct root start — the credential reaches the run ONLY here (tmpfs, 0400), never the mirror
        machine.succeed("${I} start ok --credential /root/dummy-token -- ${okRun}")
        wait_hs("ok", "working", 40)
        print("DURING the run, Herdr status:", hs("ok"), "| registry:", rec("ok")["status"])
        assert hs("ok") == "working"

        # the mirror file is world-readable; the credential is a SEPARATE 0400 file
        assert machine.succeed("stat -c %a /run/agent-runtime/ok/mirror.status").strip() == "644"
        assert machine.succeed("stat -c %a /run/agent-runtime/ok/cred/token").strip() == "400"
        mir = json.loads(machine.succeed("cat /run/agent-runtime/ok/mirror.status"))
        print("mirror.status during:", json.dumps(mir))
        assert set(mir) == {"state", "outcome", "reason"}, mir
        assert TOKEN not in machine.succeed("cat /run/agent-runtime/ok/mirror.status")
        # an UNPRIVILEGED user reads the mirror but CANNOT read the credential (absolute paths: su -c
        # need not inherit a PATH with jq/cat)
        mir_u = machine.succeed("su mirror -c '${pkgs.coreutils}/bin/cat /run/agent-runtime/ok/mirror.status'")
        assert json.loads(mir_u)["state"] in ("starting", "running"), mir_u
        rc, out = machine.execute("su mirror -c '${pkgs.coreutils}/bin/cat /run/agent-runtime/ok/cred/token' 2>&1")
        print("unprivileged read of the credential:", rc, out.strip())
        assert rc != 0, "the credential must not be readable by the unprivileged Herdr user"

        # the run ends; Herdr goes idle (done)
        machine.wait_until_succeeds("${I} status ok | jq -e '.state == \"succeeded\"'", timeout=60)
        wait_hs("ok", "idle", 40)
        print("AFTER a success, Herdr status:", hs("ok"))
        assert json.loads(machine.succeed("cat /run/agent-runtime/ok/mirror.status"))["state"] == "succeeded"

    with subtest("deliver to the mirror is refused before any Herdr call; nothing is started"):
        before = fg("ok")
        rc, out = machine.execute("agent-runtime-herdr deliver ok 'go run something' 2>&1")
        print("deliver to a mirror:", rc, out.strip())
        assert rc == 75 and "status mirror" in out and "not delivering" in out, (rc, out)
        # nothing was started: the pane still holds the placeholder, the instance is untouched
        assert fg("ok") == before, (before, fg("ok"))
        assert json.loads(machine.succeed("${I} status ok"))["state"] == "succeeded"

    with subtest("a forced failure shows blocked with its non-secret reason"):
        machine.succeed(f"${I} create bad --template {M} --host {POLICY} --task {REF}")
        print(machine.succeed(f"agent-runtime-herdr attach bad {M} {REF} /run/agent-runtime/bad/mirror.status --mirror"))
        machine.succeed("${I} start bad --credential /root/dummy-token -- ${badRun}")
        wait_hs("bad", "working", 40)
        print("DURING the failing run:", hs("bad"))
        machine.wait_until_succeeds("${I} status bad | jq -e '.state == \"failed\"'", timeout=60)
        wait_hs("bad", "blocked", 40)
        g = json.loads(agent_get("bad"))["result"]["agent"]
        print("AFTER a failure, Herdr agent:", json.dumps({k: g.get(k) for k in ("agent_status", "message")}))
        assert g["agent_status"] == "blocked"
        mir = json.loads(machine.succeed("cat /run/agent-runtime/bad/mirror.status"))
        print("mirror.status after failure:", json.dumps(mir))
        assert mir["state"] == "failed" and mir["reason"], mir

    with subtest("the dummy token appears in NO Herdr state, mirror.status, agent get, or run log"):
        # the Herdr state dir (registry records)
        machine.succeed(f"! grep -rqF -- '{TOKEN}' /var/lib/agent-runtime-herdr")
        for i in ("ok", "bad"):
            machine.succeed(f"! grep -qF -- '{TOKEN}' /run/agent-runtime/{i}/mirror.status")
            machine.succeed(f"herdr agent get {pane(i)} > /tmp/get.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/get.{i}")
            machine.succeed(f"herdr pane get {pane(i)} > /tmp/pget.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/pget.{i}")
            machine.succeed(f"${I} logs {i} > /tmp/log.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/log.{i}")
        machine.succeed("herdr agent list > /tmp/alist 2>&1")
        machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/alist")
        print("no token in: registry, both mirror.status, both agent get, both pane get, both logs, agent list")

    with subtest("teardown: the follower, the workspace and the instances leave nothing"):
        for i in ("ok", "bad"):
            print(machine.succeed(f"agent-runtime-herdr detach {i}"))
            machine.succeed(f"${I} destroy {i} --discard")
            machine.succeed(f"test ! -e /run/agent-runtime/{i}")
        machine.succeed("! herdr agent list | jq -e '.result.agents[] | select(.name | startswith(\"rt-\"))'")
        machine.succeed("! systemctl list-units --all --no-legend 'agent-runtime-herdr-follow-*' | grep -q .")
        statuses = machine.succeed("agent-runtime-herdr status --json | jq -r '[.[].status] | unique | join(\",\")'").strip()
        assert statuses == "torn_down", statuses
  '';
}
