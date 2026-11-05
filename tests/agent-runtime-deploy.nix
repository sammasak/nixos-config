# #140: deploy-rs pushes the agent-runtime substrate (a system profile) and a
# pinned template profile to two VM hosts with different NixOS configurations
# and one shared template module, from a third VM, the way lenovo pushes to the
# homelab: as `deploy` with sudo, pinned host keys, auto and magic rollback.
# Runs only in QEMU: nix build .#packages.x86_64-linux.agent-runtime-deploy-test
{ pkgs, lib, deployRs, skills }:
let
  deployLib = deployRs.lib.x86_64-linux;
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  templates = version: import ./agent-runtime/deploy-templates.nix { inherit skills version; };
  policy = {
    hosta = { maxConcurrentInstances = 2; reserve = { memoryMiB = 512; diskMiB = 256; }; };
    hostb = { maxConcurrentInstances = 1; reserve = { memoryMiB = 640; diskMiB = 512; }; };
  };
  enable = name: { sam.agentRuntime.host = { enable = true; eligibleTemplates = [ "tiny" ]; } // policy.${name}; };
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs) snakeOilPrivateKey snakeOilPublicKey;
  hostKeys = pkgs.runCommand "agent-runtime-deploy-host-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    for h in hosta hostb; do ssh-keygen -q -t ed25519 -N "" -C "$h" -f "$out/$h"; done
  '';

  target =
    name:
    { pkgs, ... }:
    {
      imports = [ ../modules/agent-runtime/host.nix (templates 1) ];
      virtualisation = { memorySize = 1536; diskSize = 2048; };
      # test-instrumentation's mkDefault 2 panics the VM on any cgroup OOM; hosts run the kernel's 0
      boot.kernel.sysctl."vm.panic_on_oom" = 0;
      environment.systemPackages = [ pkgs.jq ];
      # the test's payloads, rooted by the system so the GC subtest cannot take them (a real
      # payload comes from the template's packages, which the template roots)
      environment.etc."agent-runtime-test/hold".source = hold;
      services.openssh = {
        enable = true;
        hostKeys = [ { path = "/etc/ssh/test_host_ed25519_key"; type = "ed25519"; } ];
      };
      environment.etc."ssh/test_host_ed25519_key" = { source = "${hostKeys}/${name}"; mode = "0600"; };
      users.users.deploy = { isNormalUser = true; openssh.authorizedKeys.keys = [ snakeOilPublicKey ]; };
      security.sudo.extraRules = [ { users = [ "deploy" ]; commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ]; } ];
      # the homelab accepts lenovo's signed closures (nix-signing-key); the test trusts `deploy` instead
      nix.settings.trusted-users = [ "root" "deploy" ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      nix.settings.substituters = lib.mkForce [ ];
      # what deploy-rs pushes as the system profile: the substrate, and the substrate with a unit
      # that fails to start (switch-to-configuration then fails and deploy-rs must roll back)
      specialisation.substrate.configuration = enable name;
      specialisation.broken.configuration = enable name // {
        systemd.services.agent-runtime-broken-unit = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.coreutils}/bin/false"; };
        };
      };
    };

  # every profile a step pushes, by node: deploy-rs builds `drvPath` (already realised in the
  # deployer's store, so nothing builds in the VM) and copies `path`
  steps =
    nodes:
    let
      system = name: spec: deployLib.activate.nixos { config = nodes.${name}.specialisation.${spec}.configuration; };
      tpl =
        name: version: substrateSchema:
        deployLib.activate.custom (runtime.templateProfile {
          agentRuntime = runtime.evalManifests { modules = [ (templates version) (enable name) ]; };
          inherit substrateSchema;
        }) "$PROFILE/bin/agent-runtime-templates-activate";
    in
    {
      substrate = { hosta.system = system "hosta" "substrate"; hostb.system = system "hostb" "substrate"; };
      broken.hosta.system = system "hosta" "broken";
      tpl1 = { hosta.agent-runtime = tpl "hosta" 1 1; hostb.agent-runtime = tpl "hostb" 1 1; };
      tpl2.hosta.agent-runtime = tpl "hosta" 2 1;
      # templates that need a substrate the hosts do not have: the activation refuses them
      tpl-bad.hosta.agent-runtime = tpl "hosta" 3 2;
      tpl3 = { hosta.agent-runtime = tpl "hosta" 3 1; hostb.agent-runtime = tpl "hostb" 3 1; };
    };
  # deploy-rs builds each profile's drvPath before it copies it. The deployer evaluates a wrapper
  # per profile from the profile already in its store (builtins.storePath; deploy-rs evaluates in
  # read-write mode, so the drv is written in the VM) with nix's in-process builder, the one
  # nix-env builds profiles with: no build-time closure and no exec, which the VM's landlock
  # confinement of local builds kills (signal 9) for a store binary.
  deployFile = pkgs.writeText "default.nix" ''
    let
      # readFile of a store file carries its references, which fromJSON refuses
      data = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile ./deploy.json));
      wrap =
        name: path:
        derivation {
          name = "deploy-''${name}";
          system = "builtin";
          builder = "builtin:buildenv";
          manifest = builtins.toFile "manifest.nix" "[ ]";
          derivations = [ "true" 5 1 (builtins.storePath path) ];
          preferLocalBuild = true;
          allowSubstitutes = false;
        };
      profile = name: p: let w = wrap name p.path; in p // { path = w.outPath; drvPath = w.drvPath; };
    in
    {
      deploy = data // { nodes = builtins.mapAttrs (_: n: n // { profiles = builtins.mapAttrs profile n.profiles; }) data.nodes; };
    }
  '';
  stepData =
    nodes:
    let
      profile = name: p: { path = "${p}"; } // lib.optionalAttrs (name == "agent-runtime") { profilePath = "/nix/var/nix/profiles/agent-runtime/templates"; };
      node = name: profiles: {
        hostname = name;
        sshUser = "deploy";
        user = "root";
        sshOpts = [ "-o" "StrictHostKeyChecking=yes" "-o" "ConnectTimeout=5" ];
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 120;
        confirmTimeout = 30;
        profilesOrder = lib.filter (p: profiles ? ${p}) [ "system" "agent-runtime" ];
        profiles = lib.mapAttrs profile profiles;
      };
    in
    pkgs.runCommand "agent-runtime-deploy-steps" { } (
      lib.concatStrings (
        lib.mapAttrsToList (step: nodesOf: ''
          mkdir -p $out/${step}
          cp ${pkgs.writeText "deploy.json" (builtins.toJSON { nodes = lib.mapAttrs node nodesOf; })} $out/${step}/deploy.json
          cp ${deployFile} $out/${step}/default.nix
        '') (steps nodes)
      )
    );

  hold = pkgs.writeShellScript "agent-hold" ''
    touch /workspace/ready
    while [ ! -e /workspace/go ]; do sleep 0.2; done
    command -v hello && hello || echo "no hello in this template"
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-runtime-deploy";

  nodes = {
    hosta = target "hosta";
    hostb = target "hostb";
    deployer =
      { nodes, ... }:
      {
        environment.systemPackages = [ deployRs.packages.x86_64-linux.default ];
        environment.etc."agent-runtime-deploy".source = stepData nodes;
        virtualisation.additionalPaths = [ (stepData nodes) ];
        virtualisation.memorySize = 2048;
        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          # offline VM: no cache to ask, and the only builds are one-symlink wrappers
          substituters = lib.mkForce [ ];
          sandbox = false;
        };
        programs.ssh.knownHosts = lib.genAttrs [ "hosta" "hostb" ] (h: { publicKeyFile = "${hostKeys}/${h}.pub"; });
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import json, time
      SYS = "/nix/var/nix/profiles/system"
      TPL = "/nix/var/nix/profiles/agent-runtime/templates"
      I = "agent-runtime-instance"
      hosts = {"hosta": hosta, "hostb": hostb}
      substrate = {"hosta": "${nodes.hosta.specialisation.substrate.configuration.system.build.toplevel}",
                   "hostb": "${nodes.hostb.specialisation.substrate.configuration.system.build.toplevel}"}

      def deploy(step: str, *targets: str) -> tuple[int, str]:
          rc, out = deployer.execute(f"deploy --file /etc/agent-runtime-deploy/{step} --skip-checks --targets {' '.join(targets)} 2>&1")
          print(f"=== deploy {step} {' '.join(targets)}: exit {rc}"); print(out[-3000:])
          if rc != 0:
              print(deployer.succeed("journalctl -b -u nix-daemon --no-pager | tail -15; dmesg | tail -10"))
          return rc, out

      def gens(m, profile: str) -> str:
          return m.succeed(f"nix-env --list-generations -p {profile} 2>/dev/null || echo '(no generations)'").strip()

      def current(m, profile: str) -> str:
          return m.succeed(f"readlink -f {profile} 2>/dev/null || echo none").strip()

      def digest(m, path: str) -> str:
          return m.succeed(f"jq -r .digests.template {path}").strip()

      def state(m, label: str) -> dict[str, str]:
          s = {"system": current(m, SYS), "running": m.succeed("readlink -f /run/current-system").strip(),
               "system_gens": gens(m, SYS), "templates": current(m, TPL), "template_gens": gens(m, TPL)}
          print(f"--- {m.name} {label}:", json.dumps(s, indent=1))
          return s

      def run(m, i: str, script: str) -> dict:
          m.succeed(f"{I} create {i} --template {TPL}/templates/tiny.json --task t-{i}")
          m.execute(f"{I} start {i} --wait -- {script}")
          s = json.loads(m.succeed(f"{I} status {i}"))
          print(f"== {m.name}/{i}: {s['state']}", m.succeed(f"{I} logs {i}")[-500:])
          return s

      start_all()
      for m in hosts.values():
          m.wait_for_unit("sshd.service")
      deployer.wait_for_unit("multi-user.target")
      deployer.succeed("install -D -m 600 ${snakeOilPrivateKey} /root/.ssh/id_ed25519")
      for h in hosts:
          # pinned host keys only: an unknown key is refused, never accepted on first use
          deployer.succeed(f"ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 deploy@{h} 'sudo -n true'", timeout=60)
      print(deployer.succeed("deploy --version"))
      print("nixpkgs ${pkgs.lib.version}")

      with subtest("the hosts start without the substrate"):
          for m in hosts.values():
              m.fail(f"command -v {I}")
              m.fail("test -e /etc/agent-runtime")

      with subtest("deploy-rs pushes the substrate as each host's system profile"):
          rc, out = deploy("substrate", "hosta.system", "hostb.system")
          assert rc == 0, out
          for h, m in hosts.items():
              s = state(m, "after the substrate")
              assert s["running"] == substrate[h], s
              m.succeed(f"command -v {I}")
              print(m.succeed("cat /etc/agent-runtime/substrate.json /etc/agent-runtime/host.json"))
          assert json.loads(hosta.succeed("cat /etc/agent-runtime/host.json"))["maxConcurrentInstances"] == 2
          assert json.loads(hostb.succeed("cat /etc/agent-runtime/host.json"))["maxConcurrentInstances"] == 1
      base = {h: state(m, "baseline") for h, m in hosts.items()}

      with subtest("templates v1 on both hosts: one template module, two host configurations"):
          rc, out = deploy("tpl1", "hosta.agent-runtime", "hostb.agent-runtime")
          assert rc == 0 and "templates active" in out, out
          v1 = digest(hosta, f"{TPL}/templates/tiny.json")
          assert v1 == digest(hostb, f"{TPL}/templates/tiny.json"), "the same template digest on both hosts"
          for h, m in hosts.items():
              s = run(m, f"first-{h}", "${pkgs.coreutils}/bin/true")
              assert s["state"] == "succeeded" and s["template"]["digests"]["template"] == v1, s
              m.succeed(f"{I} destroy first-{h} --discard")
              assert state(m, "after v1 and a run")["system"] == base[h]["system"], "a template deploy or a run moved the system"

      with subtest("template v2 while an instance runs: the instance keeps v1, a new one gets v2, no host switch"):
          hosta.succeed(f"{I} create inflight --template {TPL}/templates/tiny.json --task t-inflight")
          hosta.succeed(f"{I} start inflight -- ${hold}")
          hosta.wait_until_succeeds("test -e /var/lib/agent-runtime/inflight/vol/workspace/workspace/ready", timeout=30)
          v1_manifest = json.loads(hosta.succeed(f"{I} status inflight"))["template"]["manifest"]
          rc, out = deploy("tpl2", "hosta.agent-runtime")
          assert rc == 0, out
          v2 = digest(hosta, f"{TPL}/templates/tiny.json")
          assert v2 != v1
          assert json.loads(hosta.succeed(f"{I} status inflight"))["state"] == "running"
          hosta.succeed(f"{I} create after-v2 --template {TPL}/templates/tiny.json --task t-after-v2")
          assert json.loads(hosta.succeed(f"{I} status after-v2"))["template"]["digests"]["template"] == v2
          after = state(hosta, "after v2")
          assert after["system"] == base["hosta"]["system"] and after["running"] == base["hosta"]["running"], after
          # GC during the in-flight job keeps its template closure
          print(hosta.succeed("nix-collect-garbage -d 2>&1 | tail -3"))
          hosta.succeed(f"test -e {v1_manifest}")
          print("v1 manifest kept by", hosta.succeed("readlink /var/lib/agent-runtime/inflight/template-root"))
          hosta.succeed("touch /var/lib/agent-runtime/inflight/vol/workspace/workspace/go")
          s = json.loads(hosta.succeed(f"{I} wait inflight --timeout-sec 30"))
          assert s["state"] == "succeeded", s
          assert "no hello" in hosta.succeed(f"{I} logs inflight")
          hosta.succeed(f"{I} destroy inflight --discard")
          hosta.succeed(f"nix-store --delete {v1_manifest}")
          print("v1 manifest collected once its instance was destroyed")
          hosta.succeed(f"{I} start after-v2 -- ${hold}")
          hosta.wait_until_succeeds("test -e /var/lib/agent-runtime/after-v2/vol/workspace/workspace/ready", timeout=30)
          hosta.succeed("touch /var/lib/agent-runtime/after-v2/vol/workspace/workspace/go")
          hosta.succeed(f"{I} wait after-v2 --timeout-sec 30")
          assert "Hello, world!" in hosta.succeed(f"{I} logs after-v2")
          hosta.succeed(f"{I} destroy after-v2 --discard")

      with subtest("a failed template activation is rolled back; admission keeps the previous templates"):
          before = state(hosta, "before the bad templates")
          rc, out = deploy("tpl-bad", "hosta.agent-runtime")
          assert rc != 0 and "need substrate schemaVersion 2" in out, out
          after = state(hosta, "after the bad templates")
          assert after["templates"] == before["templates"], (before, after)
          assert digest(hosta, f"{TPL}/templates/tiny.json") == v2
          s = run(hosta, "post-bad", "${pkgs.coreutils}/bin/true")
          assert s["state"] == "succeeded" and s["template"]["digests"]["template"] == v2, s
          hosta.succeed(f"{I} destroy post-bad --discard")

      with subtest("a failed substrate activation is rolled back to the previous system generation"):
          before = state(hosta, "before the broken substrate")
          rc, out = deploy("broken", "hosta.system")
          assert rc != 0 and "rolled back to previous generation" in out, out
          # deploy-rs re-activates the previous generation on the host after the client has returned
          t0 = time.monotonic()
          hosta.wait_until_succeeds(f"test $(readlink -f /run/current-system) = {before['running']}", timeout=120)
          print(f"previous system running again {time.monotonic() - t0:.1f} s after deploy returned")
          after = state(hosta, "after the broken substrate")
          assert after["system"] == before["system"] and after["running"] == before["running"], (before, after)
          hosta.fail("systemctl is-active agent-runtime-broken-unit.service")
          hosta.succeed(f"{I} status")

      with subtest("SSH failure in a fleet deploy: no host takes the new templates"):
          before = {h: state(m, "before the fleet deploy") for h, m in hosts.items()}
          hostb.succeed("systemctl stop sshd.service sshd.socket 2>/dev/null || systemctl stop sshd.service")
          rc, out = deploy("tpl3", "hosta.agent-runtime", "hostb.agent-runtime")
          assert rc != 0, out
          for h, m in hosts.items():
              assert current(m, TPL) == before[h]["templates"], (h, "took the new templates in a failed fleet deploy")
          hostb.succeed("systemctl start sshd.service")
          hostb.wait_for_unit("sshd.service")

      with subtest("host offline: the deploy fails within the connect timeout and changes nothing"):
          hostb.succeed("ip link set eth1 down")
          rc, out = deploy("tpl3", "hostb.agent-runtime")
          assert rc != 0, out
          hostb.succeed("ip link set eth1 up")
          deployer.wait_until_succeeds("ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 deploy@hostb true", timeout=60)
          assert current(hostb, TPL) == before["hostb"]["templates"]

      with subtest("the whole fleet then takes v3; the systems never moved"):
          rc, out = deploy("tpl3", "hosta.agent-runtime", "hostb.agent-runtime")
          assert rc == 0, out
          v3 = digest(hosta, f"{TPL}/templates/tiny.json")
          assert v3 == digest(hostb, f"{TPL}/templates/tiny.json") and v3 not in (v1, v2)
          for h, m in hosts.items():
              s = state(m, "at the end")
              assert s["system"] == base[h]["system"] and s["running"] == base[h]["running"], s
              r = run(m, f"last-{h}", "${pkgs.coreutils}/bin/true")
              assert r["state"] == "succeeded" and r["template"]["digests"]["template"] == v3, r
              m.succeed(f"{I} destroy last-{h} --discard")
              assert json.loads(m.succeed(f"{I} status")) == []
              m.succeed("! systemctl list-units --all --no-legend 'agent-runtime-*' | grep -q .")
              m.succeed("! findmnt -rn | grep -q agent-runtime")
    '';
}
