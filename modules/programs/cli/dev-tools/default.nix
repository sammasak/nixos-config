# Backup layer: interactive-only dev tooling most repos never ship. The moment
# a checked-in script or CI step needs one, it moves into that repo's devshell.
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # Profiling / benchmarking
    samply
    hyperfine
    tokio-console
    # Structured data
    yq-go
    fx
    sd
    # Network debugging
    xh
    doggo
    websocat
    # Code / nix intel
    ast-grep
    watchexec
    nix-output-monitor
    statix
    deadnix
    # Misc: postgres client, vault reader, age-from-ssh bootstrap
    pgcli
    glow
    ssh-to-age
    # Not gemini-cli: replaced upstream, flagged for nixpkgs removal.
    antigravity-cli
  ];

  programs.bacon.enable = true;
}
