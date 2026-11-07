# devenv-platform#93, mode (a): the pinned repository's OWN devShell, realized on the host from its own
# flake.lock (../native-shell.nix), projected read-only through the runtime's /nix/store bind, and the
# repository's own gate run inside the instance with that shell. sammasak/rf-proto at the flake's
# pinned revision: a mkShell devShell, zero crate dependencies, so its gate builds offline. No network,
# no nix inside the instance, no credential; the shell's hook runs only in the instance.
{ config, lib, pkgs, ... }:
let
  src = config.sam.agentRuntime.pinnedSources;
  t = config.sam.agentRuntime.templates.native-shell;
  repo = t.repositories.rf-proto.path;
  shell = (import ../native-shell.nix { inherit lib pkgs; }) { src = src.rf-proto; };
  # rf-proto's gate, as its CI runs it (fmt, clippy -D warnings, tests), offline against the lockfile
  gate = [
    [ "cargo" "fmt" "--all" "--check" ]
    [ "cargo" "clippy" "--all-targets" "--offline" "--locked" "--" "-D" "warnings" ]
    [ "cargo" "test" "--offline" "--locked" ]
  ];
  jq = lib.getExe pkgs.jq;
  co = "${pkgs.coreutils}/bin";
  run = pkgs.writeShellApplication {
    name = "native-shell-run";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      out=''${AGENT_RUNTIME_OUTPUT:?not in an agent-runtime instance}
      passes=1
      if [ "''${1:-}" = --passes ]; then passes=$2; shift 2; fi
      cp ${shell.info} "$out/shell.json"
      cd ${repo}
      # the host-realized shell: its environment, then its hook, only inside this instance (HOME and
      # TMPDIR stay the instance's: the env file carries none of the builder's)
      # shellcheck source=/dev/null
      source ${shell.env}
      eval "''${shellHook:-}"
      export CARGO_HOME=${t.filesystem.cache.path}/cargo CARGO_TARGET_DIR=${t.filesystem.cache.path}/target CARGO_NET_OFFLINE=true
      ${co}/mkdir -p "$CARGO_HOME"
      ${co}/printf '{"cargo":"%s","rustc":"%s","cargoPath":"%s"}\n' "$(cargo --version)" "$(rustc --version)" "$(command -v cargo)" >"$out/versions.json"
      : >"$out/steps.jsonl"
      rc=0
      for pass in $(${co}/seq 1 "$passes"); do
        i=0
        while IFS= read -r step; do
          i=$((i + 1))
          mapfile -t argv < <(${jq} -r '.[]' <<<"$step")
          a=$(${co}/date +%s%N) s=0
          "''${argv[@]}" >"$out/pass$pass-step$i.log" 2>&1 || s=$?
          b=$(${co}/date +%s%N)
          ${jq} -nc --argjson pass "$pass" --argjson argv "$step" --argjson exit "$s" --argjson ms "$(( (b - a) / 1000000 ))" \
            '{pass: $pass, argv: $argv, exit: $exit, ms: $ms}' >>"$out/steps.jsonl"
          echo "pass $pass: ''${argv[*]} -> $s"
          if [ "$s" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=$s; fi
        done < <(${jq} -c '.[]' <<<${lib.escapeShellArg (builtins.toJSON gate)})
      done
      used() { ${co}/du -sm "$1" | ${co}/cut -f1; }
      inodes() { ${pkgs.findutils}/bin/find "$1" | ${co}/wc -l; }
      ${jq} -nc --arg rev ${src.rf-proto.rev} --argjson exit "$rc" --slurpfile steps "$out/steps.jsonl" \
        --argjson cache "$(used ${t.filesystem.cache.path})" --argjson tmp "$(used "$TMPDIR")" --argjson ws "$(used ${t.filesystem.workspace})" \
        --argjson icache "$(inodes ${t.filesystem.cache.path})" --argjson itmp "$(inodes "$TMPDIR")" \
        '{repo: "sammasak/rf-proto", rev: $rev, exit: $exit, steps: $steps,
          usedMiB: {cache: $cache, tmp: $tmp, workspace: $ws}, inodes: {cache: $icache, tmp: $itmp}}' >"$out/result.json"
      (cd "$out" && ${co}/sha256sum -- * 2>/dev/null | ${pkgs.gnugrep}/bin/grep -v ' SHA256SUMS$' >SHA256SUMS || true)
      exit "$rc"
    '';
  };
in
{
  sam.agentRuntime.templates.native-shell = {
    role = {
      name = "rust-worker";
      harness = "claude-code";
    };
    repositories.rf-proto = {
      github = "sammasak/rf-proto";
      ref = {
        type = "commit";
        value = src.rf-proto.rev;
      };
      lock = src.rf-proto;
      path = "/workspace/rf-proto";
      writable = true;
    };
    skillsSource = src.skills;
    skills.rust-engineering = { };
    # the runner only: the shell's own tools reach the instance through its env file, not PATH here
    packages = [ run pkgs.bash pkgs.coreutils ];
    filesystem = {
      workspaceBudget = { sizeMiB = 64; inodes = 4000; };
      home = { sizeMiB = 64; inodes = 2000; };
      tmp = { sizeMiB = 512; inodes = 20000; };
      cache = { sizeMiB = 1024; inodes = 20000; };
      output = { sizeMiB = 64; inodes = 200; };
    };
    resources = {
      cpus = 2;
      memoryMiB = 2048;
      tasksMax = 512;
      timeoutMinutes = 20;
    };
    # network.allow stays null (no egress) and capabilities empty (no credential)
  };
}
