{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "factum";
  version = "0.2.0";
  inherit src;
  cargoLock.lockFile = "${src}/Cargo.lock";
  cargoBuildFlags = [ "-p" "factum" ];
  cargoInstallFlags = [ "--path" "crates/factum" ];
  # The release's apply fixture writes an ignored lockfile during the test phase.
  doCheck = false;

  meta = {
    description = "Deterministic Rust diagnostics and impact analysis";
    homepage = "https://github.com/sammasak/factum";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "factum";
    platforms = lib.platforms.linux;
  };
}
