# Installs the pi-harness extension (performance-first classifier harness) for
# the pi coding agent. The bundle is generated from sammasak/pi-harness
# (`npm run bundle`) and vendored here; regenerate and re-commit when that
# source changes. See vault: nix/nixos-modules.md for the home.file pattern.
{ lib, ... }:
{
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
