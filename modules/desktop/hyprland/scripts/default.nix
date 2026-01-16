# Desktop utility scripts module
{ pkgs, ... }:
let
  defaultWallpaper = ../../../../assets/wallpapers/train-sideview.webp;

  wallpaper-init = pkgs.writeShellScriptBin "wallpaper-init" ''
    if ! swww query &> /dev/null; then
      swww init &> /dev/null
    fi

    swww restore &> /dev/null
    if ! swww query | grep -q "image:" &> /dev/null; then
      swww img "${defaultWallpaper}"
    fi
  '';

  window-switcher = pkgs.writeShellScriptBin "hyprland-window-switcher" (builtins.readFile ./window-switcher.sh);
in
{
  services.swww.enable = true;

  home.packages = [
    wallpaper-init
    window-switcher
  ];

  xdg.configFile = {
    "hypr/scripts/screenshot.sh" = {
      source = ./screenshot.sh;
      executable = true;
    };
    "hypr/scripts/screen-record.sh" = {
      source = ./screen-record.sh;
      executable = true;
    };
    "hypr/scripts/ClipManager.sh" = {
      source = ./ClipManager.sh;
      executable = true;
    };
    "hypr/scripts/keybinds.sh" = {
      source = ./keybinds.sh;
      executable = true;
    };
    "hypr/scripts/wallpaper-select.sh" = {
      source = ./wallpaper-select.sh;
      executable = true;
    };
  };
}
