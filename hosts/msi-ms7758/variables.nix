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
  desktop = "i3"; # keep non-hyprland defaults so Wayland-only utils aren't pulled in
  shell = "nushell";
  tuiFileManager = "yazi";

  # Hardware
  # Discrete GPU: NVIDIA GeForce GTX 680 (Kepler) -> legacy 470 driver.
  videoDriver = "nvidia-kepler";

  # Features
  laptop = false;
  games = false;
  hardwareControl = true;
  # Let the MSI BIOS "Smart Fan" control the CPU fan. We keep the
  # `fancontrol-worker.conf` file around for reference/testing, but do not
  # override firmware by default on this legacy box.
  fancontrol = false;
  hwmonModules = [
    # Z77A-G43 (MS-7758) uses a Fintek Super I/O (fan/PWM + temps).
    "f71882fg"
    "lm78"
  ];

  # Roles
  roles = [ "base" "homelab-agent" ];
}
