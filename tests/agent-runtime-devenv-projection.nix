# devenv-platform#93: the complete generated Devenv environment and enterShell
# output are captured on the host and activated only inside the existing nspawn
# runtime. The env JSON and its profile are inputs to this test via the focused
# script, which runs `devenv print-dev-env --json` before building this VM test.
{ pkgs, lib, envJsonPath, profilePath, skills }:
let
  envJson = builtins.storePath envJsonPath;
  profile = builtins.storePath profilePath;
  fixtureSrc = pkgs.runCommandLocal "native-devenv-projection-fixture" { } ''
    cp -r ${./fixtures/native-devenv-projection} $out
  '';
  fixtureRev = builtins.substring 0 40 (builtins.hashString "sha1" (baseNameOf (toString fixtureSrc)));
  fixtureNar = lib.fileContents (pkgs.runCommand "native-devenv-projection-narhash" { nativeBuildInputs = [ pkgs.nix ]; } ''
    nix --extra-experimental-features nix-command hash path ${fixtureSrc} > $out
  '');
  badJson = pkgs.writeText "native-devenv-projection-unsafe.json" (builtins.toJSON {
    schema_version = 1;
    check = "touch /workspace/projection/.unsafe-check-ran";
    variables = {
      DEVENV_PROFILE = { type = "exported"; value = "/home/host/.cache/profile"; };
      DEVENV_ROOT = { type = "exported"; value = "__PROJECT_ROOT__"; };
      DEVENV_RUNTIME = { type = "exported"; value = "__DEVENV_RUNTIME__"; };
      shellHook = { type = "exported"; value = "touch /workspace/projection/.unsafe-hook-ran"; };
    };
  });
  projection = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    inherit envJson profile;
    projectRoot = "/workspace/projection";
  };
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  I = lib.getExe runtime.tools.instance;
  runner = lib.getExe projection.runner;
  manifestData = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "devenv-projection" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
        sam.agentRuntime.templates.devenv-projection = {
          role = { name = "devenv-projection"; harness = "codex"; };
          repositories.projection = {
            github = "sammasak/native-devenv-projection-fixture";
            ref = { type = "commit"; value = fixtureRev; };
            lock = { rev = fixtureRev; narHash = fixtureNar; outPath = "${fixtureSrc}"; };
            path = "/workspace/projection";
            writable = true;
          };
          skillsSource = skills;
          packages = [ projection.runner ];
          filesystem = {
            workspaceBudget = { sizeMiB = 64; inodes = 4000; };
            home = { sizeMiB = 32; inodes = 2000; };
            tmp = { sizeMiB = 128; inodes = 20000; };
            cache = { sizeMiB = 128; inodes = 20000; };
            output = { sizeMiB = 32; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 1024; tasksMax = 512; timeoutMinutes = 10; };
        };
      }
    ];
  };
  manifest = "${manifestData.manifestDir}/devenv-projection.json";
  template = manifestData.manifestData.devenv-projection;
in
assert template.policies.network == { egress = "none"; allow = [ ]; };
assert template.policies.capabilities == [ ] && template.policies.privateSources == [ ];
assert template.filesystem.workspaceBudget.sizeMiB == 64 && template.filesystem.output.sizeMiB == 32;
pkgs.testers.runNixOSTest {
  name = "agent-runtime-devenv-projection";
  nodes.machine = {
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ envJson profile fixtureSrc manifest badJson ];
    environment.systemPackages = with pkgs; [ util-linux coreutils jq procps ];
  };
  testScript = ''
    import json
    M = "${manifest}"
    POLICY = "${manifestData.hostPolicy}"
    I = "${I}"
    V = "/var/lib/agent-runtime"

    def status(i):
        return json.loads(machine.succeed(f"{I} status {i}"))

    def create(i):
        machine.succeed(f"{I} create {i} --template {M} --host {POLICY} --task devenv-platform#93")

    def clean(i):
        machine.succeed(f"{I} destroy {i} --discard")
        machine.succeed(f"! findmnt -rn | grep -qE 'agent-runtime[-/]{i}(/| |$)'")
        machine.succeed(f"! systemctl list-units --all --no-legend 'agent-runtime-{i}.service' | grep -q .")
        machine.succeed(f"test ! -e {V}/{i} -a ! -e /run/agent-runtime/{i}")

    machine.wait_for_unit("multi-user.target")
    machine.succeed("test ! -e ${fixtureSrc}/.devenv-enterShell-ran")

    with subtest("generated Devenv variables, import, and enterShell activate inside nspawn before the project check"):
        create("projected")
        machine.succeed(f"{I} start projected --wait -- ${runner}")
        s = status("projected")
        assert s["state"] == "succeeded", s
        o = f"{V}/projected/vol/output"
        result = json.loads(machine.succeed(f"cat {o}/result.json"))
        assert result["environment"]["marker"] == "generated-devenv-environment", result
        assert result["environment"]["imported"] == "generated-devenv-import", result
        assert result["environment"]["profile"].startswith("/nix/store/"), result
        assert result["check_exit"] == 0, result
        machine.succeed(f"grep -q 'guest-check:generated-devenv-environment:generated-devenv-import' {o}/check.log")
        machine.succeed(f"test -f {V}/projected/vol/workspace/workspace/projection/.devenv-enterShell-ran")
        machine.succeed(f"test -f {V}/projected/vol/workspace/workspace/projection/check.result")
        machine.succeed("test ! -e ${fixtureSrc}/.devenv-enterShell-ran")
        clean("projected")

    with subtest("unsafe host-local profile is rejected before the hook or project check runs"):
        create("unsafe")
        machine.execute(f"{I} start unsafe --wait -- ${runner} ${badJson}")
        s = status("unsafe")
        assert s["state"] == "failed" and s["result"]["exitStatus"] == 65, s
        machine.succeed(f"grep -q 'projection rejected' {V}/unsafe/vol/output/stderr.log || journalctl -u agent-runtime-unsafe.service --no-pager -o cat | grep -q 'projection rejected'")
        machine.succeed(f"test ! -e {V}/unsafe/vol/workspace/workspace/projection/.unsafe-hook-ran")
        machine.succeed(f"test ! -e {V}/unsafe/vol/workspace/workspace/projection/.unsafe-check-ran")
        clean("unsafe")

    machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
    machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")
  '';
}
