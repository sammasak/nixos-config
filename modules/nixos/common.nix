{ pkgs, ...}:
{
  services.openssh.enable = true;

  programs.git.enable = true;
}
