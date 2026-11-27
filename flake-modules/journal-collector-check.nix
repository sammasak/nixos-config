# black-pi's journal collector, validated in nixos:qa: an aarch64 host is only evaluated there, so the module's own
# alloy-config-check never builds before a deploy. This runs x86 Alloy's `alloy validate` on the config text black-pi
# renders; the x86 hosts' collectors are validated by their own toplevel builds.
{ config, lib, ... }:
let
  pi = config.flake.nixosConfigurations.black-pi.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        journal-collector-config-black-pi =
          assert lib.assertMsg pi.homelab.journalCollector.enable
            "journal-collector-check: black-pi no longer enables homelab.journalCollector; drop this check with it";
          pkgs.runCommand "journal-collector-config-black-pi"
            {
              nativeBuildInputs = [
                pkgs.grafana-alloy
                pkgs.python3
              ];
            }
            ''
              alloy validate ${pkgs.writeText "black-pi-config.alloy" pi.services.alloy.configPath.text}
              python3 ${../scripts/test-journal-filter-runtime.py} \
                ${pkgs.writeText "black-pi-config.alloy" pi.services.alloy.configPath.text} \
                ${lib.getExe pkgs.grafana-alloy}
              fake=${pkgs.writeShellScript "alloy-exit-failure" ''
                exec ${pkgs.python3}/bin/python ${../scripts/fixtures/alloy-exit-failure.py} "$@"
              ''}
              if python3 ${../scripts/test-journal-filter-runtime.py} \
                ${pkgs.writeText "black-pi-config.alloy" pi.services.alloy.configPath.text} \
                "$fake" > exit-failure.log 2>&1; then
                echo "journal-collector: runtime harness accepted an Alloy exit failure" >&2
                exit 1
              fi
              grep -F 'Alloy exited with status 2:' exit-failure.log
              touch $out
            '';
        # the ntfy receipt and fail-closed stages render only where ntfy runs; topics as the module derives them on lenovo
        journal-collector-config-lenovo =
          assert lib.assertMsg lenovo.services.ntfy-sh.enable
            "journal-collector-check: lenovo no longer runs ntfy; move this check to the host that does";
          pkgs.runCommand "journal-collector-config-lenovo" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            python3 ${../scripts/test-journal-filter-runtime.py} ${lenovo.services.alloy.configPath} \
              ${lib.getExe lenovo.services.alloy.package} homelab-alerts,homelab-watchdog
            touch $out
          '';
      };
    };
}
