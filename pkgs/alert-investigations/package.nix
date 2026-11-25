# The alert-investigation trigger (alert_investigations.py, modules/homelab/alert-investigations.nix). ruff and mypy run
# in the build: a broken trigger fails the build, never a timer run.
{
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  name = "alert-investigations";
  src = ./alert_investigations.py;
  dontUnpack = true;
  nativeBuildInputs = [
    ruff
    mypy
  ];
  buildPhase = ''
    cp $src alert_investigations.py
    ruff check --no-cache --select E,F,W,B,UP --line-length 120 alert_investigations.py
    mypy --strict --no-incremental --cache-dir=/dev/null --python-executable ${python3.interpreter} alert_investigations.py
  '';
  installPhase = ''
    install -Dm755 alert_investigations.py $out/bin/alert-investigations
    substituteInPlace $out/bin/alert-investigations --replace-fail '#!/usr/bin/env python3' '#!${python3.interpreter} -I'
  '';
  meta.mainProgram = "alert-investigations";
}
