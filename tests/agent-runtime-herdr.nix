# #139 proof: two ephemeral nspawn runtimes become Herdr agents of the physical
# host through the host-side adapter (modules/agent-runtime/herdr), take a
# handoff through its gated `deliver` (herdr 0.9.5's `agent prompt` refuses
# them, asserted), report their state, lose no result and get no second
# assignment across a Herdr restart, and leave nothing after teardown.
# Real herdr server and CLI, real systemd-nspawn, in QEMU only:
# nix build .#packages.x86_64-linux.agent-runtime-herdr-test
{ pkgs, lib, skills }:
let
  inherit (import ./agent-runtime-herdr-fixture.nix { inherit pkgs lib skills; })
    evaluated manifest adapter launch prepare destroy;
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
        # the test shell runs under set -e: each exit code is captured, not allowed to abort the pair
        out = machine.succeed("a=0; agent-runtime-herdr deliver a1 'Assignment #901: second task' > /tmp/d1 2>&1 || a=$?; "
                              "b=0; agent-runtime-herdr deliver a1 'Assignment #901: duplicate' > /tmp/d2 2>&1 || b=$?; "
                              "echo first=$a second=$b; cat /tmp/d1 /tmp/d2")
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
