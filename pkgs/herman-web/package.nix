# herman's web shell as herman's `just web-dist "/"` builds it: trunk, the post-build wasm-opt, sw.js over the shipped
# bytes, then zopfli .gz siblings for Caddy's precompressed file_server.
{
  lib,
  stdenv,
  rust-bin,
  rustPlatform,
  trunk,
  binaryen,
  zopfli,
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
in
stdenv.mkDerivation {
  pname = "herman-web";
  version = builtins.substring 0 7 rev;
  inherit src;

  cargoDeps = rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; };
  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    rust
    trunk
    wasmBindgenCli
    binaryen
    zopfli
  ];
  # ring compiles C for wasm32; the wrapped clang adds host flags wasm32 rejects
  env = {
    CC_wasm32_unknown_unknown = "${llvmPackages.clang-unwrapped}/bin/clang";
    AR_wasm32_unknown_unknown = "${llvmPackages.llvm}/bin/llvm-ar";
  };

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    (cd apps/herman-web && trunk build --release --offline --public-url /)
    dist=apps/herman-web/dist
    wasm=$(echo $dist/herman-web-*_bg.wasm)
    wasm-opt -Oz --flatten --rereloop -Oz --const-hoisting \
      --enable-bulk-memory --enable-nontrapping-float-to-int \
      --enable-sign-ext --converge --strip-producers --zero-filled-memory \
      "$wasm" -o "$wasm.opt"
    mv "$wasm.opt" "$wasm"

    # herman's generate-sw: sort trunk's modulepreload hints, whose order varies, then version the cache by content
    hintline=$(grep -m1 -n '<link rel="modulepreload"' $dist/index.html | cut -d: -f1 || true)
    if [ -n "$hintline" ]; then
      content=$(sed -n "''${hintline}p" $dist/index.html)
      indent="''${content%%<*}"
      body="''${content#"$indent"}"
      tail=""
      case "$body" in *"</head>") tail="</head>"; body="''${body%</head>}";; esac
      sorted=$(printf '%s' "$body" | sed 's|><link|>\n<link|g' | LC_ALL=C sort | tr -d '\n')
      repl="$indent$sorted$tail" awk -v n="$hintline" 'NR==n{print ENVIRON["repl"]; next}{print}' \
        $dist/index.html > $dist/index.html.tmp
      mv $dist/index.html.tmp $dist/index.html
    fi
    files=$(cd $dist && find . -type f ! -name '*.gz' ! -name 'sw.js' | sed 's|^\./||' | LC_ALL=C sort)
    version=$(cd $dist && printf '%s\n' "$files" | xargs -d '\n' sha256sum | sha256sum | cut -c1-12)
    list=$(printf '%s\n' "$files" | awk '{printf "%s\"/%s\"", (NR>1?",":"["), $0} END{printf "]"}')
    sed -e "s|__CACHE_VERSION__|$version|" -e "s|__INDEX_PATH__|/index.html|" -e "s|__PRECACHE_LIST__|$list|" \
      apps/herman-web/sw.template.js > $dist/sw.js

    find $dist -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.html' \) -exec zopfli --i15 {} +
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r apps/herman-web/dist $out
    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/sammasak/herman";
    platforms = lib.platforms.linux;
  };
}
