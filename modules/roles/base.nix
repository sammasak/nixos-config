# Base role for all machines
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
  ];
}
