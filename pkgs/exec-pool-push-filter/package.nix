# A pool slot's git pushes held to its own task's refs (push_filter.py). ruff and mypy run in the build: a broken filter
# fails the build, never a push.
{
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  name = "exec-pool-push-filter";
  src = ./push_filter.py;
  dontUnpack = true;
  nativeBuildInputs = [
    ruff
    mypy
  ];
  buildPhase = ''
    cp $src push_filter.py
    ruff check --no-cache --select E,F,W,B,UP --line-length 120 push_filter.py
    mypy --strict --no-incremental --cache-dir=/dev/null --python-executable ${python3.interpreter} push_filter.py
  '';
  installPhase = ''
    install -Dm755 push_filter.py $out/bin/exec-pool-push-filter
    substituteInPlace $out/bin/exec-pool-push-filter --replace-fail '#!/usr/bin/env python3' '#!${python3.interpreter} -I'
  '';
  meta.mainProgram = "exec-pool-push-filter";
}
