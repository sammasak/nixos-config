let
  vars = import ../../hosts/msi-ms7758/variables.nix;
in
{
  configurations.nixos.msi-ms7758 = {
    hostDir = "msi-ms7758";
    system = "x86_64-linux";
    username = vars.username;
    roles = vars.roles or [ "base" ];
  };
}
