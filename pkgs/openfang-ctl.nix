{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "openfang-ctl";
  version = "0.5.2";

  src = fetchFromGitHub {
    owner = "sammasak";
    repo = "openfang-ctl";
    rev = "v${version}";
    sha256 = "1zcnki9skjy5kxvphl4p2s6srdi3ijdnk84723k34mq5af9b5632";
  };

  cargoHash = "sha256-C95u5eOkoTludJ88IhGFd3QkDj8teWCdHianwYHzQL0=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = with lib; {
    description = "CLI tool for managing OpenFang agents";
    homepage = "https://github.com/sammasak/openfang-ctl";
    license = licenses.mit;
    maintainers = [ ];
  };
}
