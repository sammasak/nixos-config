# Exercise the real metadata writer/collector and the evaluated units without touching any backup data.
{ config, lib, ... }:
let
  acer = config.flake.nixosConfigurations.acer-swift.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
  service = host: unit: host.systemd.services.${unit}.serviceConfig;
  spec = {
    units = {
      authentik-backup = service acer "authentik-backup";
      authentik-offhost = service lenovo "authentik-offhost";
      llm-gateway-backup = service acer "llm-gateway-backup";
      open-webui-backup = service acer "open-webui-backup";
    };
    collectors = {
      acer = service acer "backup-metrics";
      lenovo = service lenovo "backup-metrics";
    };
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.backup-metrics =
        pkgs.runCommand "backup-metrics"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.ruff
              pkgs.prometheus.cli
            ];
            unitSpec = builtins.unsafeDiscardStringContext (builtins.toJSON spec);
            passAsFile = [ "unitSpec" ];
          }
          ''
            ruff check --isolated --no-cache --select F ${../scripts/backup-metrics.py} ${../scripts/test-backup-metrics.py}
            python3 -I ${../scripts/test-backup-metrics.py} ${../scripts/backup-metrics.py} "$out" "$unitSpecPath"
            promtool check metrics < "$out/backup.prom"
          '';
    };
}
