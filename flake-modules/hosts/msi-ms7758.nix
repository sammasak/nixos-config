let
  vars = import ../../hosts/msi-ms7758/variables.nix;
in
{
  configurations.nixos.msi-ms7758 = {
    hostDir = "msi-ms7758";
    inherit (vars) username roles;
  };
}
