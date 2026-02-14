# Host-specific variables for msi-ms7758
{
  # System
  username = "lukas";
  hostname = "msi-ms7758";
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Desktop
  desktop = "hyprland";
  waybarTheme = "minimal";
  sddmTheme = "astronaut";
  defaultWallpaper = "train-sideview.webp";

  # Applications
  terminal = "kitty";
  browser = "firefox";
  editor = "vscode";
  shell = "nushell";
  tuiFileManager = "yazi";

  # Monitor configuration (Hyprland): apply defaults to all monitors.
  monitors = [
    ",preferred,auto,1"
  ];

  # Features
  laptop = false;
  games = true;

  # Roles
  roles = [ "base" "desktop" ];
}
