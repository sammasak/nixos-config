# The never-installed channel: `, cmd` runs any nixpkgs tool via the weekly
# prebuilt index. Do not also add comma/nix-index to home.packages — the
# nix-index-database module owns both and a manual copy conflicts.
{ ... }:
{
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;
}
