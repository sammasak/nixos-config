{ ... }:
{
  imports = [
    ../desktop/hyprland
    ../core/sddm.nix
  ];

  # The GUI signal every desktop-gated module reads (compositor-agnostic).
  sam.desktop.enable = true;

  # Some GUI apps still expect an X server to exist.
  services.xserver.enable = true;
}
