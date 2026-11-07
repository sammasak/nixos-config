# A pinned repo's own mkShell devShell, realized on the host from the repo's OWN flake.lock (every
# node by fetchTree, narHash-pinned); an instance only reads it (devenv-platform#93, mode (a)).
#   (import ./native-shell.nix { inherit lib pkgs; }) { src = inputs.rf-proto; } -> { env, info, drv }
# `env` is the shell's build environment as `declare -x` lines; docs/agent-runtime-native-shell.md.
{ lib, pkgs }:
{ src, system ? pkgs.stdenv.hostPlatform.system, shell ? "default" }:
let
  lock = lib.importJSON "${src}/flake.lock";
  # an input reference is a node name, or a follows path walked from the root
  resolve = ref: if builtins.isList ref then lib.foldl' (n: i: resolve lock.nodes.${n}.inputs.${i}) lock.root ref else ref;
  fetched = lib.mapAttrs (n: node:
    if n == lock.root then null
    else if !(node ? locked.narHash) then throw "native-shell: ${src.rev or "src"} lock node ${n} has no narHash; refusing an unpinned input"
    else builtins.fetchTree node.locked) lock.nodes;
  callFlake = sourceInfo: inputNodes:
    let
      inputs = lib.mapAttrs (_: ref: flakes.${resolve ref}) inputNodes;
      outputs = (import "${sourceInfo.outPath}/flake.nix").outputs (inputs // { self = result; });
      result = outputs // sourceInfo // { inherit inputs outputs sourceInfo; _type = "flake"; };
    in
    result;
  flakes = lib.mapAttrs (n: node:
    if n == lock.root then null
    else if (node.flake or true) == false then fetched.${n}
    else callFlake fetched.${n} (node.inputs or { })) lock.nodes;
  flake = callFlake src (lock.nodes.${lock.root}.inputs or { });

  drv = flake.devShells.${system}.${shell}
    or (throw "native-shell: ${src.rev or "src"} has no devShells.${system}.${shell}");
  # the builder's own variables: meaningless (or harmful) in an instance, as `nix develop` drops them
  ignored = [ "BASHOPTS" "EUID" "HOME" "NIX_BUILD_TOP" "NIX_ENFORCE_PURITY" "NIX_LOG_FD" "NIX_REMOTE"
    "NIX_SSL_CERT_FILE" "OLDPWD" "PPID" "PWD" "SHELLOPTS" "SHLVL" "SSL_CERT_FILE" "TEMP" "TEMPDIR"
    "TERM" "TMP" "TMPDIR" "TZ" "UID" "builder" "out" "outputs" ];
  env = pkgs.runCommand "native-shell-env-${builtins.substring 0 7 (src.rev or "src")}" { } ''
    grep -q 'internal implementation detail for pkgs.mkShell' ${drv} \
      || { echo "native-shell: devShells.${system}.${shell} is not a pkgs.mkShell; unsupported" >&2; exit 1; }
    grep -E '^declare -x [A-Za-z_][A-Za-z0-9_]*=' ${drv} \
      | grep -vE '^declare -x (${lib.concatStringsSep "|" ignored})=' >$out
  '';
  closure = pkgs.closureInfo { rootPaths = [ env ]; };
  info = pkgs.runCommand "native-shell-info.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq -nS --arg rev ${lib.escapeShellArg (src.rev or "")} --arg narHash ${lib.escapeShellArg (src.narHash or "")} \
      --arg shell ${lib.escapeShellArg "devShells.${system}.${shell}"} --arg drvPath ${lib.escapeShellArg (builtins.unsafeDiscardStringContext drv.drvPath)} \
      --arg shellPath ${drv} --arg env ${env} --arg nix ${lib.escapeShellArg builtins.nixVersion} \
      --argjson lock ${lib.escapeShellArg (builtins.toJSON (lib.mapAttrs (_: n: { inherit (n.locked) rev narHash; type = n.locked.type; })
        (lib.filterAttrs (n: _: n != lock.root) lock.nodes)))} \
      --argjson paths "$(wc -l <${closure}/store-paths)" --argjson narSize "$(cat ${closure}/total-nar-size)" \
      '{source: {rev: $rev, narHash: $narHash}, lock: $lock, shell: $shell, drvPath: $drvPath, shellPath: $shellPath,
        env: $env, evaluatedBy: {nix: $nix}, closure: {paths: $paths, narSize: $narSize}}' >$out
  '';
in
{ inherit env info drv; }
