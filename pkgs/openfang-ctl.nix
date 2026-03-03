{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "openfang-ctl";
  version = "0.5.4";

  src = fetchFromGitHub {
    owner = "sammasak";
    repo = "openfang-ctl";
    rev = "v${version}";
    sha256 = "1lfsn2qfznnlxgrsnx2xynzn9l3c0a6rk4dis1n8vcnjapiagfvj";
  };

  cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = with lib; {
    description = "CLI tool for managing OpenFang agents";
    homepage = "https://github.com/sammasak/openfang-ctl";
    license = licenses.mit;
    maintainers = [ ];
  };
}
