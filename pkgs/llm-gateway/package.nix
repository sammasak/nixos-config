{
  lib,
  rustPlatform,
  src,
}:
let
  manifest = (lib.importTOML "${src}/crates/gateway/Cargo.toml").package;
in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;
  inherit src;
  cargoLock.lockFile = "${src}/Cargo.lock";
  cargoBuildFlags = [
    "-p"
    "llm-gateway"
  ];
  cargoTestFlags = [
    "-p"
    "llm-gateway"
  ];

  meta = {
    inherit (manifest) description;
    homepage = "https://github.com/sammasak/llm-gateway";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "llm-gateway";
    platforms = lib.platforms.linux;
  };
}
