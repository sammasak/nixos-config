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
{ pkgs, lib, skills }:
let
  inherit (import ./agent-runtime-herdr-fixture.nix { inherit pkgs lib skills; })
    evaluated adapter launch prepare destroy;
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs) snakeOilPrivateKey snakeOilPublicKey;
  hostKeyFor = name: pkgs.runCommand "${name}-host-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out; ssh-keygen -q -t ed25519 -N "" -C ${name} -f $out/key
  '';
  acerKey = hostKeyFor "acer";
  msiKey = hostKeyFor "msi";
  # a runtime host as acer-swift / msi-ms7758 are: own Herdr server, reached over SSH with a pinned key
  rtHost = hostKey: {
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
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-herdr-fleet";

  nodes = {
    acer = rtHost acerKey;
    msi = rtHost msiKey;
    # the coordinator host, as lenovo is: no runtimes, two saved machines, host keys pinned
    coord = {
      environment.systemPackages = [ pkgs.herdr pkgs.jq ];
      programs.ssh.knownHosts.acer.publicKeyFile = "${acerKey}/key.pub";
      programs.ssh.knownHosts.msi.publicKeyFile = "${msiKey}/key.pub";
      programs.ssh.extraConfig = "StrictHostKeyChecking yes";
    };
  };

  testScript = ''
    import json

    MANIFESTS = "${evaluated.manifestDir}"

    def ssh_ok(host: str) -> None:
        coord.succeed(f"ssh -o ConnectTimeout=5 root@{host} true", timeout=60)

    # The coordinator's herdr:inventory rollup, reduced to its Herdr calls: for every saved
    # machine, `herdr --machine <label> agent list`; a machine that does not answer is an offline
    # row (an error), never an empty fleet; each runtime's five fields come from its Herdr `title`
    # (OWNER/REPO#N rt=<id> tpl=<digest12>), never terminal_title_stripped (the container's own).
    def fleet() -> dict:
        labels = sorted(m["label"] for m in json.loads(coord.succeed("herdr machine list --json")))
        rows, offline = [], []
        for label in labels:
            rc, out = coord.execute(f"timeout 30 herdr --machine {label} agent list 2>&1")
            if rc != 0:
                offline.append(label); continue
            for a in json.loads(out)["result"]["agents"]:
                name = a.get("name") or ""
                if not name.startswith("rt-"):
                    continue
                title = a.get("title") or ""
                ref = title.split(" rt=")[0] if " rt=" in title else None
                rid = title.split(" rt=")[1].split(" ")[0] if " rt=" in title else None
                tpl = title.split(" tpl=")[1].split(" ")[0] if " tpl=" in title else None
                rows.append({"host": label, "runtime_id": rid, "task_ref": ref, "template": tpl,
                             "status": a.get("agent_status"), "reason": a.get("message"),
                             "name": name, "terminal_title_stripped": a.get("terminal_title_stripped")})
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
    coord.succeed("install -D -m 600 ${snakeOilPrivateKey} /root/.ssh/id_ed25519")
    ssh_ok("acer"); ssh_ok("msi")
    print(coord.succeed("herdr --version"))

    with subtest("the coordinator saves both worker hosts as Herdr machines (strict host keys)"):
        coord.succeed("herdr machine add root@acer --label acer --remote-session default </dev/null 2>&1")
        coord.succeed("herdr machine add root@msi --label msi --remote-session default </dev/null 2>&1")
        labels = sorted(m["label"] for m in json.loads(coord.succeed("herdr machine list --json")))
        assert labels == ["acer", "msi"], labels
        v = fleet()
        assert v == {"rows": [], "offline": []}, v

    with subtest("two runtimes that share the instance id `coder` are told apart by host, task and template"):
        # both hosts run an instance literally named `coder`; nothing but the host distinguishes the id
        acer.succeed("${prepare} coder 1048576")
        acer.succeed(f"agent-runtime-herdr attach coder {MANIFESTS}/worker-a.json sammasak/nixos-config#901 /var/lib/rt/coder/output/status -- ${launch} coder 1048576")
        msi.succeed("${prepare} coder 1048576")
        msi.succeed(f"agent-runtime-herdr attach coder {MANIFESTS}/worker-b.json sammasak/skills#902 /var/lib/rt/coder/output/status -- ${launch} coder 1048576")
        wait_remote("acer", "rt-coder", ["idle", "done"])
        wait_remote("msi", "rt-coder", ["idle", "done"])
        v = fleet()
        rows = v["rows"]
        assert v["offline"] == [] and len(rows) == 2, v
        # every row carries all five fields, and the two `coder`s are distinct by host
        for r in rows:
            assert r["runtime_id"] == "coder" and r["task_ref"] and r["template"] and r["status"] in ("idle", "done"), r
        a = next(r for r in rows if r["host"] == "acer")
        m = next(r for r in rows if r["host"] == "msi")
        assert a["task_ref"] == "sammasak/nixos-config#901" and m["task_ref"] == "sammasak/skills#902", rows
        assert a["template"] != m["template"], rows   # worker-a vs worker-b digests
        assert (a["host"], a["runtime_id"]) != (m["host"], m["runtime_id"]) or a["host"] != m["host"]
        # the correlation is the Herdr title, not terminal_title_stripped (the container's own name)
        assert a["task_ref"] not in (a["terminal_title_stripped"] or ""), a
        print("per-host coder correlation OK:", json.dumps([a, m]))

    with subtest("a launcher-started runtime shows through its status mirror with its non-secret blocked reason"):
        # a status mirror of an instance started by the trusted launcher (not a pane launch): the
        # root-written 0644 mirror.status is the only input, and the follower never prompts or launches
        msi.succeed("mkdir -p /run/agent-runtime/m1")
        msi.succeed("printf '%s' '{\"state\":\"blocked\",\"outcome\":\"\",\"reason\":\"waiting on owner approval for #903\"}' > /run/agent-runtime/m1/mirror.status")
        msi.succeed("chmod 0644 /run/agent-runtime/m1/mirror.status")
        msi.succeed(f"agent-runtime-herdr attach m1 {MANIFESTS}/worker-b.json sammasak/nixos-config#903 /run/agent-runtime/m1/mirror.status --mirror")
        assert rec(msi, "m1")["mirror"] is True, rec(msi, "m1")
        wait_remote("msi", "rt-m1", ["blocked"])
        v = fleet()
        mrow = next(r for r in v["rows"] if r["host"] == "msi" and r["name"] == "rt-m1")
        assert mrow["status"] == "blocked" and mrow["task_ref"] == "sammasak/nixos-config#903", mrow
        assert "waiting on owner approval" in (mrow["reason"] or ""), mrow   # the non-secret blocked reason crosses hosts
        # a mirror refuses a prompt/deliver outright (never accepts work, never launches a second instance)
        rc, out = msi.execute("agent-runtime-herdr deliver m1 'should not land' 2>&1")
        assert rc == 75, (rc, out)
        # working then idle transitions are followed from the root-written mirror
        msi.succeed("printf '%s' '{\"state\":\"running\",\"outcome\":\"\",\"reason\":\"\"}' > /run/agent-runtime/m1/mirror.status")
        wait_remote("msi", "rt-m1", ["working"])
        msi.succeed("printf '%s' '{\"state\":\"succeeded\",\"outcome\":\"succeeded\",\"reason\":\"\"}' > /run/agent-runtime/m1/mirror.status")
        wait_remote("msi", "rt-m1", ["idle", "done"])
        print("mirror transitions blocked->working->idle OK")

    with subtest("a Herdr restart on a worker reconciles its runtimes (never re-assigns, never lost->unknown)"):
        msi.systemctl("restart herdr.service")
        msi.wait_until_succeeds("herdr agent list", timeout=30)
        msi.succeed("agent-runtime-herdr reconcile")
        msi.wait_until_succeeds("herdr --version", timeout=10)
        wait_remote("msi", "rt-coder", ["idle", "done"])
        v = fleet()
        assert any(r["host"] == "msi" and r["name"] == "rt-coder" for r in v["rows"]), v

    with subtest("msi outside its power window is an offline error row, not a vanished runtime or false idle"):
        # Herdr holds its SSH session to a saved machine; dropping sshd and the established session is the
        # host/network going away, exactly the MSI 09:00-21:00 power window closing
        msi.succeed("systemctl stop sshd.service sshd.socket 2>/dev/null || systemctl stop sshd.service")
        msi.succeed("pkill -KILL -f '^sshd' || true")
        v = fleet()
        assert "msi" in v["offline"], v                                   # surfaced as offline, not empty
        assert any(r["host"] == "acer" and r["name"] == "rt-coder" for r in v["rows"]), v   # acer still visible
        assert not any(r["host"] == "msi" for r in v["rows"]), v          # msi runtimes are not falsely listed idle
        msi.succeed("systemctl start sshd.service"); msi.wait_for_unit("sshd.service")
        coord.wait_until_succeeds("herdr --machine msi agent list", timeout=60)
        v = fleet()
        assert v["offline"] == [] and any(r["host"] == "msi" for r in v["rows"]), v   # online again, no false absence

    with subtest("teardown leaves nothing of any runtime on any node, and the fleet view is empty"):
        acer.succeed("agent-runtime-herdr detach coder"); acer.succeed("${destroy} coder")
        for i in ("coder", "m1"):
            msi.succeed(f"agent-runtime-herdr detach {i}")
        msi.succeed("${destroy} coder")
        v = fleet()
        assert v["rows"] == [] and v["offline"] == [], v
        for h in (acer, msi):
            h.succeed("! machinectl list --no-legend | grep -q rt-")
            h.succeed("! systemctl list-units --all --no-legend 'rt-*' 'agent-runtime-herdr-follow-*' | grep -q .")
  '';
}
