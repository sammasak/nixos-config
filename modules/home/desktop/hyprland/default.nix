{
  config,
  pkgs,
  ...
}:
let
  term = "alacritty";
  menu = "wofi --show drun";
in
{
  home.packages = with pkgs; [
    alacritty
    waybar
    wofi
    grim
    slurp
  ];


  wayland.windowManager.hyprland = {
    enable = true;

    package = null;
    portalPackage = null;
  };

  wayland.windowManager.hyprland.settings = {
    "$mod" = "SUPER";

    bind = [
      "$mod, RETURN, exec, alacritty"
      "$mod, D, exec, wofi --show drun"
      "$mod, Q, killactive,";
    ];
    input = {
      kb_layout = "se"; 
    };
  };
}
