# Nushell - Modern shell
{ pkgs, ... }:
{
  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }
    '';
    extraConfig = ''
      # Run neofetch on interactive shell startup
      if $nu.is-interactive {
        neofetch
      }
    '';
  };
}
