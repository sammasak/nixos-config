{ ... }:
{
  imports = [
    ../core/laptop.nix
    ../core/wifi.nix
  ];

  # NetworkManager's own profiles are imperative state and a crash can lose them.
  # See vault: homelab/acer-swift-wifi-resilience.md
  sam.wifi.declarativeHomeProfile = true;
}
