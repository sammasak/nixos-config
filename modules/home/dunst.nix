# Dunst - Notification Daemon
# Colors are handled by Stylix

{pkgs, ...}:
{
  services.dunst = {
    enable = true;

    settings = {
      global = {
        # Display
        monitor = 0;
        follow = "keyboard";

        # Geometry
        width = 370;
        height = 300;
        origin = "top-right";
        offset = "10x10";
        notification_limit = 5;

        # Progress bar
        progress_bar = true;
        progress_bar_height = 10;

        # Visual
        separator_height = 2;
        padding = 24;
        horizontal_padding = 24;
        frame_width = 2;
        gap_size = 5;
        corner_radius = 0;

        # Text
        line_height = 0;
        markup = "full";
        format = "<b>%s</b>\\n%b";
        alignment = "left";
        vertical_alignment = "center";
        show_age_threshold = 60;
        stack_duplicates = true;
        show_indicators = true;

        # Icons
        icon_position = "left";
        min_icon_size = 32;
        max_icon_size = 128;
        icon_theme = "Papirus-Dark";
        enable_recursive_icon_lookup = true;

        # History
        sticky_history = true;
        history_length = 20;

        # Misc
        dmenu = "rofi -dmenu -p dunst:";
        browser = "firefox";

        # Mouse
        mouse_left_click = "close_current";
        mouse_middle_click = "do_action, close_current";
        mouse_right_click = "close_all";
      };

      urgency_low = {
        timeout = 5;
      };

      urgency_normal = {
        timeout = 10;
      };

      urgency_critical = {
        timeout = 0;
      };
    };
  };

  home.packages = with pkgs; [
    libnotify
  ];
}
