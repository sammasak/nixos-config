# The heavy-work lock wrapper nixos:qa runs itself under, one stdlib script; ruff and mypy --strict run in the check
# phase, so a wrapper that does not lint or type-check fails the build. ps is pinned by path: no wrapper script.
{
  lib,
  stdenvNoCC,
  python3,
  procps,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  pname = "heavy-lock";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./heavy_lock.py;
  };
  nativeBuildInputs = [
    ruff
    mypy
  ];
  buildInputs = [ python3 ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ruff check --no-cache --line-length 120 heavy_lock.py
    ruff check --no-cache --line-length 120 --select E,F,W,I,UP,B heavy_lock.py
    MYPY_CACHE_DIR=$TMPDIR/mypy mypy --strict --python-executable ${lib.getExe python3} heavy_lock.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 heavy_lock.py $out/bin/heavy-lock
    substituteInPlace $out/bin/heavy-lock --replace-fail 'PS = "ps"' 'PS = "${lib.getExe' procps "ps"}"'
    runHook postInstall
  '';
  meta = {
    description = "Runs a command under the host's heavy-work lock, waiting for it and naming its holder";
    mainProgram = "heavy-lock";
  };
}
