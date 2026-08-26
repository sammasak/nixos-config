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

  # Hardware
  # Discrete GPU: NVIDIA GeForce GTX 680 (Kepler) -> legacy 470 driver.
  videoDriver = "nvidia-kepler";

  # Features
  laptop = false;

  # Roles
  roles = [ "base" "homelab-agent" ];
}
