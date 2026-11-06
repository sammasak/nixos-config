# #169: allowlist egress to an OFF-HOST endpoint, the path the live coder run needed (api.anthropic.com
# from acer). #159's egress tests reached endpoints on the runtime host itself (nft input); a real API
# host is reached by forwarding, which needs source NAT, or the reply to the instance's private 10.x
# address never comes back and the connect hangs, as the live run did for 600 s. Two VMs: the runtime
# host, and `remote` serving HTTPS on 443 as remote.test, with no route back to the instance subnet.
# Offline, no credential (a dummy token for the runner probe).
#   nix build .#packages.x86_64-linux.agent-runtime-egress-forward-test
{ pkgs, lib, rfProto, skills }:
let
  # claude-code is unfree: allowed by name for this evaluation only, as the hosts allow it
  pkgsU = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = p: lib.getName p == "claude-code";
  };
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib; pkgs = pkgsU; };
  fetch = pkgsU.writeShellScriptBin "egress-fetch" ''
    # wait for the host's go, then one bounded HTTPS request to the allowlisted name
    while [ ! -e "$TMPDIR/go" ]; do sleep 0.2; done
    rc=0
    curl -sk --max-time 8 -o "$AGENT_RUNTIME_OUTPUT/body" https://remote.test/ || rc=$?
    echo "$rc" >"$AGENT_RUNTIME_OUTPUT/curl-rc"
  '';
  fwd = {
    role = { name = "quality"; harness = "codex"; };
    skillsSource = skills;
    skills.lean-code = { };
    packages = [ fetch pkgsU.curl pkgsU.bash pkgsU.coreutils ];
    network.allow = [ "remote.test" ];
    filesystem = {
      workspaceBudget = { sizeMiB = 16; inodes = 1000; };
      home = { sizeMiB = 16; inodes = 1000; };
      tmp = { sizeMiB = 16; inodes = 1000; };
      cache = { sizeMiB = 16; inodes = 1000; };
      output = { sizeMiB = 16; inodes = 1000; };
    };
    resources = { cpus = 1; memoryMiB = 128; tasksMax = 64; timeoutMinutes = 5; };
  };
  evaluated = runtime.evalManifests {
    modules = [
      ../modules/agent-runtime/templates/claude-coder.nix
      {
        sam.agentRuntime.pinnedSources = { rf-proto = rfProto; inherit skills; };
        sam.agentRuntime.templates.fwd = fwd;
        # the coder's allowlist points at the test endpoint instead of api.anthropic.com
        sam.agentRuntime.templates.claude-coder.network.allow = [ "remote.test" ];
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "fwd" "claude-coder" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 256; diskMiB = 512; };
        };
      }
    ];
  };
  M = "${evaluated.manifestDir}/fwd.json";
  C = "${evaluated.manifestDir}/claude-coder.json";
  I = lib.getExe runtime.tools.instance;
  coderRun = lib.getExe (builtins.head evaluated.templates.claude-coder.packages);
  env = pkgsU.buildEnv { name = "agent-runtime-egress-env"; paths = fwd.packages ++ evaluated.templates.claude-coder.packages; };
  cert = pkgs.runCommand "remote-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj /CN=remote.test \
      -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-egress-forward";
  nodes = {
    # the API endpoint: off the runtime host, no route to the instance subnet (only the vlan)
    remote = {
      networking.firewall.allowedTCPPorts = [ 443 ];
      services.nginx = {
        enable = true;
        virtualHosts."remote.test" = {
          onlySSL = true;
          sslCertificate = "${cert}/cert.pem";
          sslCertificateKey = "${cert}/key.pem";
          locations."/".return = "200 'remote-ok'";
        };
      };
    };
    machine = { nodes, ... }: {
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      virtualisation.diskSize = 4096;
      boot.kernel.sysctl."vm.panic_on_oom" = 0;
      # acer forwards (k3s); the runtime checks it instead of setting it
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      networking.firewall.enable = false;
      networking.dhcpcd.denyInterfaces = [ "ve-*" ];
      networking.hosts.${nodes.remote.networking.primaryIPAddress} = [ "remote.test" ];
      virtualisation.additionalPaths = [ rfProto skills env evaluated.manifestDir ];
      environment.systemPackages = with pkgs; [ util-linux procps gnugrep gawk coreutils jq nftables iproute2 ];
    };
  };
  testScript = ''
    import json
    V = "/var/lib/agent-runtime"
    POLICY = "${evaluated.hostPolicy}"
    TASK = "sammasak/nixos-config#169"

    def st(i):
        return json.loads(machine.succeed(f"${I} status {i}"))

    def out(i, f):
        return machine.succeed(f"cat {V}/{i}/vol/output/{f}").strip()

    start_all()
    remote.wait_for_unit("nginx.service")
    remote.wait_for_open_port(443)
    machine.wait_for_unit("multi-user.target")
    print("host route to remote:", machine.succeed("ip route get $(getent ahostsv4 remote.test | awk '{print $1; exit}')").strip())
    print("remote's routes (no way back to 10.x):", remote.succeed("ip route").strip().replace("\n", " | "))
    machine.succeed("curl -sk --max-time 5 https://remote.test/ | grep -q remote-ok")

    with subtest("without source NAT (the live state before the fix) an off-host allowlisted HTTPS endpoint never answers"):
        machine.succeed(f"${I} create nonat --template ${M} --host {POLICY} --task {TASK}")
        machine.succeed("${I} start nonat -- egress-fetch")
        machine.wait_until_succeeds("nft list table inet art_nonat", timeout=60)
        print(machine.succeed("nft list table inet art_nonat"))
        # take out only the masquerade the fix adds: the filter (allowlist) stays as #159 shipped it
        machine.succeed("nft delete chain inet art_nonat postrouting")
        machine.succeed(f"touch {V}/nonat/vol/tmp/go")
        machine.wait_until_succeeds(f"test -s {V}/nonat/vol/output/curl-rc", timeout=60)
        rc = out("nonat", "curl-rc")
        print("curl from the instance without NAT: rc", rc)
        assert rc == "28", rc  # operation timed out: the SYN left, no reply came back
        machine.wait_until_succeeds("${I} status nonat | jq -e '.state | IN(\"succeeded\", \"failed\")'", timeout=60)
        machine.succeed("${I} destroy nonat --discard")

    with subtest("with the per-instance masquerade the same request succeeds; teardown removes it"):
        machine.succeed(f"${I} create nat --template ${M} --host {POLICY} --task {TASK}")
        machine.succeed("${I} start nat -- egress-fetch")
        machine.wait_until_succeeds("nft list chain inet art_nat postrouting | grep -q masquerade", timeout=60)
        print(machine.succeed("nft list chain inet art_nat postrouting"))
        machine.succeed(f"touch {V}/nat/vol/tmp/go")
        machine.wait_until_succeeds(f"test -s {V}/nat/vol/output/curl-rc", timeout=60)
        rc, body = out("nat", "curl-rc"), out("nat", "body")
        print("curl from the instance with NAT: rc", rc, "body", body)
        assert rc == "0" and body == "remote-ok", (rc, body)
        machine.wait_until_succeeds("${I} status nat | jq -e '.state == \"succeeded\"'", timeout=60)
        machine.succeed("${I} destroy nat --discard")
        machine.fail("nft list table inet art_nat")

    with subtest("allowlist egress fails closed, before anything starts, when the host does not forward"):
        machine.succeed(f"${I} create nofwd --template ${M} --host {POLICY} --task {TASK}")
        machine.succeed("sysctl -w net.ipv4.ip_forward=0")
        rc, o = machine.execute("${I} start nofwd -- egress-fetch 2>&1")
        machine.succeed("sysctl -w net.ipv4.ip_forward=1")
        print("start without forwarding:", rc, o.strip()[-300:])
        assert rc != 0 and "needs IPv4 forwarding" in o, (rc, o)
        assert st("nofwd")["state"] == "created", st("nofwd")
        machine.fail("nft list table inet art_nofwd")
        machine.succeed("${I} destroy nofwd --discard")

    with subtest("the coder runner fails fast with a clear error when a pinned egress host never answers"):
        machine.succeed("printf 'sk-ant-oat01-DUMMY-egress-169' > /root/dummy-token && chmod 600 /root/dummy-token")
        # replies from remote to the host (the NATed source) are dropped: the connect hangs, as live
        host_ip = machine.succeed("getent ahostsv4 remote.test >/dev/null; ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        remote.succeed(f"ip route add blackhole {host_ip}/32")
        machine.succeed(f"${I} create probe --template ${C} --host {POLICY} --task {TASK}")
        machine.execute("${I} start probe --credential /root/dummy-token --wait -- ${coderRun} --turn-seconds 120 'add a function'")
        remote.succeed(f"ip route del blackhole {host_ip}/32")
        s = st("probe")
        print("coder with an unreachable pinned host:", json.dumps(s["result"]))
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 75, s
        assert s["result"]["runtimeUSec"] < 60_000_000, s  # seconds, not the 120 s turn bound
        r = json.loads(out("probe", "result.json"))
        assert r["egress"] == "unreachable" and r["host"] == "remote.test" and r["claudeExit"] is None, r
        machine.succeed(f"test ! -s {V}/probe/vol/output/claude.json")
        machine.succeed("${I} export probe")
        machine.succeed(f"! grep -rqF DUMMY-egress-169 {V}/exports/probe")
        machine.succeed("${I} destroy probe")
        machine.succeed("! findmnt -rn | grep -q agent-runtime")
        machine.succeed("! nft list tables | grep -q art_")
  '';
}
