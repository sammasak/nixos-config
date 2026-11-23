# The execution pool's contract crate, a library: the build is its tests, clippy with warnings denied and rustfmt.
{
  lib,
  rustPlatform,
  clippy,
  rustfmt,
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
      ./src
      ./tests
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [
    clippy
    rustfmt
  ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --offline --all-targets -- -D warnings
  '';
  # cargo install refuses a crate with no binary
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp Cargo.toml $out/
    runHook postInstall
  '';
  meta = {
    inherit (manifest) description;
    license = with lib.licenses; [
      mit
      asl20
    ];
    platforms = lib.platforms.linux;
  };
}
