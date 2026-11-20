{ lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.monitoring-baseline =
        pkgs.runCommand "monitoring-baseline"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.ruff
              pkgs.mypy
            ];
          }
          ''
            ruff check --isolated --no-cache --select E4,E7,E9,F,B ${../scripts/monitoring-baseline.py} ${../scripts/test-monitoring-baseline.py}
            mypy --strict --cache-dir "$TMPDIR/mypy" ${../scripts/monitoring-baseline.py}
            python3 -I ${../scripts/test-monitoring-baseline.py} ${../scripts/monitoring-baseline.py}
            touch "$out"
          '';
    };
}
