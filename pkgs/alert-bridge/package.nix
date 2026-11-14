{
  lib,
  rustPlatform,
  src,
}:
let
  manifest = (lib.importTOML "${src}/Cargo.toml").package;
in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  inherit (manifest) version;
  inherit src;
  cargoLock.lockFile = "${src}/Cargo.lock";

  meta = {
    inherit (manifest) description;
    homepage = "https://github.com/sammasak/alert-bridge";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "alert-bridge";
    platforms = lib.platforms.linux;
  };
}
