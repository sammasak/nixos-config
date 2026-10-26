{
  lib,
  rustPlatform,
  src,
  rev,
}:
rustPlatform.buildRustPackage {
  pname = "nix-audit";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = "${src}/Cargo.lock";
  cargoBuildFlags = [ "-p" "nix-audit" ];
  cargoInstallFlags = [ "-p" "nix-audit" ];
  cargoTestFlags = [ "--workspace" ];
  # A flake input carries no .git; nix-audit then reports this locked rev as
  # `(<rev>, declared by the build)` instead of `unknown revision`.
  env.NIX_AUDIT_DECLARED_REVISION = rev;
  postInstall = ''
    install -Dm644 examples/policy.toml $out/share/nix-audit/policy.toml
  '';

  meta = {
    description = "Read-only inventory and security evidence for Nix closures";
    homepage = "https://github.com/sammasak/nix-audit";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "nix-audit";
    platforms = lib.platforms.linux;
  };
}
