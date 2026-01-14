# Home configuration for lukas
{ lib, pkgs, desktop ? false, ... }:
{
  home.stateVersion = "25.11";

  # Install custom scripts
  home.packages = lib.optionals desktop [
    (pkgs.writeShellScriptBin "hyprland-window-switcher" (builtins.readFile ../scripts/window-switcher.sh))
  ];

  imports = [
    ../modules/shell/nushell.nix
    ../modules/shell/starship.nix
    ../modules/shell/git.nix
    ../modules/shell/cli-tools.nix
    ../modules/dev/vscode.nix
  ] ++ lib.optionals desktop [
    ../modules/desktop/hyprland
    ../modules/desktop/hyprlock.nix
    ../modules/desktop/hypridle.nix
    ../modules/desktop/hyprpaper.nix
    ../modules/desktop/gtk.nix
    ../modules/desktop/kitty.nix
    ../modules/desktop/waybar.nix
    ../modules/desktop/rofi.nix
    ../modules/desktop/swaync.nix
    ../modules/desktop/firefox.nix
  ];
}
