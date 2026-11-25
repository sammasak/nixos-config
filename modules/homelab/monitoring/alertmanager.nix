# Alertmanager on black-pi through upstream services.prometheus.alertmanager: one route and its inhibitions,
# one webhook publishing to lenovo's ntfy as JSON. Upstream passes the file through envsubst, so a literal `$` must be written `$$`.
{ config, lib, ... }:
let
  inherit (config.sam.fleet) hosts ntfy pageUrl;
  hostOff = [ "alertname = HostExpectedOff" ];
  # https://prometheus.io/docs/alerting/latest/configuration/#webhook_config and
  # https://docs.ntfy.sh/publish/#publish-as-json. Alertmanager (0.33.1, template.DeepCopyWithTemplate) parses each
  # rendered string as YAML and sends what that yields unless it is a string: "[a, b]" goes out as tags' list and "3"
  # as priority's int, but "[WARNING] X" as the list [WARNING] and "Disk full:\nQuery: q" as an object, which ntfy
  # refuses. A leading tab fails that parse and ntfy trims it, so title and message carry one.
  bySeverity =
    resolved: critical: warning: info: other:
    lib.concatStrings [
      ''{{ if eq .Status "resolved" }}${resolved}''
      ''{{ else if eq .CommonLabels.severity "critical" }}${critical}''
      ''{{ else if eq (or .CommonLabels.severity "warning") "warning" }}${warning}''
      ''{{ else if eq .CommonLabels.severity "info" }}${info}''
      "{{ else }}${other}{{ end }}"
    ];
  # No template function subtracts, so the overflow line counts all alerts. printf cuts runes, not bytes: ntfy's
  # 4096-byte message limit holds only for mostly ASCII text, a longer message becomes a refused attachment.
  message = lib.concatStrings [
    "\t"
    ''{{ printf "%.1000s" .CommonAnnotations.summary }}''
    "{{ with .CommonAnnotations.description }}{{ if ne . $$.CommonAnnotations.summary }}"
    "\n"
    ''{{ printf "%.400s" . }}{{ end }}{{ end }}''
    "{{ range $$i, $$a := .Alerts }}{{ if lt $$i 4 }}"
    "{{ with or $$a.Labels.pod $$a.Labels.instance $$a.Labels.job $$a.Labels.namespace }}"
    "\n  • {{ . }}{{ end }}{{ end }}{{ end }}"
    "{{ if gt (len .Alerts) 4 }}\n  … {{ len .Alerts }} in all{{ end }}"
    "{{ with .CommonAnnotations.query }}\nQuery: "
    ''{{ printf "%.600s" . }}{{ end }}''
  ];
  # the shipping policy's quiet hours, in UTC: a location would need tzdata where amtool checks the file. 19:00 to
  # 07:30 covers 21:00 to 08:30 Stockholm in both seasons, and mutes one more hour: 20:00 to 21:00 in winter (CET),
  # 08:30 to 09:30 in summer (CEST)
  quiet = (lib.importJSON ./shipping-policy.json).notify;
  clock =
    h:
    let
      m = builtins.floor (h * 60.0);
    in
    "${lib.fixedWidthNumber 2 (m / 60)}:${lib.fixedWidthNumber 2 (lib.mod m 60)}";
  from = clock quiet.quietFromUtcHour.value;
  until = clock quiet.quietUntilUtcHour.value;
  night =
    assert lib.assertMsg (
      from != until
    ) "shipping-policy.json: notify's quiet hours start and end at ${from}";
    if quiet.quietFromUtcHour.value > quiet.quietUntilUtcHour.value then
      [
        {
          start_time = from;
          end_time = "24:00";
        }
        {
          start_time = "00:00";
          end_time = until;
        }
      ]
    else
      [
        {
          start_time = from;
          end_time = until;
        }
      ];
in
{
  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = hosts.${config.networking.hostName}.address;
    inherit (config.sam.fleet.listeners.alertmanager) port;
    # one instance: no gossip listener on 9094
    extraFlags = [ "--cluster.listen-address=" ];
    configuration = {
      global.resolve_timeout = "5m";
      route = {
        group_by = [
          "namespace"
          "alertname"
          "severity"
        ];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "12h";
        receiver = "ntfy";
        # Watchdog pages no one: lenovo's cluster-watchdog reads it from /api/v2/alerts
        routes = [
          {
            receiver = "null";
            matchers = [ ''alertname =~ "Watchdog|HostExpectedOff"'' ];
          }
          # a rule's notify="none" keeps it in the alert list and off the phone; so does severity="info"
          {
            receiver = "null";
            matchers = [ ''notify = "none"'' ];
          }
          {
            receiver = "null";
            matchers = [ ''severity = "info"'' ];
          }
          # shipping alerts (rules/shipping.nix) wait for the morning; one firing then is sent when the night ends
          {
            receiver = "ntfy";
            matchers = [ ''team = "shipping"'' ];
            mute_time_intervals = [ "night" ];
          }
        ];
      };
      time_intervals = [
        {
          name = "night";
          time_intervals = [ { times = night; } ];
        }
      ];
      receivers = [
        { name = "null"; }
        {
          name = "ntfy";
          webhook_configs = [
            {
              # the root URL takes a JSON publish; ntfy admits any LAN source without credentials (fleet.nix public)
              url = "${ntfy.url}/";
              send_resolved = true;
              payload = {
                topic = lib.removePrefix "${ntfy.url}/" pageUrl;
                title = lib.concatStrings [
                  "\t"
                  ''{{ if eq .Status "resolved" }}[RESOLVED]''
                  ''{{ else }}[{{ or .CommonLabels.severity "warning" | toUpper }}]{{ end }}''
                  " {{ .CommonLabels.alertname }}"
                  ''{{ if and (ne .Status "resolved") (gt (len .Alerts) 1) }} ×{{ len .Alerts }}{{ end }}''
                ];
                tags =
                  bySeverity "[white_check_mark, green_circle]" "[rotating_light, red_circle]"
                    "[warning, orange_circle]"
                    "[information_source]"
                    "[warning]";
                priority = bySeverity "1" "4" "3" "1" "3";
                # an empty render goes out as null, no link
                click = ''{{ if match "^https?://[[:graph:]]+$" .CommonAnnotations.runbook_url }}{{ .CommonAnnotations.runbook_url }}{{ end }}'';
                inherit message;
              };
            }
          ];
        }
      ];
      inhibit_rules = [
        {
          source_matchers = [ "severity = critical" ];
          target_matchers = [ "severity =~ warning|info" ];
          equal = [
            "namespace"
            "alertname"
          ];
        }
        {
          source_matchers = [ "severity = warning" ];
          target_matchers = [ "severity = info" ];
          equal = [
            "namespace"
            "alertname"
          ];
        }
        # Planned power-off of a sleeping host (homelab-gitops#188): while HostExpectedOff fires for it
        # (./rules/homelab.yaml, ./rules/homelab.nix), silence what it causes. With a host that does not sleep down, it does not fire.
        # 1) anything labelled with that host;
        {
          source_matchers = hostOff;
          target_matchers = [ ''node =~ ".+"'' ];
          equal = [ "node" ];
        }
        #    TargetDown carries no node; it leaves the host's targets out itself (./rules/general.yaml).
        # 2) GpuTelemetryDown is the per-host page for a dead GPU exporter: its TargetDown would say it twice
        {
          source_matchers = [ "alertname = GpuTelemetryDown" ];
          target_matchers = [
            "alertname = TargetDown"
            ''job = "nvidia-gpu"''
          ];
        }
        # 3) UnitOOMKilled (Loki's ruler) names the unit NodeOOMKill only counts; NodeOOMKill's for: gives the journal
        #    line time to arrive, and it still pages when the journal path is down
        {
          source_matchers = [ "alertname = UnitOOMKilled" ];
          target_matchers = [ "alertname = NodeOOMKill" ];
          equal = [ "node" ];
        }
      ];
    };
  };

  systemd.services.alertmanager.serviceConfig = {
    RestartSec = 10;
    MemoryMax = "64M";
  };

  assertions = [
    {
      assertion = lib.elem "--cluster.listen-address=" config.services.prometheus.alertmanager.extraFlags;
      message = "modules/homelab/monitoring/alertmanager.nix: Alertmanager runs unclustered; rules/alertmanager.yaml leaves out the cluster alerts, so add them back with a second instance.";
    }
  ];
}
