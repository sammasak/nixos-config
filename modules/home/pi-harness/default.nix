# Installs the pi coding agent and the pi-harness extension (performance-first
# classifier harness). The bundle is generated from sammasak/pi-harness
# (`npm run bundle`) and vendored here; regenerate and re-commit when that
# source changes. See vault: nix/nixos-modules.md for the home.file pattern.
{ lib, pkgs, ... }:
{
  # nixpkgs ships 0.87.1: stage 1 (routing) works; stage 2 (model-tier) needs a
  # newer runtime that exposes registerVirtualModel and self-activates there
  # (e.g. `nix run github:nklmilojevic/pi-flake` gives 0.99.x with both stages).
  home.packages = [ pkgs.pi-coding-agent ];

  home.file.".pi/agent/extensions/pi-harness.ts".source = ./pi-harness.bundle.mjs;

  # The earlier single-stage router was dropped in imperatively (a real file, not
  # a nix symlink), so home.file can't replace it; move it aside or its input
  # hook double-fires alongside the harness.
  home.activation.retireOldPiRouter = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    old="$HOME/.pi/agent/extensions/system1-router.ts"
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      run mv "$old" "$HOME/.pi/agent/system1-router.ts.superseded"
    fi
  '';
}
