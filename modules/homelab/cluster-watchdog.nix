# Lightweight cluster health watchdog running on the k3s control plane.
# Checks node readiness and monitoring-stack pod status every 10 minutes,
# posts to the local ntfy instance on the first failure in a run.
# Runs outside k8s so it survives worker node outages.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homelab.clusterWatchdog;
in
{
  options.homelab.clusterWatchdog = {
    enable = mkEnableOption "k3s cluster health watchdog";

    interval = mkOption {
      type = types.str;
      default = "*:0/10:00";
      description = "systemd OnCalendar expression. Default: every 10 minutes.";
    };

    ntfyUrl = mkOption {
      type = types.str;
      default = "http://localhost:${toString config.homelab.ntfy.port}/homelab-watchdog";
      defaultText = "http://localhost:<ntfy.port>/homelab-watchdog";
      description = "ntfy push URL for watchdog alerts.";
    };

    kubeconfig = mkOption {
      type = types.str;
      default = "/etc/rancher/k3s/k3s.yaml";
      description = "Path to the kubeconfig used to query the cluster.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.cluster-watchdog = {
      description = "Homelab k3s cluster health watchdog";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "k3s.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Environment = "KUBECONFIG=${cfg.kubeconfig}";
        # Prevent a hung curl/kubectl from blocking the next run.
        TimeoutStartSec = "90";
      };
      path = [ pkgs.kubectl pkgs.curl pkgs.gawk ];
      script = ''
        failures=""

        # 1. k3s API health
        if ! kubectl get --raw /healthz --request-timeout=10s &>/dev/null; then
          failures="$failures\n• k3s API not responding"
        else
          # 2. Node readiness
          not_ready=$(kubectl get nodes --no-headers 2>/dev/null \
            | awk '$2 != "Ready" {count++} END {print count+0}')
          if [ "$not_ready" -gt 0 ]; then
            node_list=$(kubectl get nodes --no-headers 2>/dev/null \
              | awk '$2 != "Ready" {print $1}' | tr '\n' ' ')
            failures="$failures\n• $not_ready node(s) NotReady: $node_list"
          fi

          # 3. Prometheus pod health
          prom_running=$(kubectl -n monitoring get pods \
            -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null \
            | awk '$3 == "Running" {count++} END {print count+0}')
          if [ "$prom_running" -eq 0 ]; then
            failures="$failures\n• Prometheus: no running pods"
          fi

          # 4. Alertmanager pod health
          am_running=$(kubectl -n monitoring get pods \
            -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null \
            | awk '$3 == "Running" {count++} END {print count+0}')
          if [ "$am_running" -eq 0 ]; then
            failures="$failures\n• Alertmanager: no running pods"
          fi
        fi

        if [ -n "$failures" ]; then
          curl -sf \
            -H "Title: Homelab cluster degraded" \
            -H "Priority: high" \
            -H "Tags: warning,rotating_light" \
            -d "$(printf "Health check failures:%b\n\nNode: $(hostname -s)\nTime: $(date -u '+%H:%M UTC')" "$failures")" \
            "${cfg.ntfyUrl}" || true
        fi
      '';
    };

    systemd.timers.cluster-watchdog = {
      wantedBy = [ "timers.target" ];
      description = "Homelab cluster health watchdog — every 10 minutes";
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };
  };
}
