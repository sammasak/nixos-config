# #186 fleet-level proof: the Lenovo coordinator sees every active isolated runtime on two
# worker hosts (acer + msi analogues) through saved Herdr machines, read-only, with the five
# fields host + runtime_id + GitHub task + template + state (+ non-secret blocked reason). It
# reuses the shipped agent-runtime-herdr adapter and status mirror and the saved-machine path
# proven in agent-runtime-herdr-machines-test -- no new service, scheduler, dashboard or poller.
# It proves: two runtimes that share the instance id `coder` are told apart by host; a
# launcher-started runtime (status mirror, not a pane launch) shows with its blocked reason and
# its working/idle transitions; a host outside its power window is an offline error row, not a
# vanished runtime or a false idle; a Herdr restart reconciles; teardown leaves nothing. In QEMU:
# nix build .#packages.x86_64-linux.agent-runtime-herdr-fleet-test
{ pkgs, lib, skills, registration }:
let
  inherit (import ./agent-runtime-herdr-fixture.nix { inherit pkgs lib skills; })
    evaluated adapter launch prepare destroy;
  runtime = import ../modules/agent-runtime/lib.nix { inherit pkgs lib; };
  probe = pkgs.writeShellScriptBin "fleet-mirror-probe" ''
    touch "$AGENT_RUNTIME_OUTPUT/started"
    while [ ! -e "$AGENT_RUNTIME_OUTPUT/finish" ]; do sleep 0.2; done
    test ! -e "$AGENT_RUNTIME_OUTPUT/fail"
  '';
  mirrorConfig.sam.agentRuntime = {
    host = {
      enable = true;
      eligibleTemplates = [ "mirror-probe" ];
      maxConcurrentInstances = 2;
      reserve = { memoryMiB = 256; diskMiB = 512; };
    };
    templates.mirror-probe = {
      role = { name = "mirror-probe"; harness = "codex"; };
      skillsSource = skills;
      skills.lean-code = { };
      packages = [ probe pkgs.bash pkgs.coreutils ];
      filesystem = {
        workspaceBudget = { sizeMiB = 16; inodes = 1000; };
        home = { sizeMiB = 16; inodes = 1000; };
        tmp = { sizeMiB = 16; inodes = 1000; };
        cache = { sizeMiB = 16; inodes = 1000; };
        output = { sizeMiB = 16; inodes = 1000; };
      };
      resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 5; };
    };
  };
  mirror = runtime.evalManifests { modules = [ mirrorConfig ]; };
  mirrorEnv = pkgs.buildEnv { name = "fleet-mirror-env"; paths = mirror.templates.mirror-probe.packages; };
  taskConfig = lib.evalModules {
    modules = [
      { options.tasks = lib.mkOption { type = lib.types.attrsOf lib.types.anything; }; }
      "${skills}/task-modules/herdr.nix"
      { coordinator = { stateDir = "/tmp/fleet-coordinator"; timeoutSeconds = 5; }; }
    ];
  };
  # Execute the production task body, without installing devenv inside the disposable VM.
  inventory = pkgs.writeShellScript "fleet-inventory" taskConfig.config.tasks."herdr:inventory".exec;
  register = pkgs.writeShellScript "fleet-register" ''
    run() { "$@"; }
    ${registration}
  '';
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs) snakeOilPrivateKey snakeOilPublicKey;
  hostKeyFor = name: pkgs.runCommand "${name}-host-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out; ssh-keygen -q -t ed25519 -N "" -C ${name} -f $out/key
  '';
  acerKey = hostKeyFor "acer";
  msiKey = hostKeyFor "msi";
  # a runtime host as acer-swift / msi-ms7758 are: own Herdr server, reached over SSH with a pinned key
  rtHost = hostKey: {
    imports = [ ../modules/agent-runtime/host.nix mirrorConfig ];
    sam.agentRuntime.authorizedLaunch = { enable = true; user = "coordinator"; };
    users.users.coordinator.isNormalUser = true;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    virtualisation.additionalPaths = [ skills mirrorEnv mirror.manifestDir ];
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    environment.systemPackages = [ pkgs.herdr pkgs.jq adapter pkgs.procps pkgs.util-linux ];
    systemd.services.herdr = {
      description = "Herdr server of the runtime host";
      environment = { HOME = "/root"; SHELL = "${pkgs.bash}/bin/bash"; };
      serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
    };
    services.openssh = {
      enable = true;
      hostKeys = [ { path = "/etc/ssh/test_host_ed25519_key"; type = "ed25519"; } ];
    };
    environment.etc."ssh/test_host_ed25519_key" = { source = "${hostKey}/key"; mode = "0600"; };
    users.users.root.openssh.authorizedKeys.keys = [ snakeOilPublicKey ];
  };
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-herdr-fleet";

  nodes = {
    acer = rtHost acerKey;
    msi = rtHost msiKey;
    # the coordinator host, as lenovo is: no runtimes, two saved machines, host keys pinned
    coord = {
      environment.systemPackages = [ pkgs.herdr pkgs.jq pkgs.gnugrep pkgs.coreutils pkgs.inetutils ];
      programs.ssh.knownHosts.acer.publicKeyFile = "${acerKey}/key.pub";
      programs.ssh.knownHosts.msi.publicKeyFile = "${msiKey}/key.pub";
      programs.ssh.extraConfig = ''
        StrictHostKeyChecking yes
        Host acer-swift
          HostName acer
          User root
        Host msi-ms7758
          HostName msi
          User root
      '';
      systemd.services.herdr = {
        environment = { HOME = "/root"; SHELL = "${pkgs.bash}/bin/bash"; };
        serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
      };
    };
  };

  testScript = ''
    import json

    MANIFESTS = "${evaluated.manifestDir}"

    def ssh_ok(host: str) -> None:
        coord.succeed(f"ssh -o ConnectTimeout=5 root@{host} true", timeout=60)

    # Adapt only the production record's shape for assertions; identity and state parsing stay in the task.
    def fleet() -> dict:
        inventory = json.loads(coord.succeed("${inventory}"))
        rows, offline = [], []
        for host in inventory["hosts"]:
            if not host["reachable"]:
                assert host["error"] and host["agents"] == [], host
                offline.append(host["host"])
            for a in host["agents"]:
                if a["harness"] != "agent-runtime":
                    continue
                assert a["observed_at"] and a["evidence_ref"] is None, a
                rows.append({"host": host["host"], "runtime_id": a["runtime_id"], "task_ref": a["runtime_task_ref"],
                             "template": a["template"], "status": a["observed_state"], "reason": a["blocked_reason"],
                             "name": "rt-" + a["runtime_id"]})
        view = {"rows": sorted(rows, key=lambda r: (r["host"], r["name"])), "offline": sorted(offline)}
        print("FLEET", json.dumps(view))
        return view

    def wait_remote(label: str, name: str, states: list, timeout: int = 40) -> None:
        want = json.dumps(states)
        coord.wait_until_succeeds(
            f"herdr --machine {label} agent get {name} | jq -e --argjson w '{want}' '.result.agent.agent_status as $s | $w | index($s)'",
            timeout=timeout)

    def rec(host, i: str) -> dict:
        return json.loads(host.succeed(f"cat /var/lib/agent-runtime-herdr/{i}.json"))

    start_all()
    for h in (acer, msi):
        h.wait_for_unit("sshd.service")
        h.systemctl("start herdr.service")
        h.wait_until_succeeds("herdr agent list", timeout=30)
    coord.wait_for_unit("multi-user.target")
    coord.systemctl("start herdr.service")
    coord.wait_until_succeeds("herdr agent list", timeout=30)
    coord.succeed("install -D -m 600 ${snakeOilPrivateKey} /root/.ssh/id_ed25519")
    ssh_ok("acer"); ssh_ok("msi")
    print(coord.succeed("herdr --version"))

    with subtest("the coordinator saves both worker hosts as Herdr machines (strict host keys)"):
        coord.succeed("${register}")
        labels = sorted(m["label"] for m in json.loads(coord.succeed("herdr machine list --json")))
        assert labels == ["acer-swift", "msi-ms7758"], labels
        saved = coord.succeed("herdr machine list --json")
        coord.succeed("${register}")
        assert coord.succeed("herdr machine list --json") == saved, "registration must be idempotent"
        rc, out = coord.execute("ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null root@msi true 2>&1")
        assert rc != 0 and "Host key verification failed" in out, (rc, out)
        v = fleet()
        assert v == {"rows": [], "offline": []}, v

    with subtest("two runtimes that share the instance id `coder` are told apart by host, task and template"):
        # both hosts run an instance literally named `coder`; nothing but the host distinguishes the id
        acer.succeed("${prepare} coder 1048576")
        acer.succeed(f"agent-runtime-herdr attach coder {MANIFESTS}/worker-a.json sammasak/nixos-config#901 /var/lib/rt/coder/output/status -- ${launch} coder 1048576")
        msi.succeed("${prepare} coder 1048576")
        msi.succeed(f"agent-runtime-herdr attach coder {MANIFESTS}/worker-b.json sammasak/skills#902 /var/lib/rt/coder/output/status -- ${launch} coder 1048576")
        wait_remote("acer-swift", "rt-coder", ["idle", "done"])
        wait_remote("msi-ms7758", "rt-coder", ["idle", "done"])
        v = fleet()
        rows = v["rows"]
        assert v["offline"] == [] and len(rows) == 2, v
        # every row carries all five fields, and the two `coder`s are distinct by host
        for r in rows:
            assert r["runtime_id"] == "coder" and r["task_ref"] and r["template"] and r["status"] in ("idle", "done"), r
        a = next(r for r in rows if r["host"] == "acer-swift")
        m = next(r for r in rows if r["host"] == "msi-ms7758")
        assert a["task_ref"] == "sammasak/nixos-config#901" and m["task_ref"] == "sammasak/skills#902", rows
        assert a["template"] == rec(acer, "coder")["template_digest"][:12], a
        assert m["template"] == rec(msi, "coder")["template_digest"][:12], m
        assert a["template"] != m["template"], rows
        assert (a["host"], a["runtime_id"]) != (m["host"], m["runtime_id"]) or a["host"] != m["host"]
        # the correlation is the Herdr title, not terminal_title_stripped (the container's own name)
        print("per-host coder correlation OK:", json.dumps([a, m]))
        acer.succeed("agent-runtime-herdr deliver coder 'fleet fixture handoff'")
        wait_remote("acer-swift", "rt-coder", ["working"])
        wait_remote("acer-swift", "rt-coder", ["idle", "done"])

    with subtest("credential-free authorized launcher mirrors: unknown, working, blocked with reason, and no prompt"):
        for i, ref in [("m1", "sammasak/nixos-config#903"), ("m2", "sammasak/nixos-config#904")]:
            manifest = "${mirror.manifestDir}/mirror-probe.json"
            msi.succeed(f"agent-runtime-instance create {i} --template {manifest} --host /etc/agent-runtime/host.json --task {ref}")
            msi.succeed(f"agent-runtime-herdr attach {i} {manifest} {ref} /run/agent-runtime/{i}/mirror.status --mirror")
            wait_remote("msi-ms7758", f"rt-{i}", ["unknown"])
            pane = rec(msi, i)["herdr"]["pane_id"]
            msi.succeed(f"herdr pane report-metadata {pane} --source agent-runtime --agent agent-runtime --token blocked_reason=stale")
            rc, out = msi.execute(f"agent-runtime-herdr deliver {i} 'must not launch' 2>&1")
            assert rc == 75, (rc, out)
            assert json.loads(msi.succeed(f"agent-runtime-instance status {i}"))["state"] == "created"
            msi.succeed(f"systemd-run --unit=fleet-launch-{i} --collect --property=Type=exec runuser -u coordinator -- /run/wrappers/bin/sudo -n $(readlink -f $(command -v agent-runtime-authorized-start)) {i}")
            wait_remote("msi-ms7758", f"rt-{i}", ["working"])
            observed = json.loads(msi.succeed(f"herdr agent get rt-{i}"))["result"]["agent"]
            assert "blocked_reason" not in observed.get("tokens", {}), observed
            msi.succeed(f"test ! -e /run/agent-runtime/{i}/cred/token")
            assert msi.succeed(f"stat -c %a /run/agent-runtime/{i}/mirror.status").strip() == "644"
        msi.succeed("touch /var/lib/agent-runtime/m1/vol/output/fail /var/lib/agent-runtime/m1/vol/output/finish")
        wait_remote("msi-ms7758", "rt-m1", ["blocked"])
        blocked = next(r for r in fleet()["rows"] if r["host"] == "msi-ms7758" and r["runtime_id"] == "m1")
        reason = json.loads(msi.succeed("cat /run/agent-runtime/m1/mirror.status"))["reason"]
        assert blocked["task_ref"] == "sammasak/nixos-config#903" and blocked["reason"] == reason[:80] and reason, blocked
        before = json.loads(msi.succeed("agent-runtime-instance status m2"))["started"]["invocation"]

    with subtest("Herdr restart marks a lost pane honestly and preserves real launcher mirrors without reassigning"):
        msi.systemctl("restart herdr.service")
        msi.wait_until_succeeds("herdr agent list", timeout=30)
        print(msi.succeed("agent-runtime-herdr reconcile"))
        # Herdr checks self-reported agents against an idle shell every second. Verify the
        # restored identity survives that check, rather than only observing a fleeting report.
        msi.sleep(2)
        assert rec(msi, "coder")["status"] == "lost", rec(msi, "coder")
        wait_remote("msi-ms7758", "rt-m1", ["blocked"])
        wait_remote("msi-ms7758", "rt-m2", ["working"])
        v = fleet()
        assert "msi-ms7758" not in v["offline"], v
        after = next(r for r in v["rows"] if r["host"] == "msi-ms7758" and r["runtime_id"] == "m1")
        assert after == blocked, (blocked, after)
        assert not any(r["host"] == "msi-ms7758" and r["runtime_id"] == "coder" for r in v["rows"]), v
        assert json.loads(msi.succeed("agent-runtime-instance status m2"))["started"]["invocation"] == before

    with subtest("msi outside its power window is an offline error row, not a vanished runtime or false idle"):
        # Herdr holds its SSH session to a saved machine; dropping sshd and the established session is the
        # host/network going away, exactly the MSI 09:00-21:00 power window closing
        msi.succeed("systemctl stop sshd.service sshd.socket 2>/dev/null || systemctl stop sshd.service")
        msi.succeed("pkill -KILL -f '^sshd' || true")
        v = fleet()
        assert "msi-ms7758" in v["offline"], v                                   # surfaced as offline, not empty
        assert any(r["host"] == "acer-swift" and r["name"] == "rt-coder" for r in v["rows"]), v   # acer still visible
        assert not any(r["host"] == "msi-ms7758" for r in v["rows"]), v          # msi runtimes are not falsely listed idle
        msi.succeed("systemctl start sshd.service"); msi.wait_for_unit("sshd.service")
        coord.wait_until_succeeds("herdr --machine msi-ms7758 agent list", timeout=60)
        v = fleet()
        assert v["offline"] == [] and any(r["host"] == "msi-ms7758" for r in v["rows"]), v   # online again, no false absence

    with subtest("success is idle, machine rollback is explicit, and declarative re-registration restores identity"):
        msi.succeed("touch /var/lib/agent-runtime/m2/vol/output/finish")
        wait_remote("msi-ms7758", "rt-m2", ["idle", "done"])
        profile = next(m["id"] for m in json.loads(coord.succeed("herdr machine list --json")) if m["label"] == "msi-ms7758")
        coord.succeed(f"herdr machine remove {profile}")
        assert not any(r["host"] == "msi-ms7758" for r in fleet()["rows"])
        coord.succeed("${register}")
        wait_remote("msi-ms7758", "rt-m1", ["blocked"])
        wait_remote("msi-ms7758", "rt-m2", ["idle", "done"])
        assert json.loads(msi.succeed("agent-runtime-instance status m2"))["started"]["invocation"] == before

    with subtest("teardown leaves nothing of any runtime on any node, and the fleet view is empty"):
        acer.succeed("agent-runtime-herdr detach coder"); acer.succeed("${destroy} coder")
        for i in ("coder", "m1", "m2"):
            msi.succeed(f"agent-runtime-herdr detach {i}")
        msi.succeed("${destroy} coder")
        for i in ("m1", "m2"):
            msi.succeed(f"agent-runtime-instance export {i}")
            bundle = json.loads(msi.succeed(f"agent-runtime-instance status {i}"))["export"]["dir"]
            msi.succeed(f"agent-runtime-verify --bundle {bundle} --template ${mirror.manifestDir}/mirror-probe.json")
            msi.succeed(f"agent-runtime-instance destroy {i}")
            msi.succeed(f"test ! -e /run/agent-runtime/{i} -a ! -e /var/lib/agent-runtime/{i} -a -f {bundle}/bundle.json")
        v = fleet()
        assert v["rows"] == [] and v["offline"] == [], v
        for h in (acer, msi):
            h.succeed("! machinectl list --no-legend | grep -q rt-")
            h.succeed("! systemctl list-units --all --no-legend 'rt-*' 'agent-runtime-herdr-follow-*' | grep -q .")
  '';
}
