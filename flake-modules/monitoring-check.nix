# black-pi's promtool (config and rule files), amtool and blackbox --config.check run only in its toplevel's build, so on
# the Pi at deploy. Seeded onto msi, an x86 host, the same modules' checked files build in the flake check; building it
# realises only those files and their tools, never a toplevel.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations) black-pi msi-ms7758;
  modules = [
    # options only: prometheus.nix scrapes homelab.loki.port
    ../modules/homelab/loki.nix
    ../modules/homelab/monitoring/prometheus.nix
    ../modules/homelab/monitoring/alertmanager.nix
  ];
  seeded = (msi-ms7758.extendModules { inherit modules; }).config;
  failing = builtins.filter (a: !a.assertion) seeded.assertions;
  # a check switched off upstream or here would leave this derivation green and unchecked
  checksOn =
    c:
    c.services.prometheus.checkConfig == true
    && c.services.prometheus.alertmanager.checkConfig
    && c.services.prometheus.exporters.blackbox.enableConfigCheck
    && !c.services.prometheus.enableReload;
  s = seeded.systemd.services;
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        monitoring-config-msi-ms7758 = pkgs.writeText "monitoring-config-msi-ms7758" (
          assert lib.assertMsg (
            failing == [ ]
          ) "monitoring-check: the seeded msi fails ${toString (map (a: a.message) failing)}";
          assert lib.assertMsg (
            checksOn seeded && checksOn black-pi.config
          ) "monitoring-check: promtool, amtool or blackbox --config.check is off on black-pi or the seed";
          lib.concatStringsSep "\n" [
            s.prometheus.serviceConfig.ExecStart
            s.alertmanager.serviceConfig.ExecStartPre
            s.prometheus-blackbox-exporter.serviceConfig.ExecStart
          ]
        );
      };
    };
}
