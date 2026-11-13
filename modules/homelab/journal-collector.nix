# The host's own journal to Loki through upstream services.alloy, so it keeps shipping when the cluster
# does not; pod logs stay with the cluster's Alloy DaemonSet.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.journalCollector;
  listen = "127.0.0.1:12345";
in
{
  options.homelab.journalCollector = {
    enable = lib.mkEnableOption "shipping this host's journal to Loki with Alloy";
    lokiUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://10.43.92.124:3100/loki/api/v1/push";
      description = "Loki push endpoint.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      extraFlags = [ "--server.http.listen-addr=${listen}" "--disable-reporting" ];
    };

    # https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/
    environment.etc."alloy/config.alloy".text = ''
      loki.relabel "journal" {
        forward_to = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }
      }

      loki.source.journal "host" {
        forward_to    = [loki.write.loki.receiver]
        relabel_rules = loki.relabel.journal.rules
        labels        = {job = "host-journal", host = "${config.networking.hostName}"}
      }

      loki.write "loki" {
        endpoint {
          url = "${cfg.lokiUrl}"
        }
      }
    '';

    systemd.services.alloy.serviceConfig = {
      # Local only: a probe of Loki would fail the host deploy whenever Loki is away.
      ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 30 --retry-delay 2 --retry-connrefused --retry-max-time 60 http://${listen}/-/ready";
      TimeoutStartSec = 90;
      # mkForce: upstream sets always; a clean exit stays down.
      Restart = lib.mkForce "on-failure";
      MemoryMax = "256M";
    };
  };
}
