{ inputs, ... }:
let
  overlay = final: prev: (import ../pkgs final prev) // {
    factum = final.callPackage ../pkgs/factum/package.nix { src = inputs.factum; };
  };
in
{
  perSystem = { system, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ overlay ];
    };
  };

  flake.overlays.default = overlay;
}
