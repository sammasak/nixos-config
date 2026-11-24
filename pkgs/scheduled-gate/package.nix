# The scheduled full gate's runner, one stdlib script; ruff and mypy --strict run in the check phase, so a runner that
# does not lint or type-check fails the build.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  pname = "scheduled-gate";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./scheduled_gate.py;
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
    ruff check --no-cache --line-length 120 scheduled_gate.py
    ruff check --no-cache --line-length 120 --select E,F,W,I,UP,B scheduled_gate.py
    MYPY_CACHE_DIR=$TMPDIR/mypy mypy --strict --python-executable ${lib.getExe python3} scheduled_gate.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 scheduled_gate.py $out/bin/scheduled-gate
    runHook postInstall
  '';
  meta = {
    description = "Runs the full nixos:qa on origin/main when it has moved, and writes its node-exporter textfile";
    mainProgram = "scheduled-gate";
  };
}
