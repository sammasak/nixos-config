# devenv-platform#93 fixture: evaluate a pinned Devenv project on the trusted
# host, then execute the project's configured check inside the nspawn guest.
# The project itself is pinned as an in-tree locked source.
{ pkgs, lib, skills }:
let
  # the committed fixture tree, realized into the store (the projected source)
  fixtureSrc = pkgs.runCommandLocal "devenv-native-fixture" { } ''
    cp -r ${../fixtures/devenv-native} $out
  '';
  # the real NAR hash of that store path (recorded in the run manifest)
  fixtureNar = lib.fileContents (pkgs.runCommand "devenv-native-narhash" { nativeBuildInputs = [ pkgs.nix ]; } ''
    nix --extra-experimental-features nix-command hash path ${fixtureSrc} > $out
  '');
  # a deterministic synthetic 40-hex commit id for the in-tree fixture
  fixtureRev = builtins.substring 0 40 (builtins.hashString "sha1" (baseNameOf (toString fixtureSrc)));

  # Evaluate the real project with the locked Devenv modules and nixpkgs sources
  # supplied as store paths. This keeps evaluation offline and runs no shell hook.
  devenvSource = builtins.fetchTree {
    type = "github";
    owner = "cachix";
    repo = "devenv";
    rev = "9655d320b8f9df74dbecf681f52a7334574606c3";
    narHash = "sha256-WlVNaWXVTYaGBNey2Z+20sY1lT7BvzJEECb+VlDDdk0=";
  };
  fixtureNixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    rev = "fe13242281a67641c0102cdb1087f0ebe586c7df";
    narHash = "sha256-zp8ToDMnqZcu4o4IH9pdwXFXGp7yLm/M0dEnNWnyd7I=";
  };
  devenvSourcePackage = pkgs.runCommandLocal "devenv-native-devenv-source" { } ''
    mkdir -p $out/share/devenv
    ln -s ${devenvSource}/src/modules $out/share/devenv/modules
  '';
  fixtureNixpkgsPackage = pkgs.runCommandLocal "devenv-native-nixpkgs-source" { } ''
    mkdir -p $out/share
    ln -s ${fixtureNixpkgs} $out/share/nixpkgs
  '';
  devenvConfig = pkgs.runCommand "devenv-native-evaluated-config" {
    nativeBuildInputs = [ pkgs.devenv pkgs.jq pkgs.nix ];
  } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$TMPDIR/project"
    cp -R ${../fixtures/devenv-native}/. "$TMPDIR/project/"
    chmod -R u+w "$TMPDIR/project"
    cd "$TMPDIR/project"
    export DEVENV_ROOT="$TMPDIR/project"
    devenv --offline \
      --override-input nixpkgs path:${fixtureNixpkgs} \
      --override-input devenv path:${devenvSource}/src/modules \
      eval scripts.check.exec > "$TMPDIR/task.json"
    jq -er '.["scripts.check.exec"] | strings | select(length > 0)' "$TMPDIR/task.json" > "$TMPDIR/check"
    devenv --offline \
      --override-input nixpkgs path:${fixtureNixpkgs} \
      --override-input devenv path:${devenvSource}/src/modules \
      eval env.DEVENV_IMPORT_MARKER > "$TMPDIR/import-marker.json"
    jq -e '."env.DEVENV_IMPORT_MARKER" == "tooling-import-loaded"' "$TMPDIR/import-marker.json" >/dev/null
    test ! -e "$DEVENV_ROOT/.devenv-enterShell-ran"
    mkdir -p "$out"
    cp "$TMPDIR/check" "$out/check"
    cp "$TMPDIR/import-marker.json" "$out/import-marker.json"
  '';

  # These packages match the fixture's declared Devenv toolchain and support
  # the boundary probes inside the guest.
  toolchain = [ pkgs.gnumake pkgs.gcc pkgs.coreutils ];

  # Runs the exact scripts.check.exec and exported marker from Devenv's output
  # inside the guest. Devenv evaluation above never enters or executes the shell.
  run = pkgs.writeShellApplication {
    name = "devenv-native-run";
    runtimeInputs = toolchain ++ [ pkgs.findutils pkgs.jq ];
    text = ''
      out=''${AGENT_RUNTIME_OUTPUT:?not in an agent-runtime instance}
      mode=''${1:-good}
      repo=/workspace/fixture
      cd "$repo"
      # The script and imported marker come from Devenv evaluation. Its root
      # points at the writable guest copy, never the read-only projected source.
      import_marker=$(jq -er '."env.DEVENV_IMPORT_MARKER"' ${devenvConfig}/import-marker.json)
      export DEVENV_IMPORT_MARKER="$import_marker"
      export DEVENV_ROOT="$repo"
      cc_bin=$(command -v gcc); mk_bin=$(command -v make)
      { "$cc_bin" --version | head -1
        "$mk_bin" --version | head -1
        echo "selected_devshell=devenv.yaml + devenv.nix scripts.check.exec"
      } > "$out/toolchain.txt"
      echo "editing-shell-usable $AGENT_RUNTIME_INSTANCE" > "$repo/.editing-shell-ok"
      if [ "$mode" = broken ]; then
        printf 'int main(void){ return ;\n' > hello.c   # deliberately broken
      fi
      rc=0
      bash -euo pipefail -c "$(cat ${devenvConfig}/check)" > "$out/make.log" 2>&1 || rc=$?
      echo "mode=$mode check_rc=$rc"
      used() { du -sk "$1" 2>/dev/null | cut -f1 || echo 0; }
      printf '{"fixture":"devenv-native","mode":"%s","check_exit":%d,"editing_shell":"ok","usedKiB":{"cache":%s,"workspace":%s}}\n' \
        "$mode" "$rc" "$(used /var/cache/agent)" "$(used "$repo")" > "$out/result.json"
      (cd "$out" && sha256sum toolchain.txt result.json make.log > SHA256SUMS 2>/dev/null || true)
      exit "$rc"
    '';
  };

  runtime = import ../../modules/agent-runtime/lib.nix { inherit lib pkgs; };
  evaluated = runtime.evalManifests {
    modules = [
      {
        sam.agentRuntime.host = {
          enable = true;
          eligibleTemplates = [ "devenv-native" ];
          maxConcurrentInstances = 2;
          reserve = { memoryMiB = 1024; diskMiB = 256; };
        };
        sam.agentRuntime.templates.devenv-native = {
          role = { name = "devenv-native"; harness = "codex"; };
          repositories.fixture = {
            github = "sammasak/devenv-native-fixture";
            ref = { type = "commit"; value = fixtureRev; };
            lock = { rev = fixtureRev; narHash = fixtureNar; outPath = "${fixtureSrc}"; };
            path = "/workspace/fixture";
            writable = true;
          };
          skillsSource = skills;
          packages =
            [ run pkgs.devenv pkgs.nix devenvSourcePackage fixtureNixpkgsPackage ]
            ++ toolchain
            ++ [ pkgs.bash pkgs.findutils ];
          filesystem = {
            workspaceBudget = { sizeMiB = 64; inodes = 4000; };
            home = { sizeMiB = 32; inodes = 2000; };
            tmp = { sizeMiB = 128; inodes = 20000; };
            cache = { sizeMiB = 128; inodes = 20000; };
            output = { sizeMiB = 32; inodes = 1000; };
          };
          resources = { cpus = 1; memoryMiB = 1024; tasksMax = 512; timeoutMinutes = 10; };
          # network.allow null (no egress), capabilities empty (no credential)
        };
      }
    ];
  };
in
{
  inherit evaluated fixtureSrc fixtureRev fixtureNar toolchain run devenvConfig devenvSource fixtureNixpkgs devenvSourcePackage fixtureNixpkgsPackage;
  env = pkgs.buildEnv {
    name = "devenv-native-env";
    paths = evaluated.templates.devenv-native.packages ++ [ devenvConfig ];
  };
}
