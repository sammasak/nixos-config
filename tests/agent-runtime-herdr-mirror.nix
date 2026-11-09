# #169 option (b): the Herdr STATUS MIRROR. The credentialed coder run stays the direct root
# `agent-runtime-instance start --credential` (no pane, no new privilege); this proves it SHOWS in
# Herdr through the shipped `agent-runtime-herdr` adapter run by an ORDINARY non-root user, with a
# dummy token: root writes the 0644 mirror.status, the unprivileged follower maps it (working/idle/
# blocked+reason), the 0400 credential stays unreadable, deliver is refused, reconcile recovers the
# mapping after a restart, and the token reaches no Herdr surface. QEMU only:
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
          # small budgets: the defaults would exceed the VM disk / mkfs.ext4 inode limits in tiny images
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
    # the SHIPPED path: an ORDINARY (non-root) user runs the server, adapter and follower; uid pinned so
    # the test can name XDG_RUNTIME_DIR (/run/user/1001)
    users.users.mirror = { isNormalUser = true; uid = 1001; };
    systemd.user.services.herdr = {
      description = "Herdr server of the unprivileged Herdr user";
      wantedBy = [ "default.target" ];
      environment = { SHELL = "${pkgs.bash}/bin/bash"; };
      serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
    };
    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    import json, shlex

    M = "${manifest}"
    POLICY = "${evaluated.hostPolicy}"
    REF = "sammasak/nixos-config#169"
    TOKEN = "sk-ant-oat01-DUMMY-mirror-169-secret"
    MUID = 1001
    HSTATE = "/home/mirror/.local/state/agent-runtime-herdr"

    # run a Herdr-side command AS THE UNPRIVILEGED mirror user, with the env the adapter and the
    # systemd --user follower need (its own registry, the user manager socket on XDG_RUNTIME_DIR).
    def am(cmd):
        menv = f"XDG_RUNTIME_DIR=/run/user/{MUID} AGENT_RUNTIME_HERDR_STATE={HSTATE} HOME=/home/mirror PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        return f"runuser -u mirror -- env {menv} bash -c {shlex.quote(cmd)}"

    def mrun(cmd):
        return machine.succeed(am(cmd))

    def mexec(cmd):
        return machine.execute(am(cmd))

    def rec(i):
        # the registry is the mirror user's; root may read it
        return json.loads(machine.succeed(f"cat {HSTATE}/{i}.json"))

    def pane(i):
        return rec(i)["herdr"]["pane_id"]

    def fg(i):
        return mrun(
            f"herdr pane process-info --pane {pane(i)} | jq -r '.result.process_info.foreground_processes[0].cmdline // empty'"
        ).strip()

    def agent_get(i):
        return mrun(f"herdr agent get {pane(i)} > /tmp/get.{i} 2>&1; cat /tmp/get.{i}")

    def hs(i):
        return json.loads(agent_get(i))["result"]["agent"]["agent_status"]

    def wait_hs(i, state, timeout=40):
        # Herdr reports an idle-but-unseen agent as `done`; both mean idle here
        want = '["idle","done"]' if state == "idle" else f'["{state}"]'
        try:
            machine.wait_until_succeeds(
                am(f"herdr agent get {pane(i)} | jq -e --argjson w '{want}' '.result.agent.agent_status as $s | $w | index($s)'"),
                timeout=timeout,
            )
        except Exception:
            print(f"--- diagnose {i}", mexec(f"herdr agent get {pane(i)} 2>&1")[1], machine.execute(f"cat /run/agent-runtime/{i}/mirror.status 2>&1; journalctl -b _UID={MUID} -o cat | tail -30")[1])
            raise

    machine.wait_for_unit("multi-user.target")
    # bring up the UNPRIVILEGED user's systemd manager and its Herdr server
    machine.succeed("loginctl enable-linger mirror")
    machine.wait_until_succeeds(f"test -S /run/user/{MUID}/bus", timeout=30)
    mrun("systemctl --user start herdr.service")
    machine.wait_until_succeeds(am("herdr agent list"), timeout=30)
    print("=== versions ===\n" + mrun("herdr --version; uname -r"))
    # the follower must be a mirror-user unit, not a system one
    assert machine.execute("systemctl is-active herdr.service")[0] != 0, "herdr must not run as a system service here"
    # a dummy subscription token in the shape of the SOPS claude_oauth_token, nothing real
    machine.succeed(f"printf '%s' '{TOKEN}' > /root/dummy-token && chmod 600 /root/dummy-token")

    with subtest("mirror attach (unprivileged) starts nothing; the direct root run shows working, then idle (done)"):
        machine.succeed(f"${I} create ok --template {M} --host {POLICY} --task {REF}")
        # attach the mirror BEFORE the start, as the mirror user, pointing at the path root will write
        print(mrun(f"agent-runtime-herdr attach ok {M} {REF} /run/agent-runtime/ok/mirror.status --mirror"))
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
        # the follower is the UNPRIVILEGED user's unit, end to end: active under the mirror manager,
        # and no system unit of that name exists
        assert mrun("systemctl --user is-active agent-runtime-herdr-follow-ok.service").strip() == "active"
        assert machine.execute("systemctl is-active agent-runtime-herdr-follow-ok.service")[0] != 0, "follower must not be a system unit"

        # the mirror file is world-readable; the credential is a SEPARATE 0400 file
        assert machine.succeed("stat -c %a /run/agent-runtime/ok/mirror.status").strip() == "644"
        assert machine.succeed("stat -c %a /run/agent-runtime/ok/cred/token").strip() == "400"
        mir = json.loads(machine.succeed("cat /run/agent-runtime/ok/mirror.status"))
        print("mirror.status during:", json.dumps(mir))
        assert set(mir) == {"state", "outcome", "reason"}, mir
        assert TOKEN not in machine.succeed("cat /run/agent-runtime/ok/mirror.status")
        # the unprivileged user reads the mirror but CANNOT read the credential
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
        rc, out = mexec("agent-runtime-herdr deliver ok 'go run something' 2>&1")
        print("deliver to a mirror:", rc, out.strip())
        assert rc == 75 and "status mirror" in out and "not delivering" in out, (rc, out)
        # nothing was started: the pane still holds the placeholder, the instance is untouched
        assert fg("ok") == before, (before, fg("ok"))
        assert json.loads(machine.succeed("${I} status ok"))["state"] == "succeeded"

    with subtest("a forced failure shows blocked with its non-secret reason"):
        machine.succeed(f"${I} create bad --template {M} --host {POLICY} --task {REF}")
        print(mrun(f"agent-runtime-herdr attach bad {M} {REF} /run/agent-runtime/bad/mirror.status --mirror"))
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
        assert g.get("tokens", {}).get("blocked_reason") == mir["reason"][:80], g

    with subtest("the dummy token appears in NO Herdr surface (registry, state, screen, journals, log)"):
        # the mirror user's registry and all of Herdr's own on-disk state (config + session state)
        machine.succeed(f"! grep -rsqIF -- '{TOKEN}' {HSTATE} /home/mirror/.config /home/mirror/.local /home/mirror/.cache /run/user/{MUID}")
        # the legacy root registry path must not exist / must be clean either
        machine.succeed(f"! grep -rsqIF -- '{TOKEN}' /var/lib/agent-runtime-herdr")
        for i in ("ok", "bad"):
            machine.succeed(f"! grep -qF -- '{TOKEN}' /run/agent-runtime/{i}/mirror.status")
            mrun(f"herdr agent get {pane(i)} > /tmp/get.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/get.{i}")
            mrun(f"herdr pane get {pane(i)} > /tmp/pget.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/pget.{i}")
            # the pane SCREEN itself
            mrun(f"herdr agent read {pane(i)} > /tmp/read.{i} 2>&1 || true")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/read.{i}")
            machine.succeed(f"${I} logs {i} > /tmp/log.{i} 2>&1")
            machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/log.{i}")
        mrun("herdr agent list > /tmp/alist 2>&1")
        machine.succeed(f"! grep -qF -- '{TOKEN}' /tmp/alist")
        # the journals: the mirror user's (the Herdr server AND the follower units run under it) and the
        # system/instance units
        machine.succeed(f"! journalctl -b _UID={MUID} -o cat | grep -qF -- '{TOKEN}'")
        machine.succeed(f"! journalctl -b -u 'agent-runtime*' -o cat | grep -qF -- '{TOKEN}'")
        print("no token in: registry, Herdr on-disk state, mirror.status, agent get, pane get, agent read, logs, agent list, user+instance journals")

    with subtest("reconcile re-maps a mirror after a Herdr restart: idle/blocked with reason, never unknown"):
        # the records carry an instance LIFECYCLE state, which the generic pane mapping would call `unknown`
        assert rec("ok")["status"] == "succeeded" and rec("bad")["status"] == "failed", (rec("ok")["status"], rec("bad")["status"])
        mrun("systemctl --user restart herdr.service")
        machine.wait_until_succeeds(am("herdr agent list"), timeout=30)
        out = mrun("agent-runtime-herdr reconcile")
        print("reconcile after restart:\n" + out)
        assert "ok: re-reported mirror (idle)" in out, out
        assert "bad: re-reported mirror (blocked)" in out, out
        machine.sleep(2)
        wait_hs("ok", "idle", 40)
        assert hs("ok") in ("idle", "done"), hs("ok")
        wait_hs("bad", "blocked", 40)
        g = json.loads(agent_get("bad"))["result"]["agent"]
        print("bad after reconcile:", g["agent_status"])
        assert g["agent_status"] == "blocked", g
        reason = json.loads(machine.succeed("cat /run/agent-runtime/bad/mirror.status"))["reason"]
        assert g.get("tokens", {}).get("blocked_reason") == reason[:80] and reason, g
        for i in ("ok", "bad"):
            restored = json.loads(mrun(f"herdr agent get rt-{i}"))["result"]["agent"]
            assert restored["title"] == f"{REF} rt={i} tpl={rec(i)['template_digest'][:12]} (mirror)", restored
            assert "sleep" in fg(i) and "infinity" in fg(i), fg(i)

    with subtest("reconcile never replaces a foreign foreground command in a mirror pane"):
        mrun("systemctl --user restart herdr.service")
        machine.wait_until_succeeds(am("herdr agent list"), timeout=30)
        mrun(f"herdr pane run {pane('bad')} 'exec ${pkgs.coreutils}/bin/sleep 43200'")
        machine.wait_until_succeeds(am(f"herdr pane process-info --pane {pane('bad')} | jq -e '.result.process_info.foreground_processes[0].cmdline | contains(\"43200\")'"), timeout=30)
        before = fg("bad")
        out = mrun("agent-runtime-herdr reconcile")
        assert "bad: lost" in out and rec("bad")["status"] == "lost", out
        assert fg("bad") == before, (before, fg("bad"))
        assert json.loads(machine.succeed("${I} status bad"))["state"] == "failed"

    with subtest("teardown (unprivileged detach): no mirror agent, workspace or follower unit is left"):
        for i in ("ok", "bad"):
            print(mrun(f"agent-runtime-herdr detach {i}"))
            machine.succeed(f"${I} destroy {i} --discard")
            machine.succeed(f"test ! -e /run/agent-runtime/{i}")
        mrun("! herdr agent list | jq -e '.result.agents[] | select(.name | startswith(\"rt-\"))'")
        machine.succeed(am("! systemctl --user list-units --all --no-legend 'agent-runtime-herdr-follow-*' | grep -q ."))
        statuses = mrun("agent-runtime-herdr status --json | jq -r '[.[].status] | unique | join(\",\")'").strip()
        assert statuses == "torn_down", statuses
  '';
}
