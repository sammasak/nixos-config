# Cluster health watchdog. Runs outside k8s so it survives a worker outage, and
# publishes on success as well as failure — see the heartbeat comment below.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
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
      # gnugrep is pinned rather than taken from the system path: a missing grep
      # would make the Watchdog check below fail closed and page for a healthy
      # cluster.
      path = [ pkgs.kubectl pkgs.curl pkgs.gawk pkgs.gnugrep ];
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

          # 5. Alertmanager's built-in Watchdog alert is ACTIVE.
          # Watchdog is an always-firing alert shipped by kube-prometheus. A
          # running Alertmanager pod (check 4) only proves the process is up;
          # if Prometheus has stopped evaluating rules or delivering to
          # Alertmanager, Watchdog goes quiet and every other alert in the
          # cluster silently stops firing too. This is the one check that
          # notices the alerting pipeline itself has died.
          am_ip=$(kubectl -n monitoring get svc monitoring-kube-prometheus-alertmanager \
            -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
          if [ -z "$am_ip" ]; then
            failures="$failures\n• Alertmanager: service has no clusterIP"
          elif ! curl -sf --max-time 10 \
              "http://$am_ip:9093/api/v2/alerts?filter=alertname%3DWatchdog&active=true" \
              2>/dev/null | grep -q '"Watchdog"'; then
            failures="$failures\n• Alertmanager: Watchdog alert not active — alerting pipeline is down"
          fi
        fi

        if [ -n "$failures" ]; then
          curl -sf \
            -H "Title: Homelab cluster degraded" \
            -H "Priority: high" \
            -H "Tags: warning,rotating_light" \
            -d "$(printf "Health check failures:%b\n\nNode: $(hostname -s)\nTime: $(date -u '+%H:%M UTC')" "$failures")" \
            "${cfg.ntfyUrl}" || true
        else
          # Heartbeat on a clean run. This watchdog is otherwise silent when
          # healthy, which is indistinguishable from the watchdog being dead —
          # a stopped timer, a broken kubectl or an unreachable ntfy all look
          # exactly like "everything is fine". Publishing on success turns that
          # silence into a signal any future observer can alert on. Priority min
          # is delivered and retained but does not raise a notification.
          curl -sf \
            -H "Title: watchdog OK" \
            -H "Priority: min" \
            -H "Tags: heavy_check_mark" \
            -d "$(printf "All checks passed.\n\nNode: $(hostname -s)\nTime: $(date -u '+%H:%M UTC')")" \
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
