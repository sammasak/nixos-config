# scripts/test-exec-pool-push-filter.py: real git pushes through Caddy, the filter and git http-backend, all on
# loopback and unix sockets, so it builds in the sandbox.
{ lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        exec-pool-push-filter =
          pkgs.runCommand "exec-pool-push-filter-test"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.caddy
                pkgs.git
              ];
            }
            ''
              cp ${../scripts/gate_probe.py} gate_probe.py
              export HOME=$TMPDIR
              PYTHONPATH=$PWD python3 ${../scripts/test-exec-pool-push-filter.py} ${
                lib.getExe (pkgs.callPackage ../pkgs/exec-pool-push-filter/package.nix { })
              } > $out
              cat $out
            '';
      };
    };
}
