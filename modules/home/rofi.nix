# Rofi - Application Launcher
# Colors are handled by Stylix

{pkgs, ...}:
{
  programs.rofi = {
    enable = true;

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

      # Navigation
      kb-mode-next = "Tab,Control+l";
      kb-mode-previous = "ISO_Left_Tab,Control+h";
      kb-row-up = "Control+k,Up";
      kb-row-down = "Control+j,Down";
      kb-accept-entry = "Return,KP_Enter";
      kb-remove-to-eol = "";
      kb-remove-char-back = "BackSpace";
    };
  };
}
