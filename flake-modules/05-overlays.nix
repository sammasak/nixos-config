{ inputs, ... }:
let
  overlay = import ../pkgs;
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
