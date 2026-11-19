# black-pi's journal collector, validated in nixos:qa: an aarch64 host is only evaluated there, so the module's own
# alloy-config-check never builds before a deploy. This runs x86 Alloy's `alloy validate` on the config text black-pi
# renders; the x86 hosts' collectors are validated by their own toplevel builds.
{ config, lib, ... }:
let
  pi = config.flake.nixosConfigurations.black-pi.config;
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
              touch $out
            '';
      };
    };
}
