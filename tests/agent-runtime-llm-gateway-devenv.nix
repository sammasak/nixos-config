# Real-project #93 acceptance: run llm-gateway's Devenv `rust:test` task inside
# the existing nspawn lifecycle, using the complete generated environment and
# Cargo sources vendored from the project's pinned Cargo.lock.
{ pkgs, lib, src, skills, llmEnvJsonPath, llmProfilePath, llmTaskPath }:
let
  envJson = builtins.storePath llmEnvJsonPath;
  profile = builtins.storePath llmProfilePath;
  env = builtins.fromJSON (builtins.readFile envJson);
  validStorePath = path:
    builtins.match "/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^ /:\t\n]+" path != null
    && builtins.pathExists path;
  before = delimiter: value: builtins.head (lib.splitString delimiter value);
  storeBase = part:
    before "'" (before "\"" (before " " (before "/" (before ":" part))));
  storeRefs = value:
    if !builtins.isString value then [ ] else
    map builtins.storePath (lib.filter validStorePath (map (part: "/nix/store/${storeBase part}")
      (lib.drop 1 (lib.splitString "/nix/store/" value))));
  envStoreRefs = lib.unique (lib.concatMap
    (variable: if variable.type == "exported" then storeRefs variable.value else [ ])
    (builtins.attrValues env.variables));
  project = builtins.storePath (toString src);
  revision = "4a17b9241d8ad3702777ea85001597910e169e5b";
  taskSource = builtins.storePath llmTaskPath;
  taskPackage = pkgs.runCommand "llm-gateway-devenv-rust-test-task" { } ''
    mkdir -p "$out/bin"
    cp ${taskSource} "$out/bin/rust-test"
    chmod +x "$out/bin/rust-test"
  '';
  vendor = pkgs.rustPlatform.importCargoLock { lockFile = "${project}/Cargo.lock"; };
  check = pkgs.writeShellApplication {
    name = "llm-gateway-devenv-rust-test";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      export CARGO_HOME=/var/cache/agent/cargo CARGO_NET_OFFLINE=true CARGO_BUILD_JOBS=2
      mkdir -p "$CARGO_HOME"
      cat >"$CARGO_HOME/config.toml" <<'EOF'
      [source.crates-io]
      replace-with = "vendored-sources"
      [source.vendored-sources]
      directory = "${vendor}"
      [net]
      offline = true
      EOF
      printf 'RUST_SRC_PATH=%s\n' "''${RUST_SRC_PATH-<unset>}"
      test -d "''${RUST_SRC_PATH:?generated Devenv Rust source path is missing}" || {
        echo "generated Rust source path is not a directory: ''${RUST_SRC_PATH-<unset>}" >&2
        exit 1
      }
      exec ${taskPackage}/bin/rust-test
    '';
  };
  devenvProfile = pkgs.symlinkJoin {
    name = "llm-gateway-devenv-profile-with-git-bootstrap";
    # The pinned project's enterShell invokes `git` but does not declare it in
    # its Devenv profile. Supply that host-common tool explicitly in the test.
    paths = [ profile pkgs.git taskPackage ];
  };
  envClosure = pkgs.runCommand "llm-gateway-devenv-exported-store-closure" { } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArgs envStoreRefs} > "$out/references"
  '';
  projectedEnv = pkgs.runCommand "llm-gateway-devenv-projected-env.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    ${pkgs.jq}/bin/jq --arg check ${lib.escapeShellArg (lib.getExe check)} --arg gitBin ${lib.escapeShellArg "${pkgs.git}/bin"} \
      '.check = $check | .variables.PATH.value = ($gitBin + ":" + .variables.PATH.value)' ${envJson} > "$out"
  '';
  fixtureNar = lib.fileContents (pkgs.runCommand "llm-gateway-native-devenv-narhash" { nativeBuildInputs = [ pkgs.nix ]; } ''
    nix --extra-experimental-features nix-command hash path ${project} > "$out"
  '');
  runtime = import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  runnerModule = import ../modules/agent-runtime/devenv-projection.nix { inherit lib pkgs; } {
    envJson = projectedEnv;
    inherit profile;
    projectRoot = "/workspace/llm-gateway";
  };
  I = lib.getExe runtime.tools.instance;
  runner = lib.getExe runnerModule.runner;
  manifestData = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "llm-gateway-devenv" ];
          maxConcurrentInstances = 1;
          reserve = { memoryMiB = 512; diskMiB = 1024; };
        };
        sam.agentRuntime.templates.llm-gateway-devenv = {
          role = { name = "llm-gateway-devenv"; harness = "codex"; };
          repositories.llm-gateway = {
            github = "sammasak/llm-gateway";
            ref = { type = "commit"; value = revision; };
            lock = { rev = revision; narHash = fixtureNar; outPath = "${project}"; };
            path = "/workspace/llm-gateway";
            writable = true;
          };
          skillsSource = skills;
          packages = [ runnerModule.runner devenvProfile envClosure ];
          filesystem = {
            workspaceBudget = { sizeMiB = 5120; inodes = 180000; };
            home = { sizeMiB = 64; inodes = 4000; };
            tmp = { sizeMiB = 1024; inodes = 50000; };
            cache = { sizeMiB = 2048; inodes = 50000; };
            output = { sizeMiB = 64; inodes = 4000; };
          };
          resources = { cpus = 2; memoryMiB = 6144; tasksMax = 1024; timeoutMinutes = 30; };
        };
      }
    ];
  };
  manifest = "${manifestData.manifestDir}/llm-gateway-devenv.json";
  template = manifestData.manifestData.llm-gateway-devenv;
in
assert template.policies.network == { egress = "none"; allow = [ ]; };
assert template.policies.capabilities == [ ] && template.policies.privateSources == [ ];
assert template.sources.llm-gateway.ref.value == revision;
assert template.sources.llm-gateway.locked.rev == revision;
assert template.filesystem.workspaceBudget.sizeMiB == 5120 && template.filesystem.cache.sizeMiB == 2048;
pkgs.testers.runNixOSTest {
  name = "agent-runtime-llm-gateway-devenv-projection";
  nodes.machine = {
    virtualisation.memorySize = 8192;
    virtualisation.cores = 4;
    virtualisation.diskSize = 14336;
    networking.firewall.enable = false;
    networking.dhcpcd.denyInterfaces = [ "ve-*" ];
    virtualisation.additionalPaths = [ projectedEnv profile project manifest skills vendor ];
    environment.systemPackages = with pkgs; [ util-linux coreutils jq procps git ];
  };
  testScript = ''
    import json
    M = "${manifest}"
    POLICY = "${manifestData.hostPolicy}"
    I = "${I}"
    REVISION = "${revision}"
    RUNNER = "${runner}"
    V = "/var/lib/agent-runtime"

    def status(i):
        return json.loads(machine.succeed(f"{I} status {i}"))

    machine.wait_for_unit("multi-user.target")
    machine.succeed("test ! -e ${project}/.devenv-enterShell-ran")
    machine.succeed(f"{I} create llm --template {M} --host {POLICY} --task sammasak/llm-gateway#{REVISION}")
    workspace = f"{V}/llm/vol/workspace/workspace/llm-gateway"
    machine.succeed(f"printf '[safe]\\n\\tdirectory = /workspace/llm-gateway\\n' > {V}/llm/vol/home/.gitconfig")
    machine.succeed(f"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} init -q && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} add -A -f && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0={workspace} git -C {workspace} -c user.name=agent -c user.email=agent@example.invalid commit -q -m workspace")
    machine.succeed(f"{I} start llm --wait -- {RUNNER}")
    s = status("llm")
    assert s["state"] == "succeeded", s
    output = f"{V}/llm/vol/output"
    result = json.loads(machine.succeed(f"cat {output}/result.json"))
    assert result["check_exit"] == 0, result
    assert result["environment"]["profile"].startswith("/nix/store/"), result
    machine.succeed(f"test -s {output}/check.log")
    machine.succeed("test ! -e ${project}/.devenv-enterShell-ran")
    machine.succeed(f"{I} destroy llm --discard")
    machine.succeed("! findmnt -rn | grep -qE 'agent-runtime[-/]llm(/| |$)'")
    machine.succeed("! systemctl list-units --all --no-legend agent-runtime-llm.service | grep -q .")
    machine.succeed(f"test ! -e {V}/llm -a ! -e /run/agent-runtime/llm")
    machine.succeed("! machinectl list --no-legend | grep -q agent-runtime-")
    machine.succeed("! losetup -l -n -O BACK-FILE | grep -q agent-runtime")
  '';
}
