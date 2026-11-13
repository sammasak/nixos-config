# The host's own journal to Loki through upstream services.alloy, so it keeps shipping when the cluster does not;
# pod logs stay with the cluster's Alloy DaemonSet. While Loki is away the writer retries forever and its queue
# blocks the reader, so the journal holds the backlog up to max_age; Alloy stopping mid-outage loses what it had
# queued in memory (at most the 10 MiB send queue), since the reader saves its cursor before the send.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.journalCollector;
  listen = "127.0.0.1:12345";
  configFile = config.environment.etc."alloy/config.alloy".source;
in
{
  options.homelab.journalCollector = {
    enable = lib.mkEnableOption "shipping this host's journal to Loki with Alloy";
    lokiUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://loki.example:3100/loki/api/v1/push";
      description = "Loki push endpoint.";
    };
    ntfyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ntfy topic URL paged when Alloy fails; null, no page.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      extraFlags = [ "--server.http.listen-addr=${listen}" "--disable-reporting" ];
    };

    # https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/
    # max_age 72h: spans msi's weekend power-off, equals Loki's retention and stays under its 168h reject_old_samples_max_age.
    environment.etc."alloy/config.alloy".text = ''
      loki.relabel "journal" {
        forward_to = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }

        rule {
          source_labels = ["unit"]
          regex         = "(session-[0-9]+|run-.+)\\.(scope|service)"
          target_label  = "unit"
          replacement   = "transient"
        }
      }

      loki.source.journal "host" {
        forward_to    = [loki.write.loki.receiver]
        relabel_rules = loki.relabel.journal.rules
        max_age       = "72h"
        labels        = {job = "host-journal", host = "${config.networking.hostName}"}
      }

      loki.write "loki" {
        endpoint {
          url                 = "${cfg.lokiUrl}"
          max_backoff_retries = 0
        }
      }
    '';

    system.checks = [
      (pkgs.runCommand "alloy-config-check" { nativeBuildInputs = [ config.services.alloy.package ]; } ''
        alloy validate ${configFile}
        touch $out
      '')
    ];

    systemd.services.alloy = {
      restartTriggers = [ configFile ];
      startLimitIntervalSec = 600;
      startLimitBurst = 3;
      onFailure = lib.optional (cfg.ntfyUrl != null) "journal-collector-failed.service";
      serviceConfig = {
        # Local only: a probe of Loki would fail the host deploy whenever Loki is away.
        ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 30 --retry-delay 2 --retry-connrefused --retry-max-time 60 http://${listen}/-/ready";
        TimeoutStartSec = 90;
        MemoryMax = "256M";
      };
    };

    systemd.services.journal-collector-failed = lib.mkIf (cfg.ntfyUrl != null) {
      serviceConfig = { Type = "oneshot"; DynamicUser = true; };
      script = ''
        ${pkgs.curl}/bin/curl -fsS -m 10 -H "Priority: high" -d "alloy failed on ${config.networking.hostName}" ${lib.escapeShellArg cfg.ntfyUrl}
      '';
    };
  };
}
