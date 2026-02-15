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
  desktop = "i3";
  waybarTheme = "minimal";
  sddmTheme = "astronaut";
  defaultWallpaper = "train-sideview.webp";

  # Applications
  terminal = "kitty";
  browser = "firefox";
  editor = "vscode";
  shell = "nushell";
  tuiFileManager = "yazi";

  # Hardware
  # Discrete GPU: NVIDIA GeForce GTX 680 (Kepler) -> legacy 470 driver.
  videoDriver = "nvidia-kepler";

  # Features
  laptop = false;
  games = true;

  # Roles
  roles = [ "base" "desktop" "homelab-agent" ];
}
