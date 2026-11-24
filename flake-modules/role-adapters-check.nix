# Every installed Claude agent adapter, on each x86 host and each of its worker guests, may name only skills files that
# are in its own store closure: a `~/` checkout or a relative `agents/...` path is absent in a guest or at another
# revision on a host. The unpinned adapters from the skills input itself are the seeded failure.
{
  config,
  lib,
  inputs,
  ...
}:
let
  homesOf =
    os:
    lib.attrValues os.home-manager.users
    ++ lib.concatMap (c: lib.attrValues c.config.home-manager.users) (lib.attrValues os.containers);
  adaptersOf =
    home:
    lib.mapAttrsToList (_: f: f.source) (
      lib.filterAttrs (n: _: lib.hasPrefix ".claude/agents/" n) home.home.file
    );
in
{
  perSystem =
    { system, pkgs, ... }:
    let
      systems = lib.filter (os: os.nixpkgs.hostPlatform.system == system) (
        map (c: c.config) (lib.attrValues config.flake.nixosConfigurations)
      );
      installed = lib.unique (lib.concatMap adaptersOf (lib.concatMap homesOf systems));
      unpinned = lib.mapAttrsToList (n: _: "${inputs.skills}/agents/${n}") (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (
          builtins.readDir "${inputs.skills}/agents"
        )
      );
      # exit 1 when any adapter names a path outside its closure, a checkout, or a relative skills path
      verify = adapters: ''
        bad=0
        ${lib.concatMapStrings (a: ''
          a=${a} closure=${pkgs.closureInfo { rootPaths = [ a ]; }}/store-paths
          if grep -nE '~/claude-code-skills/agents/|`agents/[^`]*/' "$a"; then
            echo "$a: names a checkout or relative skills path" >&2; bad=1
          fi
          for p in $(grep -oE '/nix/store/[a-z0-9]{32}-[^ `)]+' "$a"); do
            if ! grep -qxF "$(echo "$p" | cut -d/ -f1-4)" "$closure" || [ ! -e "$p" ]; then
              echo "$a: $p is not in its closure" >&2; bad=1
            fi
          done
        '') adapters}
        [ "$bad" = 0 ]
      '';
    in
    {
      checks = lib.optionalAttrs (installed != [ ]) {
        role-adapters = pkgs.runCommand "role-adapters" { } ''
          ${verify installed}
          if (${verify unpinned}) >/dev/null 2>&1; then
            echo "the seeded unpinned adapters passed: the check finds nothing" >&2; exit 1
          fi
          touch $out
        '';
      };
    };
}
