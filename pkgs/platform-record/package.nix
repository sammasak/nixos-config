# One package for the coordinator's timers, the root units and devenv's gates, so each host carries the same store
# path. ruff and mypy run in the build: a broken writer fails the build, not a deploy.
{
  stdenvNoCC,
  python3,
  ruff,
  mypy,
}:
stdenvNoCC.mkDerivation {
  name = "platform-record";
  src = ./platform_record.py;
  schema = ../../metrics/records.json;
  dontUnpack = true;
  nativeBuildInputs = [
    ruff
    mypy
  ];
  buildPhase = ''
    cp $src platform_record.py
    ruff check --no-cache --select E,F,W,B,UP --line-length 120 platform_record.py
    mypy --strict --no-incremental --cache-dir=/dev/null --python-executable ${python3.interpreter} platform_record.py
    ${python3.interpreter} -c 'import json, sys; json.load(open(sys.argv[1]))["kinds"]' $schema
  '';
  installPhase = ''
    install -Dm755 platform_record.py $out/bin/platform-record
    substituteInPlace $out/bin/platform-record --replace-fail '#!/usr/bin/env python3' '#!${python3.interpreter}'
    install -Dm644 $schema $out/share/platform-record/records.json
  '';
  meta.mainProgram = "platform-record";
}
