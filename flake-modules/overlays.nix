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
        # the wasm-bindgen-cli matching the wasm-bindgen crate in a repo's Cargo.lock
        wasmBindgenCli =
          src:
          let
            crate = lib.findSingle (p: p.name == "wasm-bindgen") (throw "${src}: no wasm-bindgen in Cargo.lock") (
              throw "${src}: two wasm-bindgen versions in Cargo.lock"
            ) (lib.importTOML "${src}/Cargo.lock").package;
          in
          final."wasm-bindgen-cli_${lib.replaceStrings [ "." ] [ "_" ] crate.version}";
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
        llmGateway = final.callPackage ../pkgs/llm-gateway/package.nix {
          rustPlatform = factumRustPlatform;
          src = inputs.llm-gateway;
        };
        nixAudit = final.callPackage ../pkgs/nix-audit/package.nix {
          rustPlatform = factumRustPlatform;
          src = inputs.nix-audit;
          inherit (inputs.nix-audit) rev;
        };
        hermanWeb = final.callPackage ../pkgs/herman-web/package.nix {
          src = inputs.herman;
          inherit (inputs.herman) rev;
          wasmBindgenCli = wasmBindgenCli inputs.herman;
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
