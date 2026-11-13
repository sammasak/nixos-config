# The host's own journal to Loki through upstream services.alloy, so it keeps shipping when the cluster does not;
# pod logs stay with the cluster's Alloy DaemonSet. While Loki is away the writer retries forever and its queue
# blocks the reader, so the journal holds the backlog up to max_age. Residual gaps:
# - Alloy stopping or restarting while Loki is away drops its in-memory queue after the 15 s drain timeout (about
#   12 MiB: the 10 MiB send queue plus a batch), since the reader saves its cursor before the send.
# - A crash loop with fewer than 5 start attempts per 600 s never reaches failed, so it pages only once an absence
#   alert exists (P5).
# - Info-level Caddy access lines of dev-env-egress.service are dropped (72% of msi's volume, one line per proxied
#   request); its startup, warning and error lines, and access lines at error level (5xx), are kept.
# - After a start-limit hit the unit stays failed; recover with `systemctl reset-failed alloy` and a start.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.journalCollector;
  listen = "127.0.0.1:12345";
  # https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/
  # max_age 72h: spans msi's weekend power-off, equals Loki's retention and stays under its 168h reject_old_samples_max_age.
  configFile = pkgs.writeText "config.alloy" ''
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

      rule {
        source_labels = ["unit"]
        regex         = "systemd-coredump@.+\\.service"
        target_label  = "unit"
        replacement   = "systemd-coredump"
      }
    }

    loki.process "drop" {
      forward_to = [loki.write.loki.receiver]

      stage.match {
        selector = "{unit=\"dev-env-egress.service\"}"

        stage.json {
          expressions = {level = "", logger = ""}
        }

        stage.drop {
          source              = "level,logger"
          expression          = "^info;http\\.log\\.access\\."
          drop_counter_reason = "egress_access_log"
        }
      }
    }

    loki.source.journal "host" {
      forward_to    = [loki.process.drop.receiver]
      relabel_rules = loki.relabel.journal.rules
      max_age       = "72h"
      labels        = {job = "host-journal", host = ${builtins.toJSON config.networking.hostName}}
    }

    loki.write "loki" {
      endpoint {
        url                 = ${builtins.toJSON cfg.lokiUrl}
        max_backoff_retries = 0
      }
    }
  '';
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
      configPath = configFile;
      extraFlags = [ "--server.http.listen-addr=${listen}" "--disable-reporting" ];
    };

    system.checks = [
      (pkgs.runCommand "alloy-config-check" { nativeBuildInputs = [ config.services.alloy.package ]; } ''
        alloy validate ${configFile}
        touch $out
      '')
    ];

    systemd.services.alloy = {
      startLimitIntervalSec = 600;
      startLimitBurst = 4;
      onFailure = lib.optional (cfg.ntfyUrl != null) "journal-collector-failed.service";
      serviceConfig = {
        # Local only: a probe of Loki would fail the host deploy whenever Loki is away. It covers the config load;
        # a dead journal reader shows only in the post-deploy Loki query.
        ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 30 --retry-delay 2 --retry-connrefused --retry-max-time 60 http://${listen}/-/ready";
        TimeoutStartSec = 90;
        MemoryMax = "256M";
        # mkForce: upstream's 2 s spends the start limit in seconds, so a rollback's own start could be refused.
        RestartSec = lib.mkForce 30;
      };
    };

    systemd.services.journal-collector-failed = lib.mkIf (cfg.ntfyUrl != null) {
      serviceConfig = { Type = "oneshot"; DynamicUser = true; };
      script = ''
        ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-connrefused -H "Priority: high" -d "alloy failed on ${config.networking.hostName}" ${lib.escapeShellArg cfg.ntfyUrl}
      '';
    };
  };
}
