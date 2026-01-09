# Rofi - Application Launcher
# Colors are handled by Stylix

{pkgs, ...}:
{
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;

    extraConfig = {
      modi = "drun,run,window";
      show-icons = true;
      terminal = "kitty";
      drun-display-format = "{name}";
      disable-history = false;
      hide-scrollbar = true;
      display-drun = " Apps";
      display-run = " Run";
      display-window = " Window";
      sidebar-mode = true;
    };
  };
}
