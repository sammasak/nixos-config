{pkgs, user, ...}:
{
  nixpkgs.config.allowUnfree = true;

  services.xserver.xkb.layout = "se";

  time.timeZone = "Europe/Stockholm";
  
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  programs.git.enable = true;


  users.users.${user}.shell = pkgs.nushell;
}
