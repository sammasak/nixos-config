# Hyprlock - Screen Locker for Hyprland
# Secure and beautiful lock screen

{pkgs, ...}:
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

      label = [
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
      ];
    };
  };
}
