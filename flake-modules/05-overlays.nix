{ inputs, ... }:
{
  perSystem = { system, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ (import ../pkgs) ];
    };
  };

  flake.overlays.default = import ../pkgs;
}
