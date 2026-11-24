# A package, not an overlay entry: no host uses the crate, so no host's pkgs carries it.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.exec-pool = pkgs.callPackage ../pkgs/exec-pool/package.nix { };
    };
}
