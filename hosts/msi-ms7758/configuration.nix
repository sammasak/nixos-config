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

  # Shared Windows ESP is only 100 MiB; keep kernels/initrds on root FS.
  boot.loader.grub.copyKernels = false;
  boot.loader.grub.configurationLimit = 5;

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };
}
