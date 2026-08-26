{
  inputs.nixpkgs.url = "nixpkgs";
  outputs = { self, nixpkgs }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [
        rustc
        cargo
        pkg-config
        openssl.dev
        pkgsStatic.stdenv.cc
      ];
    };

    packages.x86_64-linux.default = pkgs.rustPlatform.buildRustPackage {
      pname = "claude-worker";
      version = "0.1.0";
      src = ./.;
      cargoLock.lockFile = ./Cargo.lock;
      buildInputs = [ pkgs.openssl ];
      nativeBuildInputs = [ pkgs.pkg-config ];
      meta.mainProgram = "claude-worker";
    };
  };
}
