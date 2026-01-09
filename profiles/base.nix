# Base profile - Common configuration for ALL machines
# This profile is automatically included for every host

{pkgs, user, config, ...}:
{
  # Allow unfree packages (needed for many proprietary software)
  nixpkgs.config.allowUnfree = true;

  # Keyboard layout - Swedish
  services.xserver.xkb.layout = "se";

  # Timezone
  time.timeZone = "Europe/Stockholm";

  # Enable flakes and nix-command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Networking
  networking.networkmanager.enable = true;

  # Git (system-level)
  programs.git.enable = true;

  # Default user configuration
  users.users.${user} = {
    shell = pkgs.nushell;
    # Password: Set with 'passwd' after first boot or use initialPassword
  };

  # System-wide packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
  ];
}
