# Custom packages overlay
final: prev: {
  claude-ctl = final.callPackage ./claude-ctl.nix { };
}
