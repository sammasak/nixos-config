# Custom packages overlay
{ claude-ctl-src }:
final: prev: {
  claude-ctl = final.callPackage ./claude-ctl.nix { src = claude-ctl-src; };
}
