# karta's web app and its monty worker as karta's `karta:web-build` and `karta:web-gzip` build them (no wasm-opt, as
# karta's Trunk.toml), with the BUILD_REV file and sw.js cache name its deploy/Containerfile stamps.
{
  lib,
  stdenv,
  rust-bin,
  rustPlatform,
  trunk,
  llvmPackages,
  wasmBindgenCli,
  src,
  rev,
}:
let
  inherit (lib.importTOML "${src}/rust-toolchain.toml") toolchain;
  rust = rust-bin.stable.${toolchain.channel}.minimal.override {
    targets = [ "wasm32-unknown-unknown" ];
  };
  short = builtins.substring 0 7 rev;
in
stdenv.mkDerivation {
  pname = "karta-web";
  version = short;
  inherit src;

  cargoDeps = rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; };
  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    rust
    trunk
    wasmBindgenCli
  ];
  env = {
    CC_wasm32_unknown_unknown = "${llvmPackages.clang-unwrapped}/bin/clang";
    AR_wasm32_unknown_unknown = "${llvmPackages.llvm}/bin/llvm-ar";
  };

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    trunk build --release --offline --config apps/karta-web/Trunk.toml
    dist=apps/karta-web/dist
    printf '%s' ${short} > $dist/BUILD_REV
    sed -i "s/karta-v1/karta-${short}/" $dist/sw.js
    grep -q "karta-${short}" $dist/sw.js
    find $dist -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.css' -o -name '*.html' -o -name '*.svg' \
      -o -name '*.json' -o -name '*.webmanifest' \) -exec gzip -9 -k -n {} +
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r apps/karta-web/dist $out
    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/sammasak/karta";
    platforms = lib.platforms.linux;
  };
}
