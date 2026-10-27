{ pkgs, ... }:
{
  home.packages = [
    pkgs.nixAudit
    pkgs.grype
    pkgs.vulnix
  ];
}
