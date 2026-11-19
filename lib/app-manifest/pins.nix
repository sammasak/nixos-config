# The app registry (apps/registry.json): each app's grant and the source it is built from, the one file the bump command
# (scripts/app-bump.py) writes. The whole file is type-checked and its grants applied on any use, so a bad entry fails
# evaluation, never a deploy. A source is fetched by rev with its narHash, the same tree and store path a flake input
# with that rev gives; a wrong narHash fails the fetch, so the hash cannot drift from the rev.
{
  lib,
  registry ? ../../apps/registry.json,
}:
let
  inherit (lib) mkOption types;
  names = import ./names.nix lib;
  hosts =
    lib.attrNames
      (lib.evalModules { modules = [ ../../modules/core/fleet.nix ]; }).config.sam.fleet.hosts;
  source = types.submodule {
    options = {
      repo = mkOption { type = types.strMatching names.repo; };
      rev = mkOption { type = types.strMatching "[0-9a-f]{40}"; };
      narHash = mkOption { type = types.strMatching "sha256-[A-Za-z0-9+/]{43}="; };
    };
  };
  eval = lib.evalModules {
    modules = [
      {
        options.grants = mkOption {
          type = names.keyed names.app (types.submodule (import ./grant.nix { inherit hosts; }));
          default = { };
        };
        options.apps = mkOption {
          type = names.keyed names.app (types.submodule { options.source = mkOption { type = source; }; });
          default = { };
        };
      }
      {
        _file = toString registry;
        config = lib.importJSON registry;
      }
    ];
  };
  inherit (eval.config) apps grants;
  refused = lib.concatLists (
    lib.mapAttrsToList (
      n: a:
      if !grants ? ${n} then
        [ "apps.${n}: no grants.${n}, so the platform has not admitted it." ]
      else
        lib.optional (a.source.repo != grants.${n}.repo)
          "apps.${n}.source.repo: ${a.source.repo} is not the repository grants.${n} allowlists (${grants.${n}.repo})."
    ) apps
  );
  checked = builtins.deepSeq [ apps grants ] (
    if refused == [ ] then
      apps
    else
      throw "${toString registry} refused:\n${lib.concatMapStrings (m: "  ${m}\n") refused}"
  );
in
{
  inherit checked;
  src =
    n:
    let
      a =
        checked.${n}
          or (throw "${toString registry}: no apps.${n}; registered: ${toString (lib.attrNames checked)}");
    in
    builtins.fetchTree {
      type = "git";
      url = "ssh://git@github.com/${a.source.repo}";
      ref = "refs/heads/main";
      inherit (a.source) rev narHash;
    };
}
