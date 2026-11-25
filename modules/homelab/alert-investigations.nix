# One read-only incident-investigator pool session per firing of a switched-on alert (pkgs/alert-investigations), run on
# the coordinator host as its user: that user's ssh login on the pool host is the submitter's (lib/exec-pool-ssh.nix),
# and its gh login posts the report on the alert's issue. Runbook: docs/alert-runbooks.md#alertinvestigationfailed.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.alertInvestigations;
  inherit (config.sam.fleet) listeners;
  wk = config.sam.herdr.coordinatorWakeup;
  user = config.sam.profile.username;
  dir = "/var/lib/alert-investigations";
  pkg = pkgs.callPackage ../../pkgs/alert-investigations/package.nix { };
  pool = import ../../lib/exec-pool-ssh.nix {
    inherit lib pkgs;
    inherit (wk) poolHost;
  };
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  options.homelab.alertInvestigations = {
    alerts = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*");
      default = [ ];
      example = [ "NodeSystemdUnitFailed" ];
      description = "Alert names whose firing, once 15 minutes old, starts one read-only incident-investigator pool session; empty is off.";
    };
    repo = lib.mkOption {
      type = lib.types.str;
      default = "${config.sam.userConfig.git.userName}/nixos-config";
      description = "OWNER/REPO the session checks out at main and the per-alert issues are in.";
    };
    maxPerDay = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Sessions started per alert name in any 24 hours; a firing past it is logged and not investigated.";
    };
  };

  config = lib.mkIf (cfg.alerts != [ ]) {
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
    # node-exporter counts a missing directory as a textfile scrape error until the first run
    systemd.tmpfiles.rules = [ "d ${dir} 0755 ${user} - -" ];

    systemd.services.alert-investigations = {
      description = "Start read-only investigations of firing alerts as pool sessions and post their reports";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.openssh ];
      environment = {
        HOME = "/home/${user}";
        GH_NO_UPDATE_NOTIFIER = "1";
        GH_PROMPT_DISABLED = "1";
      };
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkg)
          "--alerts"
          (lib.concatStringsSep "," cfg.alerts)
          "--alertmanager"
          listeners.alertmanager.url
          "--prometheus"
          listeners.prometheus.url
          "--loki"
          listeners.loki.url
          "--repo"
          cfg.repo
          "--clone-url"
          "https://github.com/${cfg.repo}"
          "--host"
          config.networking.hostName
          "--pool"
          (lib.getExe pool)
          "--gh"
          (lib.getExe pkgs.gh)
          "--max-per-day"
          (toString cfg.maxPerDay)
          "--state"
          "${dir}/state.json"
          "--out"
          "${dir}/alert-investigations.prom"
        ];
        StateDirectory = "alert-investigations";
        StateDirectoryMode = "0755";
        # each command has its own 120 s bound; a run settles and starts a few at most
        TimeoutStartSec = 600;
        MemoryMax = "128M";
        Nice = 10;
        ProtectSystem = "strict";
        # ssh's key and gh's login are read from the home, nothing is written there
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
    systemd.timers.alert-investigations = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*:0/2";
    };

    assertions = [
      {
        assertion = wk.enable && wk.poolHost != null;
        message = "homelab.alertInvestigations: it starts pool sessions through the coordinator's exec-pool wrapper; enable it on the coordinator host (sam.herdr.coordinatorWakeup with poolHost).";
      }
      {
        assertion = lib.all (l: lib.elem config.networking.hostName listeners.${l}.from) [
          "alertmanager"
          "prometheus"
          "loki"
        ];
        message = "homelab.alertInvestigations: this host must be in the alertmanager, prometheus and loki listeners' from (modules/core/fleet.nix).";
      }
    ];
  };
}
