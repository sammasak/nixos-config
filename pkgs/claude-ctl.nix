{ lib, rustPlatform, pkg-config, openssl, src }:

rustPlatform.buildRustPackage {
  pname = "claude-ctl";
  version = "0.0.1";

  inherit src;

  cargoLock.lockFile = "${src}/Cargo.lock";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = {
    description = "CLI for managing claude-worker autonomous agent VMs";
    mainProgram = "claude-ctl";
  };
}
