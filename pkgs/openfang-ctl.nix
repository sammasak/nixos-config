{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "openfang-ctl";
  version = "0.5.3";

  src = fetchFromGitHub {
    owner = "sammasak";
    repo = "openfang-ctl";
    rev = "v${version}";
    sha256 = "1r5r8k9mqhyiy9rch6hz3jramdkxn7whxz3wj48yq6mb2i74qpmq";
  };

  cargoHash = "sha256-3ABE3piLp7r5ogmZGvw6GM+kVBQoYMKTpnUAE2/UoSY=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = with lib; {
    description = "CLI tool for managing OpenFang agents";
    homepage = "https://github.com/sammasak/openfang-ctl";
    license = licenses.mit;
    maintainers = [ ];
  };
}
