# #139 proof: two ephemeral nspawn runtimes become Herdr agents of the physical
# host through the host-side adapter (modules/agent-runtime/herdr), take a
# handoff through its gated `deliver` (herdr 0.9.5's `agent prompt` refuses
# them, asserted), report their state, lose no result and get no second
# assignment across a Herdr restart, and leave nothing after teardown.
# Real herdr server and CLI, real systemd-nspawn, in QEMU only:
# nix build .#packages.x86_64-linux.agent-runtime-herdr-test
{ pkgs, lib, skills }:
let
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  template = name: pkgs': {
    role = { inherit name; harness = "claude-code"; };
    skillsSource = skills;
    skills.lean-code = { };
    packages = pkgs';
    filesystem = {
      home.sizeMiB = 16;
      tmp.sizeMiB = 16;
      cache.sizeMiB = 16;
      output.sizeMiB = 16;
    };
    resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 5; };
  };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = { enable = true; eligibleTemplates = [ "worker-a" "worker-b" ]; maxConcurrentInstances = 2; };
        sam.agentRuntime.templates.worker-a = template "worker-a" (with pkgs; [ bash coreutils ]);
        sam.agentRuntime.templates.worker-b = template "worker-b" (with pkgs; [ bash coreutils gnugrep ]);
      }
    ];
  };
  manifest = n: "${evaluated.manifestDir}/${n}.json";
  adapter = import ../modules/agent-runtime/herdr { inherit pkgs; };
  agentEnv = pkgs.buildEnv { name = "rt-fixture-agent"; paths = with pkgs; [ bash coreutils ]; };

  # The fixture agent inside the container: what a harness does, reduced to its
  # lifecycle. It reads each handoff from its PTY and reports through a status
  # file in its own output mount; it has no Herdr socket and no network.
  agent = pkgs.writeShellScript "rt-fixture-agent" ''
    export PATH=${agentEnv}/bin
    st=/output/status
    echo started >> $st
    sleep 1
    echo idle >> $st
    n=0
    while IFS= read -r line; do
      case $line in
        "") continue ;;
        EXIT) echo finished >> $st; exit 0 ;;
        BLOCK) echo blocked >> $st; continue ;;
        UNBLOCK) echo idle >> $st; continue ;;
      esac
      n=$((n + 1))
      echo working >> $st
      printf '%s\n' "$line" > /output/handoff-$n.txt
      sleep 2
      echo "result $n of $(id -u) in $(cat /proc/sys/kernel/hostname)" > /output/result-$n.txt
      echo idle >> $st
    done
  '';

  # The pane command: a cgroup-bounded scope around nspawn with the PTY as its
  # console, the only channel between Herdr and the container. #138's adapter
  # supplies the production form; #135/#137 prove the boundary itself.
  launch = pkgs.writeShellScript "rt-launch" ''
    set -euo pipefail
    id=$1 uidbase=$2
    exec ${pkgs.systemd}/bin/systemd-run --scope --quiet --unit="rt-$id" -p MemoryMax=128M -p TasksMax=64 \
      ${pkgs.systemd}/bin/systemd-nspawn --quiet --keep-unit --console=interactive --settings=no --register=yes \
        -M "rt-$id" -D "/run/rt/$id/root" \
        --private-users="$uidbase:65536" --private-users-ownership=chown \
        --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes \
        --hostname="rt-$id" \
        --bind-ro=/nix/store --bind="/var/lib/rt/$id/output:/output" \
        /bin/sh -c "exec ${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-all --no-new-privs ${agent}"
  '';

  prepare = pkgs.writeShellScript "rt-prepare" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils ])}
    id=$1 uidbase=$2
    root=/run/rt/$id/root
    mkdir -p "$root"/{etc,bin,usr/bin,nix/store,output,proc,sys,dev} "/var/lib/rt/$id/output"
    printf 'root:x:0:0::/root:/bin/sh\nagent:x:1000:1000::/:/bin/sh\n' > "$root/etc/passwd"
    printf 'root:x:0:\nagent:x:1000:\n' > "$root/etc/group"
    printf 'ID=agent-runtime\n' > "$root/etc/os-release"
    ln -sf ${pkgs.bash}/bin/bash "$root/bin/sh"
    chown $((uidbase + 1000)):$((uidbase + 1000)) "/var/lib/rt/$id/output"
  '';

  destroy = pkgs.writeShellScript "rt-destroy" ''
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils systemd util-linux ])}
    id=$1
    machinectl terminate "rt-$id" 2>/dev/null || true
    systemctl stop "rt-$id.scope" 2>/dev/null || true
    for _ in $(seq 50); do machinectl show "rt-$id" >/dev/null 2>&1 || break; sleep 0.1; done
    rm -rf "/run/rt/$id"
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-herdr";

  nodes.machine = {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    environment.systemPackages = [ pkgs.herdr pkgs.jq adapter pkgs.procps ];
    systemd.services.herdr = {
      description = "Herdr server of the physical host";
      environment = { HOME = "/root"; SHELL = "${pkgs.bash}/bin/bash"; };
      serviceConfig.ExecStart = "${pkgs.herdr}/bin/herdr server";
    };
  };

  testScript = ''
    import json

    def herdr_agents():
        return json.loads(machine.succeed("herdr agent list"))["result"]["agents"]

    def rt_agents():
        return {a.get("name"): a for a in herdr_agents() if (a.get("name") or "").startswith("rt-")}

    def listing(label):
        out = machine.succeed("herdr agent list | jq -c '[.result.agents[] | {pane_id, name, agent, agent_status, title, terminal_title: .terminal_title_stripped}]'")
        print(f"=== herdr agent list ({label}):", out)
        return out

    def rec(i):
        return json.loads(machine.succeed(f"cat /var/lib/agent-runtime-herdr/{i}.json"))

    def diagnose(i):
        for c in (f"herdr agent get {pane(i)}", f"herdr pane read $(jq -r .herdr.pane_id /var/lib/agent-runtime-herdr/{i}.json) --lines 30",
                  f"cat /var/lib/agent-runtime-herdr/{i}.json", f"cat /var/lib/rt/{i}/output/status",
                  f"journalctl -b -o cat -u agent-runtime-herdr-follow-{i} | tail -20", "machinectl list --no-legend",
                  f"systemctl status rt-{i}.scope --no-pager | tail -15"):
            print(f"--- {c}\n" + machine.execute(c + " 2>&1")[1])

    def pane(i):
        return rec(i)["herdr"]["pane_id"]

    def wait_state(i, state, timeout=30):
        try:
            # Herdr reports an idle agent it has not marked seen as done; both are ready for input
            want = '["idle","done"]' if state == "idle" else f'["{state}"]'
            machine.wait_until_succeeds(f"herdr agent get {pane(i)} | jq -e --argjson w '{want}' '.result.agent.agent_status as $s | $w | index($s)'", timeout=timeout)
        except Exception:
            diagnose(i)
            raise

    machine.wait_for_unit("multi-user.target")
    machine.systemctl("start herdr.service")
    machine.wait_until_succeeds("herdr agent list", timeout=30)
    print("=== versions ===")
    print(machine.succeed("herdr --version; uname -r; systemctl --version | head -1"))
    print("digests: worker-a", json.load(open("${manifest "worker-a"}"))["digests"]["template"],
          "worker-b", json.load(open("${manifest "worker-b"}"))["digests"]["template"])
    before = listing("before")
    assert "rt-" not in before

    with subtest("two runtimes on one host become two distinct Herdr agents"):
        for i, tpl, ref, base in (("a1", "worker-a", "sammasak/nixos-config#901", 1048576), ("b1", "worker-b", "sammasak/skills#902", 1114112)):
            machine.succeed(f"${prepare} {i} {base}")
            print(machine.succeed(
                f"agent-runtime-herdr attach {i} ${evaluated.manifestDir}/{tpl}.json {ref} /var/lib/rt/{i}/output/status -- ${launch} {i} {base}"))
        for i in ("a1", "b1"):
            wait_state(i, "idle")
        during = listing("two idle runtimes")
        agents = rt_agents()
        assert set(agents) == {"rt-a1", "rt-b1"}, agents
        assert agents["rt-a1"]["pane_id"] != agents["rt-b1"]["pane_id"]
        print(machine.succeed("machinectl list --no-legend"))
        a, b = rec("a1"), rec("b1")
        assert (a["template"], b["template"]) == ("worker-a", "worker-b")
        assert a["template_digest"] != b["template_digest"]
        assert (a["task_ref"], b["task_ref"]) == ("sammasak/nixos-config#901", "sammasak/skills#902")
        for r in (a, b):
            title = machine.succeed(f"herdr pane get {r['herdr']['pane_id']} | jq -c .result.pane").strip()
            print("pane", r["runtime_id"], title)
            assert r["task_ref"] in title and r["template_digest"][:12] in title, title

    with subtest("a handoff reaches the idle runtime, its state goes working and back to idle"):
        pane_a = pane("a1")
        # the Coordinator's herdr:message path: herdr 0.9.5 refuses a runtime pane (upstream gap, recorded)
        st, o = machine.execute(f"herdr agent prompt {pane_a} 'Assignment #901: run the fixture' 2>&1")
        print("herdr agent prompt to a runtime pane:", st, o.strip())
        assert st != 0 and "agent_not_ready" in o
        print(machine.succeed("agent-runtime-herdr deliver a1 'Assignment #901: run the fixture'"))
        wait_state("a1", "working", 10)
        print("registry while working:", rec("a1")["status"])
        wait_state("a1", "idle", 20)
        print(machine.succeed("cat /var/lib/rt/a1/output/handoff-1.txt /var/lib/rt/a1/output/result-1.txt"))
        assert "Assignment #901" in machine.succeed("cat /var/lib/rt/a1/output/handoff-1.txt")
        assert machine.succeed("test ! -e /var/lib/rt/b1/output/handoff-1.txt && echo none").strip() == "none", "the handoff leaked to the other runtime"
        assert rec("a1")["status"] == "idle"

    with subtest("two delivers back to back: the second is refused, the runtime gets one task"):
        out = machine.succeed("agent-runtime-herdr deliver a1 'Assignment #901: second task' > /tmp/d1 2>&1; echo first=$?; "
                              "agent-runtime-herdr deliver a1 'Assignment #901: duplicate' > /tmp/d2 2>&1; echo second=$?; cat /tmp/d1 /tmp/d2")
        print(out)
        assert "first=0" in out and "second=75" in out and "assigned, not idle" in out, out
        wait_state("a1", "idle", 20)
        assert machine.succeed("ls /var/lib/rt/a1/output").count("handoff-") == 2, machine.succeed("ls /var/lib/rt/a1/output")
        assert "second task" in machine.succeed("cat /var/lib/rt/a1/output/handoff-2.txt")
        assert len(rec("a1")["deliveries"]) == 2 and rec("a1")["status"] == "idle", rec("a1")
        status, o = machine.execute("agent-runtime-herdr deliver a1 \"$(printf 'line one\\nline two')\" 2>&1")
        print("multi-line deliver:", status, o)
        assert status == 64 and "one line" in o

    with subtest("a blocked runtime is reported blocked; a finished one is no longer an agent"):
        machine.succeed("agent-runtime-herdr deliver b1 BLOCK")
        wait_state("b1", "blocked", 10)
        machine.wait_until_succeeds("jq -e '.status == \"blocked\"' /var/lib/agent-runtime-herdr/b1.json", timeout=10)
        status, out = machine.execute("agent-runtime-herdr deliver b1 'Assignment #902: should not land' 2>&1")
        print("deliver to blocked:", status, out)
        assert status == 75 and "blocked" in out, "delivered to a blocked runtime"
        assert machine.succeed("ls /var/lib/rt/b1/output").count("handoff-") == 0
        # the operator answers the block at the pane, the way a human answers an approval
        machine.succeed(f"herdr pane send-text {pane('b1')} UNBLOCK && herdr pane send-keys {pane('b1')} Enter")
        wait_state("b1", "idle", 10)
        machine.succeed("agent-runtime-herdr deliver b1 EXIT")
        machine.wait_until_succeeds("jq -e '.status == \"finished\"' /var/lib/agent-runtime-herdr/b1.json", timeout=20)
        machine.wait_until_succeeds("! herdr agent list | jq -e '.result.agents[] | select(.name == \"rt-b1\")'", timeout=10)
        status, out = machine.execute("agent-runtime-herdr deliver b1 'Assignment #902: after exit' 2>&1")
        print("deliver to finished:", status, out)
        assert status == 75 and "finished" in out, "delivered to a finished runtime"
        listing("after b1 finished")

    with subtest("Herdr outage: local status answers, results stay, nothing is assigned twice"):
        results_before = machine.succeed("ls /var/lib/rt/*/output | sort").strip()
        machine.succeed("herdr server stop || systemctl stop herdr.service")
        machine.wait_until_fails("herdr agent list", timeout=20)
        local = machine.succeed("agent-runtime-herdr status")
        print("=== local status, Herdr down ===\n" + local)
        assert "a1\t" in local and "b1\tfinished" in local
        status, out = machine.execute("agent-runtime-herdr reconcile 2>&1")
        print("reconcile while down:", status, out)
        assert status != 0 and "unreachable" in out
        machine.systemctl("start herdr.service")
        machine.wait_until_succeeds("herdr agent list", timeout=30)
        listing("after Herdr restart")
        alive = machine.execute("machinectl show rt-a1 >/dev/null 2>&1")[0] == 0
        print("rt-a1 machine alive after the Herdr restart:", alive, "|", machine.succeed("machinectl list --no-legend; echo"))
        out = machine.succeed("agent-runtime-herdr reconcile")
        print("reconcile:", out)
        # reconcile tells the truth: a live runtime is re-reported, a dead one is lost and stays unlisted
        if alive:
            assert "a1: re-reported" in out and rec("a1")["status"] == "idle", out
        else:
            assert "a1: lost" in out and rec("a1")["status"] == "lost", out
            assert "rt-a1" not in machine.succeed("herdr agent list"), "a dead runtime is listed as an agent"
            status, o = machine.execute("agent-runtime-herdr deliver a1 'Assignment #901: replay' 2>&1")
            print("deliver to lost:", status, o)
            assert status == 75 and "lost" in o
        assert machine.succeed("ls /var/lib/rt/*/output | sort").strip() == results_before, "results changed across the restart"
        assert machine.succeed("ls /var/lib/rt/a1/output").count("handoff-") == 2, "a handoff was replayed"
        assert len(rec("a1")["deliveries"]) == 2, rec("a1")["deliveries"]
        print(machine.succeed("agent-runtime-herdr status --json | jq -c '.[] | {runtime_id, status}'"))

    with subtest("teardown: Herdr, systemd, machined and the mounts hold nothing of either runtime"):
        for i in ("a1", "b1"):
            print(machine.succeed(f"agent-runtime-herdr detach {i}"))
            machine.succeed(f"${destroy} {i}")
        after = listing("after teardown")
        assert "rt-" not in after, after
        machine.succeed("! machinectl list --no-legend | grep -q rt-")
        machine.succeed("! systemctl list-units --all --no-legend 'rt-*' 'agent-runtime-herdr-follow-*' | grep -q .")
        machine.succeed("! findmnt -rn | grep -q '/run/rt/'")
        machine.succeed("! pgrep -a -x systemd-nspawn")
        machine.succeed("test ! -e /run/rt/a1 -a ! -e /run/rt/b1")
        statuses = machine.succeed("agent-runtime-herdr status --json | jq -r '[.[].status] | unique | join(\",\")'").strip()
        assert statuses == "torn_down", statuses
        print("results kept:", machine.succeed("ls /var/lib/rt/a1/output /var/lib/rt/b1/output"))
  '';
}
