# scripts/test-alert-investigations.py: the installed trigger on a fake Alertmanager, Prometheus, Loki, pool and GitHub.
{ lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        alert-investigations =
          pkgs.runCommand "alert-investigations-test" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              python3 -I ${../scripts/test-alert-investigations.py} ${
                lib.getExe (pkgs.callPackage ../pkgs/alert-investigations/package.nix { })
              } > $out
              cat $out
            '';
      };
    };
}
