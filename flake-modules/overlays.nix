{ inputs, lib, ... }:
let
  overlay = lib.composeManyExtensions [
    inputs.rust-overlay.overlays.default
    (
      final: prev:
      let
        factumToolchain = final.rust-bin.stable."1.99.0".default.override {
          extensions = [
            "clippy"
            "rustfmt"
          ];
        };
        factumRustPlatform = final.makeRustPlatform {
          cargo = factumToolchain;
          rustc = factumToolchain;
        };
      in
      (import ../pkgs final prev)
      // {
        factum = final.callPackage ../pkgs/factum/package.nix {
          clippy = factumToolchain;
          rustfmt = factumToolchain;
          rustPlatform = factumRustPlatform;
          src = inputs.factum;
        };
        alertBridge = final.callPackage ../pkgs/alert-bridge/package.nix {
          rustPlatform = factumRustPlatform;
          src = inputs.alert-bridge;
        };
        nixAudit = final.callPackage ../pkgs/nix-audit/package.nix {
          rustPlatform = factumRustPlatform;
          src = inputs.nix-audit;
          inherit (inputs.nix-audit) rev;
        };
      }
    )
  ];
in
{
  perSystem = { system, pkgs, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ overlay ];
    };
    # hosts.nix stays one row per host, a table nixfmt would unfold.
    formatter = pkgs.nixfmt-tree.override {
      settings.formatter.nixfmt.excludes = [ "flake-modules/hosts.nix" ];
    };
  };

  flake.overlays.default = overlay;
}
