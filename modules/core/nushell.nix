# Nushell - Modern shell (home-manager module)
{ ... }:
{
  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }
    '';
    extraConfig = ''
      # Shell aliases
      alias gco = git checkout

      # Run neofetch on interactive shell startup
      if $nu.is-interactive {
        neofetch
      }
    '';
  };
}
