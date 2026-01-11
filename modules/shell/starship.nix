# Starship - Cross-shell prompt
{ ... }:
{
  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    enableBashIntegration = true;  # Useful for servers or fallback
  };
}
