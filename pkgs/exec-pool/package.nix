# The execution pool's contract and queue CLI: the build is its tests (each against a throwaway PostgreSQL on a Unix
# socket in the build directory), clippy with warnings denied and rustfmt.
{
  lib,
  rustPlatform,
  clippy,
  rustfmt,
  postgresql,
}:
let
  manifest = (lib.importTOML ./Cargo.toml).package;
in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  inherit (manifest) version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./clippy.toml
      ./migrations
      ./src
      ./tests
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [
    clippy
    rustfmt
  ];
  nativeCheckInputs = [ postgresql ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --offline --all-targets -- -D warnings
  '';
  meta = {
    inherit (manifest) description;
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "exec-pool-queue";
    platforms = lib.platforms.linux;
  };
}
