# openfang-ctl — Rust CLI for managing OpenFang agents
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.homelab.openfang-ctl;

  # Build openfang-ctl from source using Rust
  openfang-ctl = pkgs.rustPlatform.buildRustPackage rec {
    pname = "openfang-ctl";
    version = "0.1.0";

    src = pkgs.fetchFromGitHub {
      owner = "sammasak";
      repo = "openfang-ctl";
      rev = "v${version}";
      sha256 = "1x65qjxqy58a54zwbqg60xv92gwwv5cg5fcxk1pwhs886cmgq2ry";
    };

    cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ];

    meta = with lib; {
      description = "CLI tool for managing OpenFang agents";
      homepage = "https://github.com/sammasak/openfang-ctl";
      license = licenses.mit;
      maintainers = [ ];
    };
  };
in
{
  options.homelab.openfang-ctl = {
    enable = mkEnableOption "openfang-ctl CLI for managing OpenFang agents";
  };

  config = mkIf cfg.enable {
    # Make binary available system-wide
    environment.systemPackages = [ openfang-ctl ];
  };
}
