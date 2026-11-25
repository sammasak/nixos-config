# Each pkgs/<dir> as the derivation the fleet builds from it, keyed by the dir's name, so `just pool-merge-check` can
# build what a branch's changed files are part of. legacyPackages: neither `nix flake check` nor `nix flake show`
# walks it; the gate's nixos-flake-check step evaluates each entry's drvPath, builds none.
{ lib, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      dirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../pkgs));
      # a dir its own flake package or overlay entry builds, with the inputs it is called with there
      # llm-bench is a package on x86_64-linux alone: a plain inherit failed aarch64's evaluation
      built =
        lib.getAttrs (lib.intersectLists [ "exec-pool" "llm-bench" ] (
          lib.attrNames self'.packages
        )) self'.packages
        // {
          inherit (pkgs) factum wmediumd ollama-portforward;
          llm-gateway = pkgs.llmGateway;
          nix-audit = pkgs.nixAudit;
          herman-web = pkgs.hermanWeb;
        };
      called = lib.genAttrs (lib.filter (d: builtins.pathExists ../pkgs/${d}/package.nix) dirs) (
        d: pkgs.callPackage ../pkgs/${d}/package.nix { }
      );
    in
    {
      legacyPackages.pkgsDir = called // lib.filterAttrs (d: _: lib.elem d dirs) built;
    };
}
