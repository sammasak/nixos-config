{ lib, ... }:
{
  # A package, not a check: `nix flake check` realises checks but not packages,
  # so the heavy QEMU VM boot stays out of nixos:qa / the pre-push hook and runs
  # only on an explicit `nix build .#packages.x86_64-linux.rf-hwsim-dataplane`.
  # perSystem returns a static attrset (guard the value, not the whole body) so
  # flake-parts' formatter heuristic can still prove no formatter is defined.
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        rf-hwsim-dataplane = import ../tests/rf-hwsim-dataplane.nix { inherit pkgs; };
      };
    };
}
