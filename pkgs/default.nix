# Custom packages overlay
final: prev: {
  openfang-ctl = final.callPackage ./openfang-ctl.nix { };
}
