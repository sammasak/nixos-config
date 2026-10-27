{
  fetchgit,
  gitMinimal,
  lib,
  rustPlatform,
}:
let
  rev = "12d640a542957e31680646e9f25c9f6c63e2564e";
  src = fetchgit {
    url = "git+ssh://git@github.com/sammasak/nix-audit.git";
    inherit rev;
    hash = "sha256-gavOZsCWD7bvtxC2KdC73iHTCbELYn3icQBE8w/0Kv0=";
    leaveDotGit = true;
  };
in
rustPlatform.buildRustPackage {
  pname = "nix-audit";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = "${src}/Cargo.lock";
  nativeBuildInputs = [ gitMinimal ];
  cargoBuildFlags = [ "-p" "nix-audit" ];
  cargoInstallFlags = [ "-p" "nix-audit" ];
  cargoTestFlags = [ "--workspace" ];
  postUnpack = ''
    if [ ! -e "$sourceRoot/.git" ]; then
      cp -a ${src}/.git "$sourceRoot/.git"
    fi
    chmod u+w "$sourceRoot/.git"
  '';
  preBuild = ''
    export GIT_CONFIG_GLOBAL="$TMPDIR/nix-audit-gitconfig"
    ${gitMinimal}/bin/git config --global --add safe.directory "$PWD"
    ${gitMinimal}/bin/git read-tree HEAD
    test "$(${gitMinimal}/bin/git rev-parse --verify HEAD)" = "${rev}"
    test -z "$(${gitMinimal}/bin/git status --porcelain --untracked-files=no)"
  '';

  meta = {
    description = "Read-only inventory and security evidence for Nix closures";
    homepage = "https://github.com/sammasak/nix-audit";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "nix-audit";
    platforms = lib.platforms.linux;
  };
}
