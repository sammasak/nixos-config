# Every installed Claude agent adapter, on each host of the system and each of its worker guests, may name its contract
# and jq files only in its own store closure: a `~/` checkout or a relative `agents/...` path is absent in a guest or at
# another revision on a host. The unpinned adapters and one naming a store path without its context are the seeded
# failures. Its `cd <skills checkout> && devenv tasks run` command form is not checked: devenv needs a checkout.
{
  config,
  lib,
  inputs,
  ...
}:
let
  # The adapters as modules/programs/cli/claude-code/skills.nix writes them for a system, read from that module
  # without Home Manager: even home.file's names pull in stylix, which imports from a derivation the flake check
  # refuses. An adapter another module writes is not seen. Its homes are the ones fleetHome
  # (flake-modules/nixos-configurations.nix) gives skills.nix to, on devTools: keep the two in step.
  adaptersOf =
    os:
    lib.optionals os.sam.profile.devTools (
      lib.mapAttrsToList (n: f: builtins.toFile (baseNameOf n) f.text) (
        lib.filterAttrs (n: _: lib.hasPrefix ".claude/agents/" n)
          (import ../modules/programs/cli/claude-code/skills.nix inputs.skills {
            inherit lib;
            osConfig = os;
          }).home.file
      )
    );
  guestsOf = os: map (c: c.config) (lib.attrValues os.containers);
in
{
  perSystem =
    { system, pkgs, ... }:
    let
      systems = lib.filter (os: os.nixpkgs.hostPlatform.system == system) (
        map (c: c.config) (lib.attrValues config.flake.nixosConfigurations)
      );
      installed = lib.unique (lib.concatMap adaptersOf (systems ++ lib.concatMap guestsOf systems));
      unpinned = lib.mapAttrsToList (n: _: "${inputs.skills}/agents/${n}") (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (
          builtins.readDir "${inputs.skills}/agents"
        )
      );
      seeds = [
        unpinned
        [
          (pkgs.writeText "stray-adapter.md" "`${builtins.unsafeDiscardStringContext "${inputs.skills}"}/global-context.md`")
        ]
      ];
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
          ${lib.concatMapStrings (seed: ''
            if (${verify seed}) >/dev/null 2>&1; then
              echo "the seeded adapters ${toString seed} passed: the check finds nothing" >&2; exit 1
            fi
          '') seeds}
          touch $out
        '';
      };
    };
}
