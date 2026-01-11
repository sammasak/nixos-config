# Hyprlock - Screen Locker for Hyprland
# Uses Stylix colors for consistent theming

{ pkgs, lib, config, ... }:
let
  theme = import ../../lib/theme.nix;
  # Stylix colors with hashtag prefix for CSS-style usage
  colors = config.lib.stylix.colors.withHashtag;
in
{
  programs.hyprlock = {
    enable = true;

    settings = {
      general = {
        disable_loading_bar = true;
        grace = 2;
        hide_cursor = true;
        no_fade_in = false;
      };

      background = lib.mkForce [
        {
          monitor = "";
          path = "${theme.wallpaper}";
          blur_passes = 3;
          blur_size = 8;
        }
      ];

      label = lib.mkForce [
        {
          monitor = "";
          text = "$TIME";
          font_size = 50;
          color = "rgb(${config.lib.stylix.colors.base05})";
          position = "0, 80";
          valign = "center";
          halign = "center";
          font_family = theme.fonts.mono;
        }
        {
          monitor = "";
          text = "$USER";
          font_size = 20;
          color = "rgb(${config.lib.stylix.colors.base05})";
          position = "0, 150";
          valign = "center";
          halign = "center";
          font_family = theme.fonts.mono;
        }
      ];

      input-field = lib.mkForce [
        {
          monitor = "";
          size = "200, 50";
          position = "0, -80";
          valign = "center";
          halign = "center";
          dots_center = true;
          fade_on_empty = false;
          font_color = "rgb(${config.lib.stylix.colors.base05})";
          inner_color = "rgb(${config.lib.stylix.colors.base01})";
          outer_color = "rgb(${config.lib.stylix.colors.base00})";
          outline_thickness = 5;
          placeholder_text = "Password...";
          shadow_passes = 2;
        }
      ];
    };
  };
}
