{ lib, rustPlatform, pkg-config, openssl }:

rustPlatform.buildRustPackage {
  pname = "claude-ctl";
  version = "0.1.0";

  src = /home/lukas/claude-ctl;

  cargoLock.lockFile = /home/lukas/claude-ctl/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = {
    description = "CLI for managing claude-worker autonomous agent VMs";
    mainProgram = "claude-ctl";
  };
}
