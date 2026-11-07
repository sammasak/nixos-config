# devenv-platform#93 fixture: a tiny pinned native devShell, host-realized and
# projected read-only into the existing nspawn runtime (mode (a)). Shared by the
# VM test (tests/agent-runtime-devenv-native.nix) and the pure-eval check
# (flake-modules/64-...). The in-tree fixture is pinned as a locked source: its
# store path is the authority (assign.sh GC-roots it offline, never prefetching),
# the narHash is the real NAR hash of that path, and the rev is a deterministic
# synthetic commit id (there is no upstream GitHub repo for an in-tree fixture).
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

  # the selected devShell's toolchain, realized host-side and projected read-only
  toolchain = [ pkgs.gnumake pkgs.gcc pkgs.coreutils ];

  # the entrypoint that runs INSIDE the guest: it exercises the devenv project
  # check with the projected toolchain, proves the editing shell works even on a
  # broken source, and runs the project hook in-guest (never on the host).
  run = pkgs.writeShellApplication {
    name = "devenv-native-run";
    runtimeInputs = toolchain ++ [ pkgs.findutils ];
    text = ''
      out=''${AGENT_RUNTIME_OUTPUT:?not in an agent-runtime instance}
      mode=''${1:-good}
      repo=/workspace/fixture
      cd "$repo"
      # editing shell: capture the projected toolchain first, so it is proven present
      # even when the project source is broken below
      cc_bin=$(command -v gcc); mk_bin=$(command -v make)
      { "$cc_bin" --version | head -1
        "$mk_bin" --version | head -1
        echo "selected_devshell=devShells.x86_64-linux.default [gnumake gcc coreutils]"
      } > "$out/toolchain.txt"
      echo "editing-shell-usable $AGENT_RUNTIME_INSTANCE" > "$repo/.editing-shell-ok"
      # the devenv project hook, run only here in the guest
      echo "hook ran in $AGENT_RUNTIME_INSTANCE" > "$repo/.hook-ran-in-guest"
      if [ "$mode" = broken ]; then
        printf 'int main(void){ return ;\n' > hello.c   # deliberately broken
      fi
      rc=0
      make check CC="$cc_bin" > "$out/make.log" 2>&1 || rc=$?
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
          packages = [ run ] ++ toolchain ++ [ pkgs.bash pkgs.findutils ];
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
  inherit evaluated fixtureSrc fixtureRev fixtureNar toolchain run;
  env = pkgs.buildEnv { name = "devenv-native-env"; paths = evaluated.templates.devenv-native.packages; };
}
