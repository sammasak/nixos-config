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

  # Headless NixOS: Windows is the gaming OS on this box.
  desktop = "hyprland";
  tuiFileManager = "yazi";

  # Hardware
  # Discrete GPU: NVIDIA GeForce GTX 680 (Kepler) -> legacy 470 driver.
  videoDriver = "nvidia-kepler";

  # Features
  laptop = false;
  games = false;
  hardwareControl = false;
  # Let the MSI BIOS "Smart Fan" control the CPU fan (no Linux fancontrol).
  fancontrol = false;

  # Roles
  roles = [ "base" "homelab-agent" ];
}
