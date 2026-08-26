# Laptop-specific role (power + input)
{ ... }:
{
  imports = [
    ../core/laptop.nix
    ../core/wifi.nix
  ];

  # Both laptops use the home WiFi; the sole-worker incident 2026-08-26
  # showed why the profile must be declarative.
  sam.wifi.declarativeHomeProfile = true;
}
