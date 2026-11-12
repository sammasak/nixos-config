{ ... }:
{
  imports = [
    ../core/automation.nix
    ../core/boot.nix
    ../core/system.nix
    ../core/users.nix
    ../core/network.nix
    ../core/services.nix
    ../core/ssh-known-hosts.nix
    ../core/packages.nix
    ../core/fonts.nix
    ../core/sops.nix
    ../core/resource-hygiene.nix
    ../core/store-cache.nix
    ../homelab/native-otel-relay.nix
    ../themes/Catppuccin  # Always apply theming (includes GRUB)
  ];
}
