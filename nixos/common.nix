# Base NixOS configuration
{ pkgs, user, ... }:
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "Europe/Stockholm";
  services.xserver.xkb.layout = "se";
  networking.networkmanager.enable = true;
  programs.git.enable = true;

  users.users.${user} = {
    isNormalUser = true;
    shell = pkgs.nushell;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  environment.systemPackages = with pkgs; [ vim wget curl htop ];
}
