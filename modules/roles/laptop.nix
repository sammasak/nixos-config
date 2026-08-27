{ ... }:
{
  imports = [
    ../core/laptop.nix
    ../core/wifi.nix
  ];

  sam.wifi.declarativeHomeProfile = true;
}
