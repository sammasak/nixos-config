let
  vars = import ../../hosts/lenovo-21CB001PMX/variables.nix;
in
{
  configurations.nixos.lenovo = {
    hostDir = "lenovo-21CB001PMX";
    inherit (vars) username roles;
  };
}
