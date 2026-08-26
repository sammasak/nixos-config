{ lib, stdenvNoCC, fetchurl, makeWrapper, nodejs }:

let
  version = "0.118.0";
  cliTarball = fetchurl {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}.tgz";
    sha256 = "0s6bp9c7z8isbx67dl3g0p3c9aiwxssl3qkwwxs6j4jwrg44afrx";
  };
  linuxX64Tarball = fetchurl {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}-linux-x64.tgz";
    sha256 = "1jpgcrfw05d44vdyr55qnaxz478m6cw4i5zjr4zj4y4555qjckjj";
  };
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/node_modules/@openai" "$out/bin"

    tar -xzf "${cliTarball}" -C "$out/lib/node_modules/@openai"
    mv "$out/lib/node_modules/@openai/package" "$out/lib/node_modules/@openai/codex"

    tar -xzf "${linuxX64Tarball}" -C "$out/lib/node_modules/@openai"
    mv "$out/lib/node_modules/@openai/package" "$out/lib/node_modules/@openai/codex-linux-x64"

    makeWrapper "${nodejs}/bin/node" "$out/bin/codex" \
      --add-flags "$out/lib/node_modules/@openai/codex/bin/codex.js" \
      --set NODE_PATH "$out/lib/node_modules"

    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenAI Codex CLI";
    homepage = "https://developers.openai.com/codex";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "codex";
  };
}
