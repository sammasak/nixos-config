{ ... }:
{
  programs.ghostty = {
    enable = true;
    settings = {
      # Font and colours come from Stylix (stylix.targets.ghostty); setting them
      # here only duplicates font-family and fights the themed size.
      cursor-style = "block";
      cursor-style-blink = false;

      mouse-hide-while-typing = true;

      window-padding-x = 5;
      window-padding-y = 5;

      # No prompt when closing a surface with a running process.
      confirm-close-surface = false;

      keybind = [
        "ctrl+shift+t=new_tab"
        "ctrl+shift+w=close_surface"
        "ctrl+shift+right=next_tab"
        "ctrl+shift+left=previous_tab"
        "ctrl+shift+equal=increase_font_size:1"
        "ctrl+shift+minus=decrease_font_size:1"
        "ctrl+shift+zero=reset_font_size"
      ];
    };
  };
}
