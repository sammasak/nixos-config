# Shared desktop services (compositor-agnostic): bar, launcher, lock, idle,
# notifications, gtk, and the screenshot/clipboard/wallpaper scripts. niri uses
# all of these; they long predate being the sole desktop and keep the hypr* names.
{ pkgs, lib, ... }:
let
  inherit (lib) mkForce;
in
{
  imports = [
    ./programs/waybar/minimal.nix
    ./programs/rofi/default.nix
    ./programs/hyprlock/default.nix
    ./programs/hypridle/default.nix
    ./programs/swaync/default.nix
    ./programs/gtk/default.nix
    ./scripts
  ];

  # swww is the only wallpaper daemon.
  services.hyprpaper.enable = mkForce false;

  # Without a polkit agent, privileged desktop prompts (NetworkManager, udisks2)
  # fail silently.
  services.hyprpolkitagent.enable = true;

  home.packages = [ pkgs.wdisplays ];
}
