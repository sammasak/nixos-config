# Starship - Cross-shell prompt (home-manager module)
{ ... }:
{
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
  };
}
