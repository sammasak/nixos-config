{ ... }:
{
  imports = [
    ../core/automation.nix
    ../core/boot.nix
    ../core/system.nix
    ../core/users.nix
    ../core/network.nix
    ../core/services.nix
    ../core/packages.nix
    ../core/fonts.nix
    ../core/sops.nix
    ../core/resource-hygiene.nix
    ../themes/Catppuccin  # Always apply theming (includes GRUB)
  ];
}
