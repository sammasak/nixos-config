# Base macOS configuration (nix-darwin)
{ pkgs, user, ... }:
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.users.${user} = {
    home = "/Users/${user}";
    shell = pkgs.nushell;
  };

  environment.systemPackages = with pkgs; [ vim wget curl htop ];

  # macOS system preferences
  system.defaults.dock.autohide = true;
  system.defaults.dock.show-recents = false;
  system.defaults.finder.AppleShowAllExtensions = true;
  system.defaults.finder.ShowPathbar = true;
  system.defaults.NSGlobalDomain.KeyRepeat = 2;

  programs.zsh.enable = true;  # Required for nix-darwin
  system.stateVersion = 6;
}
