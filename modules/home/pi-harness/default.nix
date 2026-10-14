# Installs the pi coding agent and the pi-harness extension (performance-first
# classifier harness). The bundle is generated from sammasak/pi-harness
# (`npm run bundle`) and vendored here; regenerate and re-commit when that
# source changes. See vault: nix/nixos-modules.md for the home.file pattern.
{ lib, pkgs, ... }:
{
  # Stage 2 (model-tier) self-activates only where the runtime exposes
  # registerVirtualModel; the pinned nixpkgs build (1.1.0) does, see docs/pi.md.
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
