# The host's own journal to Loki through upstream services.alloy. While Loki is away the writer retries forever and its queue
# blocks the reader, so the journal holds the backlog up to max_age. Residual gaps:
# - Alloy stopping or restarting while Loki is away drops its in-memory queue after the 15 s drain timeout (about
#   12 MiB: the 10 MiB send queue plus a batch), since the reader saves its cursor before the send.
# - A crash loop with fewer than 5 start attempts per 600 s never reaches failed, so it pages only once an absence
#   alert exists (P5).
# - dev-env-egress.service: info-level 2xx/3xx Caddy access lines are dropped (72% of msi's volume, one line per
#   proxied request); 4xx, 5xx and all non-access lines are kept. Those kept access lines carry request headers into
#   Loki: X-Claude-Code-Session-Id and user agent in clear, Authorization logged as REDACTED.
# - After a start-limit hit the unit stays failed; recover with `systemctl reset-failed alloy` and a start.
# - Loki is unauthenticated to its allowed sources, so these lines never ship: authentik.service and
#   authentik-worker.service (request lines carry OAuth code and state query strings), user@<uid>.service (every user
#   unit's lines: agent output), login session scopes (sudo's COMMAND= lines) and any line naming `ak`'s
#   command (its shell -c code: PID 1's Started lines, polkit's and sudo's lines, sudo's continuations, any unit).
# - Only this host's own journal is read: with no path, sdjournal opens it SD_JOURNAL_LOCAL_ONLY.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.journalCollector;
  listen = "127.0.0.1:12345";
  # server and worker request lines carry OAuth codes; the assertion refuses an authentik* unit in neither list
  privateAuthentik = [
    "authentik"
    "authentik-worker"
  ];
  shippedAuthentik = [
    # pg_dump to a file and a restore check: counts and errors, no request
    "authentik-backup"
    # Django migrations at start: schema steps, no request
    "authentik-migrate"
    # lenovo pulls the dump over ssh into a file; only errors reach the journal
    "authentik-offhost"
  ];
  unlisted = lib.filter (
    u: lib.hasPrefix "authentik" u && !lib.elem u (privateAuthentik ++ shippedAuthentik)
  ) (lib.attrNames config.systemd.services);
  private = lib.concatStringsSep "|" (
    map (u: "${u}[.]service") privateAuthentik
    ++ [
      "user@[0-9]+[.]service"
      "session"
    ]
  );
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
        regex         = "session-.+\\.scope"
        target_label  = "unit"
        replacement   = "session"
      }

      rule {
        source_labels = ["unit"]
        regex         = "run-.+\\.(scope|service)"
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
        selector            = "{unit=~\"(${private})\"}"
        action              = "drop"
        drop_counter_reason = "private_unit"
      }

      stage.match {
        selector            = "{job=\"host-journal\"} |~ \"(lifecycle|bin)/ak |(^|[^A-Za-z0-9_.-])ak[^A-Za-z0-9_.-]+shell|[(]command continued[)]\""
        action              = "drop"
        drop_counter_reason = "ak_command"
      }

      stage.match {
        selector = "{unit=\"dev-env-egress.service\"}"

        stage.json {
          expressions = {level = "", logger = "", status = ""}
        }

        stage.drop {
          source              = "level,logger,status"
          expression          = "^info;http\\.log\\.access\\.[^;]*;[1-3][0-9][0-9]$"
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
      type = lib.types.strMatching "https?://.+";
      default = "${config.sam.fleet.loki.url}/loki/api/v1/push";
      defaultText = lib.literalExpression ''"''${config.sam.fleet.loki.url}/loki/api/v1/push"'';
      description = "Loki push endpoint.";
    };
    ntfyUrl = lib.mkOption {
      type = lib.types.strMatching "https?://.+";
      default = config.sam.fleet.pageUrl;
      defaultText = lib.literalExpression "config.sam.fleet.pageUrl";
      description = "ntfy topic URL paged when Alloy fails.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      configPath = configFile;
      extraFlags = [
        "--server.http.listen-addr=${listen}"
        "--disable-reporting"
      ];
    };

    system.checks = [
      (pkgs.runCommand "alloy-config-check" { nativeBuildInputs = [ config.services.alloy.package ]; } ''
        alloy validate ${configFile}
        touch $out
      '')
    ];

    assertions = [
      {
        assertion = unlisted == [ ];
        message = "modules/homelab/journal-collector.nix: put ${toString unlisted} in privateAuthentik (never shipped) or shippedAuthentik; a new Authentik unit's lines may carry OAuth codes.";
      }
    ];

    systemd.services.alloy = {
      # the Go heap target under MemoryMax: a catch-up of the 72h backlog otherwise meets the cap as an OOM kill
      environment.GOMEMLIMIT = "200MiB";
      startLimitIntervalSec = 600;
      startLimitBurst = 4;
      onFailure = [ "journal-collector-failed.service" ];
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

    systemd.services.journal-collector-failed = {
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
      };
      script = ''
        ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-connrefused --retry-all-errors -H "Priority: high" -d "alloy failed on ${config.networking.hostName}" ${lib.escapeShellArg cfg.ntfyUrl}
      '';
    };
  };
}
