# The execution pool's contract and queue CLI: the build is its tests (each against a throwaway PostgreSQL on a Unix
# socket in the build directory, and git for a session's park and resume against a bare remote), clippy with warnings
# denied and rustfmt.
{
  lib,
  rustPlatform,
  clippy,
  rustfmt,
  postgresql,
  git,
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
  nativeCheckInputs = [
    postgresql
    git
  ];
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
