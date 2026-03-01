{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "openfang-ctl";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "sammasak";
    repo = "openfang-ctl";
    rev = "v${version}";
    sha256 = "1x65qjxqy58a54zwbqg60xv92gwwv5cg5fcxk1pwhs886cmgq2ry";
  };

  cargoHash = "sha256-K6y2Cp+j25QQKuFFwzIFmUw7aBH54yb2XDdwRFIGM1c=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = with lib; {
    description = "CLI tool for managing OpenFang agents";
    homepage = "https://github.com/sammasak/openfang-ctl";
    license = licenses.mit;
    maintainers = [ ];
  };
}
