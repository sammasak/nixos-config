{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "openfang-ctl";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "sammasak";
    repo = "openfang-ctl";
    rev = "v${version}";
    sha256 = "0lgz6qrijd4439hb7r88zizjc29if9c399gmyp8rci8rs3ns75b4";
  };

  cargoHash = "sha256-dKjx2RdMFd54PZ9zvnd37YGGQF/TchvmY9AG+50JBYs=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = with lib; {
    description = "CLI tool for managing OpenFang agents";
    homepage = "https://github.com/sammasak/openfang-ctl";
    license = licenses.mit;
    maintainers = [ ];
  };
}
