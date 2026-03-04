{ inputs, ... }:
let
  overlay = import ../pkgs { claude-ctl-src = inputs.claude-ctl; };
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
