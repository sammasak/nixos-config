# The platform scorecard (docs/measurement.md) as one stdlib-only script; ruff and mypy --strict run in the check
# phase, so a scorecard that does not lint or type-check fails the build, not the weekly report.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  pname = "platform-scorecard";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./scorecard.py;
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
    ruff check --no-cache --line-length 120 scorecard.py
    ruff check --no-cache --line-length 120 --select E,F,W,I,UP,B scorecard.py
    MYPY_CACHE_DIR=$TMPDIR/mypy mypy --strict --python-executable ${lib.getExe python3} scorecard.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 scorecard.py $out/bin/platform-scorecard
    runHook postInstall
  '';
  meta = {
    description = "Platform scorecard: each metric in metrics/targets.json read from Prometheus and Loki, with its verdict";
    mainProgram = "platform-scorecard";
  };
}
