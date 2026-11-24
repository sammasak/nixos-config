# A package, not an overlay entry: only acer runs it (modules/homelab/exec-pool.nix calls the same file).
{
  perSystem =
    { pkgs, ... }:
    {
      packages.exec-pool = pkgs.callPackage ../pkgs/exec-pool/package.nix { };
    };
}
