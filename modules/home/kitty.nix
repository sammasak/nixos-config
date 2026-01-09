# Kitty Terminal Configuration
# Modern, GPU-accelerated terminal emulator for Wayland

{pkgs, ...}:
{
  programs.kitty = {
    enable = true;

    # Kitty settings
    settings = {
      # Font
      font_family = "JetBrains Mono";
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 11;

      # Cursor
      cursor_shape = "block";
      cursor_blink_interval = 0;

      # Scrollback
      scrollback_lines = 10000;

      # Mouse
      mouse_hide_wait = 3;
      url_style = "curly";
      open_url_with = "default";

      # Terminal bell
      enable_audio_bell = false;
      visual_bell_duration = 0;

      # Window
      remember_window_size = true;
      initial_window_width = 640;
      initial_window_height = 400;
      window_padding_width = 5;

      # Tab bar
      tab_bar_edge = "top";
      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";

      # Advanced
      shell = ".";
      allow_remote_control = "socket-only";
      listen_on = "unix:/tmp/kitty";
      update_check_interval = 0;

      # Wayland specific
      wayland_titlebar_color = "background";
      linux_display_server = "wayland";

      # Performance
      repaint_delay = 10;
      input_delay = 3;
      sync_to_monitor = true;

      # Disable confirm on close
      confirm_os_window_close = 0;
    };

    # Keybindings
    keybindings = {
      "ctrl+shift+c" = "copy_to_clipboard";
      "ctrl+shift+v" = "paste_from_clipboard";
      "ctrl+shift+t" = "new_tab";
      "ctrl+shift+w" = "close_tab";
      "ctrl+shift+right" = "next_tab";
      "ctrl+shift+left" = "previous_tab";
      "ctrl+shift+equal" = "increase_font_size";
      "ctrl+shift+minus" = "decrease_font_size";
      "ctrl+shift+backspace" = "restore_font_size";
    };
  };
}
