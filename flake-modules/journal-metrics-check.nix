{ config, lib, ... }:
let
  hosts = lib.filterAttrs (_: h: h.config.homelab.journalCollector.enable or false) (
    config.flake.nixosConfigurations
  );
  spec = lib.mapAttrs (_: h: {
    service = h.config.systemd.services.journal-metrics.serviceConfig;
    after = h.config.systemd.services.journal-metrics.after;
    wants = h.config.systemd.services.journal-metrics.wants;
    flags = h.config.services.alloy.extraFlags;
    nodeFlags = h.config.services.prometheus.exporters.node.extraFlags;
    timer = h.config.systemd.timers.journal-metrics.timerConfig;
    wantedBy = h.config.systemd.timers.journal-metrics.wantedBy;
  }) hosts;
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.journal-metrics =
        pkgs.runCommand "journal-metrics"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.curl
              pkgs.gawk
              pkgs.coreutils
              pkgs.ruff
              pkgs.shellcheck
              pkgs.prometheus.cli
            ];
            unitSpec = builtins.unsafeDiscardStringContext (builtins.toJSON spec);
            passAsFile = [ "unitSpec" ];
          }
          ''
            shellcheck ${../scripts/journal-metrics.sh}
            ruff check --isolated --no-cache --select E4,E7,E9,F,B ${../scripts/test-journal-metrics.py}
            python3 -I ${../scripts/test-journal-metrics.py} ${../scripts/journal-metrics.sh} "$out" "$unitSpecPath"
            promtool check metrics < "$out/journal.prom"
          '';
    };
}
