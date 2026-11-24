# The activation's generation writer (nixos_textfile.py). ruff and mypy run in the build: a broken writer fails the
# build, never an activation.
{
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  name = "nixos-textfile";
  src = ./nixos_textfile.py;
  dontUnpack = true;
  nativeBuildInputs = [
    ruff
    mypy
  ];
  buildPhase = ''
    cp $src nixos_textfile.py
    ruff check --no-cache --select E,F,W,B,UP --line-length 120 nixos_textfile.py
    mypy --strict --no-incremental --cache-dir=/dev/null --python-executable ${python3.interpreter} nixos_textfile.py
  '';
  installPhase = ''
    install -Dm755 nixos_textfile.py $out/bin/nixos-textfile
    substituteInPlace $out/bin/nixos-textfile --replace-fail '#!/usr/bin/env python3' '#!${python3.interpreter} -I'
  '';
  meta.mainProgram = "nixos-textfile";
}
