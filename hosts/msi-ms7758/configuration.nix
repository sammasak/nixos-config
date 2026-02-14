# Host configuration for msi-ms7758
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  sam.profile = vars;

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };
}
