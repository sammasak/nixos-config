# #139 across machines: a coordinator node sees the runtimes of another host
# through a saved Herdr machine (`herdr machine add`, `herdr --machine <label>`),
# tells them apart by name, task and template digest, and drives the
# Coordinator's herdr:message route against them: its state gate (`agent get`)
# works across the machine, the final `agent prompt` is refused by herdr 0.9.5
# (the upstream requirement in docs/agent-runtime-herdr.md), and a blocked or
# finished runtime is refused before anything is sent. Real herdr server and
# CLI on both nodes, real systemd-nspawn on the runtime host, SSH with a pinned
# host key. In QEMU only:
# nix build .#packages.x86_64-linux.agent-runtime-herdr-machines-test
{ pkgs, lib, skills }:
let
  inherit (import ./agent-runtime-herdr-fixture.nix { inherit pkgs lib skills; })
    evaluated adapter launch prepare destroy;
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs) snakeOilPrivateKey snakeOilPublicKey;
  hostKey = pkgs.runCommand "rthost-host-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out; ssh-keygen -q -t ed25519 -N "" -C rthost -f $out/key
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-herdr-machines";

  nodes = {
    # the physical host with the runtimes, as acer-swift is: its own Herdr server, reached over SSH
    rthost = {
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      environment.systemPackages = [ pkgs.herdr pkgs.jq adapter pkgs.procps ];
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
    # the coordinator host, as lenovo is: no runtimes, one saved machine
    coord = {
      environment.systemPackages = [ pkgs.herdr pkgs.jq ];
      programs.ssh.knownHosts.rthost.publicKeyFile = "${hostKey}/key.pub";
      programs.ssh.extraConfig = "StrictHostKeyChecking yes";
    };
  };

  testScript = ''
    import json

    def remote(cmd: str) -> str:
        return coord.succeed(f"herdr --machine rthost {cmd}")

    def remote_rt() -> list:
        agents = json.loads(remote("agent list"))["result"]["agents"]
        return sorted(({k: a.get(k) for k in ("pane_id", "name", "agent", "agent_status", "title", "terminal_title_stripped")}
                       for a in agents if (a.get("name") or "").startswith("rt-")), key=lambda a: a["name"])

    def listing(label: str) -> list:
        local = rthost.succeed("herdr agent list | jq -c '[.result.agents[] | {name, agent_status, title}]'").strip()
        seen = remote_rt()
        print(f"=== {label}\n  rthost's own view: {local}\n  coord via --machine rthost: {json.dumps(seen)}")
        return seen

    def rec(i: str) -> dict:
        return json.loads(rthost.succeed(f"cat /var/lib/agent-runtime-herdr/{i}.json"))

    def remote_state(name: str) -> str:
        return json.loads(remote(f"agent get {name}"))["result"]["agent"]["agent_status"]

    def wait_remote(name: str, states: list, timeout: int = 30) -> None:
        want = json.dumps(states)
        coord.wait_until_succeeds(f"herdr --machine rthost agent get {name} | jq -e --argjson w '{want}' '.result.agent.agent_status as $s | $w | index($s)'", timeout=timeout)

    start_all()
    rthost.wait_for_unit("sshd.service")
    rthost.systemctl("start herdr.service")
    rthost.wait_until_succeeds("herdr agent list", timeout=30)
    coord.wait_for_unit("multi-user.target")
    coord.succeed("install -D -m 600 ${snakeOilPrivateKey} /root/.ssh/id_ed25519")
    coord.succeed("ssh -o ConnectTimeout=5 root@rthost true", timeout=60)
    print(coord.succeed("herdr --version"))

    with subtest("the coordinator saves the runtime host as a Herdr machine"):
        print(coord.succeed("herdr machine add root@rthost --label rthost --remote-session default </dev/null 2>&1"))
        machines = json.loads(coord.succeed("herdr machine list --json"))
        print("machines:", json.dumps(machines))
        assert any(m.get("label") == "rthost" for m in machines), machines
        print(coord.succeed("herdr machine status --json rthost 2>&1"))
        before = listing("before the runtimes")
        assert before == [], before

    with subtest("criterion 1 across machines: two runtimes on rthost, told apart from coord"):
        for i, tpl, ref, base in (("a1", "worker-a", "sammasak/nixos-config#901", 1048576), ("b1", "worker-b", "sammasak/skills#902", 1114112)):
            rthost.succeed(f"${prepare} {i} {base}")
            rthost.succeed(f"agent-runtime-herdr attach {i} ${evaluated.manifestDir}/{tpl}.json {ref} /var/lib/rt/{i}/output/status -- ${launch} {i} {base}")
        for name in ("rt-a1", "rt-b1"):
            wait_remote(name, ["idle", "done"])
        seen = listing("two idle runtimes")
        by = {a["name"]: a for a in seen}
        assert set(by) == {"rt-a1", "rt-b1"}, seen
        a, b = rec("a1"), rec("b1")
        for r in (a, b):
            title = by[f"rt-{r['runtime_id']}"]["title"]
            # identity, task and template digest arrive at the coordinator in the agent's `title`
            assert f"rt={r['runtime_id']}" in title and r["task_ref"] in title and r["template_digest"][:12] in title, (title, r)
        assert by["rt-a1"]["title"] != by["rt-b1"]["title"] and a["template_digest"] != b["template_digest"]
        # what herdr:inventory reads today: terminal_title_stripped is the container's own, not the correlation
        print("terminal_title_stripped (coord):", {n: x["terminal_title_stripped"] for n, x in by.items()})

    with subtest("criterion 2 through herdr:message's Herdr calls: state gate passes, prompt refused (upstream)"):
        # herdr:message: `agent get` must show idle|done, then `agent prompt <agent> <text>`
        assert remote_state("rt-a1") in ("idle", "done")
        rc, out = coord.execute("herdr --machine rthost agent prompt rt-a1 'Assignment #901: run the fixture' 2>&1")
        print("herdr --machine rthost agent prompt rt-a1:", rc, out.strip())
        assert rc != 0, "herdr agent prompt delivered to a runtime pane: the upstream gap is gone; update docs/agent-runtime-herdr.md"
        code = json.loads(out.strip().splitlines()[-1]).get("error", {}).get("code")
        assert code == "agent_not_ready", out
        rthost.succeed("test ! -e /var/lib/rt/a1/output/handoff-1.txt")
        assert len(rec("a1")["deliveries"]) == 0 and remote_state("rt-a1") in ("idle", "done")
        # what works today: the host-side gate, run on the runtime host itself
        print(rthost.succeed("agent-runtime-herdr deliver a1 'Assignment #901: run the fixture'"))
        wait_remote("rt-a1", ["working"], 10)
        print("coord sees rt-a1:", remote_state("rt-a1"))
        wait_remote("rt-a1", ["idle", "done"], 20)
        assert "Assignment #901" in rthost.succeed("cat /var/lib/rt/a1/output/handoff-1.txt")
        rthost.succeed("test ! -e /var/lib/rt/b1/output/handoff-1.txt")

    with subtest("criterion 2: a blocked or finished runtime is refused through the route before anything is sent"):
        rthost.succeed("agent-runtime-herdr deliver b1 BLOCK")
        wait_remote("rt-b1", ["blocked"], 10)
        # herdr:message fails agent_blocked on this state without prompting; herdr itself refuses as well
        assert remote_state("rt-b1") == "blocked"
        rc, out = coord.execute("herdr --machine rthost agent prompt rt-b1 'Assignment #902: should not land' 2>&1")
        print("prompt to a blocked runtime:", rc, out.strip())
        assert rc != 0
        rthost.succeed("test -z \"$(ls /var/lib/rt/b1/output | grep handoff- || true)\"")
        rthost.succeed(f"herdr pane send-text {rec('b1')['herdr']['pane_id']} UNBLOCK && herdr pane send-keys {rec('b1')['herdr']['pane_id']} Enter")
        wait_remote("rt-b1", ["idle", "done"], 10)
        rthost.succeed("agent-runtime-herdr deliver b1 EXIT")
        rthost.wait_until_succeeds("jq -e '.status == \"finished\"' /var/lib/agent-runtime-herdr/b1.json", timeout=20)
        coord.wait_until_succeeds("! herdr --machine rthost agent list | jq -e '.result.agents[] | select(.name == \"rt-b1\")'", timeout=20)
        rc, out = coord.execute("herdr --machine rthost agent get rt-b1 2>&1")
        print("agent get on a finished runtime:", rc, out.strip())
        assert rc != 0, "a finished runtime is still an agent"
        listing("after b1 finished")

    with subtest("an unreachable runtime host is an error at the coordinator, not an empty fleet"):
        # Herdr keeps its SSH connection to a saved machine: stopping sshd leaves an established session
        # answering, so the sessions go too, as when the host or its network goes away
        rthost.succeed("systemctl stop sshd.service sshd.socket 2>/dev/null || systemctl stop sshd.service")
        rthost.succeed("pkill -KILL -f '^sshd' || true")
        rc, out = coord.execute("timeout 60 herdr --machine rthost agent list 2>&1")
        print("agent list with rthost unreachable:", rc, out.strip()[-300:])
        assert rc != 0
        rthost.succeed("systemctl start sshd.service")
        rthost.wait_for_unit("sshd.service")
        coord.wait_until_succeeds("herdr --machine rthost agent list", timeout=60)

    with subtest("teardown: nothing of either runtime is listed from either node"):
        for i in ("a1", "b1"):
            print(rthost.succeed(f"agent-runtime-herdr detach {i}"))
            rthost.succeed(f"${destroy} {i}")
        after = listing("after teardown")
        assert after == [], after
        rthost.succeed("! machinectl list --no-legend | grep -q rt-")
        rthost.succeed("! systemctl list-units --all --no-legend 'rt-*' 'agent-runtime-herdr-follow-*' | grep -q .")
  '';
}
