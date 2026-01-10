# Hyprlock - Screen Locker for Hyprland
# Secure and beautiful lock screen

{pkgs, lib, ...}:
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
          path = "${pkgs.nixos-artwork.wallpapers.nineish-dark-gray.gnomeFilePath}";
          blur_passes = 3;
          blur_size = 8;
        }
      ];

      label = lib.mkForce [
        {
          monitor = "";
          text = "$TIME";
          font_size = 50;
          color = "rgba(200, 200, 200, 1.0)";
          position = "0, 80";
          valign = "center";
          halign = "center";
          font_family = "JetBrains Mono";
        }
        {
          monitor = "";
          text = "$USER";
          font_size = 20;
          color = "rgba(200, 200, 200, 1.0)";
          position = "0, 150";
          valign = "center";
          halign = "center";
          font_family = "JetBrains Mono";
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
          font_color = "rgb(200, 200, 200)";
          inner_color = "rgb(25, 20, 20)";
          outer_color = "rgb(0, 0, 0)";
          outline_thickness = 5;
          placeholder_text = "Password...";
          shadow_passes = 2;
        }
      ];
    };
  };
}
