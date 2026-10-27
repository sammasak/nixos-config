# Installs the pi coding agent and the pi-harness extension (performance-first
# classifier harness). The bundle is generated from sammasak/pi-harness
# (`npm run bundle`) and vendored here; regenerate and re-commit when that
# source changes. See vault: nix/nixos-modules.md for the home.file pattern.
{ pkgs, ... }:
{
  # Stage 2 (model-tier) self-activates only where the runtime exposes
  # registerVirtualModel; the pinned nixpkgs build does, see docs/pi.md.
  home.packages = [ pkgs.pi-coding-agent ];

  home.file.".pi/agent/extensions/pi-harness.ts".source = ./pi-harness.bundle.mjs;
}
