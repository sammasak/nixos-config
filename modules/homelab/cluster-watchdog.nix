# Cluster health watchdog. Runs outside k8s so it survives a worker outage, and
# publishes on success as well as failure — see the heartbeat comment below.
{
  config,
  pkgs,
  ...
}:

let
  ntfyUrl = "http://localhost:${toString config.homelab.ntfy.port}/homelab-watchdog";
  blackPi = config.sam.fleet.hosts.black-pi.address;
  prometheus = "http://${blackPi}:9090";
  alertmanager = "http://${blackPi}:9093";
in
{
  config = {
    systemd.services.cluster-watchdog = {
      description = "Homelab k3s cluster health watchdog";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "k3s.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
        # Prevent a hung curl/kubectl from blocking the next run.
        TimeoutStartSec = "90";
        StateDirectory = "cluster-watchdog";
      };
      # gnugrep is pinned rather than taken from the system path: a missing grep
      # would make the Watchdog check below fail closed and page for a healthy
      # cluster.
      path = [
        pkgs.kubectl
        pkgs.curl
        pkgs.gawk
        pkgs.gnugrep
        pkgs.jq
      ];
      enableStrictShellChecks = true;
      script = ''
        failures=""

        # 1. k3s API health
        if ! kubectl get --raw /healthz --request-timeout=10s &>/dev/null; then
          failures="$failures\n• k3s API not responding"
        else
          # 2. Node readiness
          # One read for the count and the names, so a failed second call cannot change the page's text.
          node_list=$(kubectl get nodes --no-headers 2>/dev/null \
            | awk '$2 != "Ready" {printf "%s ", $1}') || true
          if [ -n "$node_list" ]; then
            not_ready=$(wc -w <<<"$node_list")
            failures="$failures\n• $not_ready node(s) NotReady: $node_list"
          fi

          # 3. Flux objects Ready=False for over a tick (replaces FluxReconciliationFailed; goes with Flux)
          flux_failed=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io \
            -A -o json --request-timeout=20s 2>/dev/null \
            | jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "False"
                and (.lastTransitionTime | fromdateiso8601) < now - 600))
                | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)"] | join(" ")') || true
          if [ -n "$flux_failed" ]; then
            failures="$failures\n• Flux not Ready: $flux_failed"
          fi
        fi

        # 4. Prometheus and Alertmanager on black-pi, outside the k3s branch: an API outage cannot hide them
        if ! curl -sf -o /dev/null --max-time 10 "${prometheus}/-/ready"; then
          failures="$failures\n• Prometheus on black-pi not ready"
        fi
        if ! curl -sf -o /dev/null --max-time 10 "${alertmanager}/-/ready"; then
          failures="$failures\n• Alertmanager on black-pi not ready"
        fi

        # 5. Alertmanager's always-firing Watchdog alert is ACTIVE. A ready
        # Alertmanager only proves the process is up; if Prometheus has
        # stopped evaluating rules or delivering to Alertmanager, Watchdog
        # goes quiet and every other alert silently stops firing too. This is
        # the one check that notices the alerting pipeline itself has died.
        # Not piped: under pipefail a SIGPIPEd curl would page a healthy pipeline.
        am_alerts=$(curl -sf --max-time 10 \
          "${alertmanager}/api/v2/alerts?filter=alertname%3DWatchdog&active=true" \
          2>/dev/null) || true
        if ! grep -q '"Watchdog"' <<<"$am_alerts"; then
          failures="$failures\n• Alertmanager: Watchdog alert not active — alerting pipeline is down"
        fi

        # Pages when the failure set changes and repeats an unchanged one every
        # 6 h. The state moves only once ntfy took the page, so a failed send is
        # retried at the next run.
        last="$STATE_DIRECTORY/failures"
        paged="$STATE_DIRECTORY/paged-at"
        before=$(cat "$last" 2>/dev/null) || true
        now=$(date +%s)
        paged_at=$(cat "$paged" 2>/dev/null) || paged_at=0
        node="${config.networking.hostName}"
        at=$(date -u '+%H:%M UTC')

        if [ -n "$failures" ]; then
          if [ "$failures" != "$before" ] || [ $((now - paged_at)) -ge 21600 ]; then
            title="Homelab cluster degraded"
            [ "$failures" = "$before" ] && title="Homelab cluster still degraded"
            if curl -sf \
              -H "Title: $title" \
              -H "Priority: high" \
              -H "Tags: warning,rotating_light" \
              -d "$(printf 'Health check failures:%b\n\nNode: %s\nTime: %s' "$failures" "$node" "$at")" \
              "${ntfyUrl}"; then
              printf '%s' "$failures" >"$last"
              echo "$now" >"$paged"
            fi
          fi
        else
          if [ -n "$before" ]; then
            curl -sf \
              -H "Title: Homelab cluster recovered" \
              -H "Tags: white_check_mark" \
              -d "$(printf 'All checks pass again.\n\nNode: %s\nTime: %s' "$node" "$at")" \
              "${ntfyUrl}" && rm -f "$last" "$paged"
          fi
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
            -d "$(printf 'All checks passed.\n\nNode: %s\nTime: %s' "$node" "$at")" \
            "${ntfyUrl}" || true
        fi
      '';
    };

    systemd.timers.cluster-watchdog = {
      wantedBy = [ "timers.target" ];
      description = "Homelab cluster health watchdog — every 10 minutes";
      timerConfig = {
        OnCalendar = "*:0/10:00";
        Persistent = true;
      };
    };
  };
}
