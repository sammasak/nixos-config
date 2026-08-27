# Enabling this grants the trigger principal CONTROL-PLANE DEPLOY: anyone who can
# write /run/nixos-rebuild-trigger/request can deploy any pushed revision of
# sammasak/nixos-config to this host. The source is a pinned 40-char SHA fetched
# from the remote, never the local clone. Never deploy a change to THIS module
# through the trigger itself.
# See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.nixosRebuildTrigger;
  username = config.sam.profile.username;
  # Resolved, not assumed eponymous: NixOS gives a normal user the shared `users`
  # group, and a tmpfiles rule naming a non-existent group is silently useless.
  triggerGroup = config.users.users.${username}.group;
  triggerDir = "/run/nixos-rebuild-trigger";
  triggerFile = "${triggerDir}/request";
  resultFile = "${triggerDir}/result";
  auditLog = "/var/log/nixos-rebuild-trigger.log";
  lockFile = "/var/lib/nixos-rebuild-trigger/deploy.lock";
  activationUnit = "nixos-rebuild-activation";

  runtimePkgs = with pkgs; [
    nixos-rebuild
    git
    openssh
    util-linux
    iproute2
    curl
    coreutils
    gnugrep
    gnused
    systemd
  ];

  # common.sh is prepended rather than sourced so the build-time shellcheck sees
  # helpers and callers as one file; nothing about the pair is dynamic.
  mkScript =
    name: body:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = runtimePkgs;
      text = builtins.readFile ./common.sh + builtins.readFile body;
    };

  triggerScript = mkScript "nixos-rebuild-trigger" ./trigger.sh;
  activateScript = mkScript "nixos-rebuild-activate" ./activate.sh;
in
{
  options.homelab.nixosRebuildTrigger = {
    enable = mkEnableOption "path-activated, health-gated nixos-rebuild for board worker";

    flakeRef = mkOption {
      type = types.str;
      default = "github:sammasak/nixos-config";
      description = ''
        Remote flake reference (without revision) the rebuild is pinned to.
        A full git SHA supplied in the request is appended as `/<rev>`. The local
        writable clone is deliberately NOT used - the source is always fetched
        fresh and integrity-checked from this remote so the triggering agent
        cannot inject Nix that runs as root.
      '';
    };

    hostAttr = mkOption {
      type = types.str;
      default = "lenovo";
      description = "nixosConfigurations attribute to build (flake#<hostAttr>).";
    };

    healthTimeoutSec = mkOption {
      type = types.int;
      default = 120;
      description = ''
        Seconds to wait for post-activation health checks (k3s API :6443, sshd,
        DNS) to pass before triggering an automatic rollback to the previous
        generation.
      '';
    };
  };

  config = mkIf cfg.enable {
    # WHO CAN TRIGGER: any member of `${triggerGroup}` — 0770 is what makes the
    # request file writable without sudo, and it is the whole trust boundary.
    systemd.tmpfiles.rules = [
      "d ${triggerDir} 0770 root ${triggerGroup} -"
      # Persistent state dir for the deploy lock (survives reboots, outside /run).
      "d /var/lib/nixos-rebuild-trigger 0700 root root -"
    ];

    # The tmpfiles rule alone is not enough: /run rules are applied only at boot
    # by systemd-tmpfiles-setup, so a switch that introduces one leaves the
    # directory missing — and the trigger dead — until the next reboot. That is
    # how this module first shipped broken. This oneshot runs during activation.
    systemd.services.nixos-rebuild-trigger-dir = {
      description = "Provision the nixos-rebuild trigger request directory";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        install -d -m 0770 -o root -g ${triggerGroup} "${triggerDir}"
      '';
    };

    systemd.paths.nixos-rebuild-trigger = {
      description = "Board-worker nixos-rebuild trigger (path watch)";
      wantedBy = [ "multi-user.target" ];
      # Wants, not Requires: a Requires on a oneshot would propagate the
      # oneshot's eventual stop back to the path unit.
      wants = [ "nixos-rebuild-trigger-dir.service" ];
      after = [ "nixos-rebuild-trigger-dir.service" ];
      pathConfig.PathExists = triggerFile;
    };

    # Audit trail: append-only ${auditLog}, journald, and ${resultFile} for pollers.
    systemd.services.nixos-rebuild-trigger = {
      description = "Pinned, health-gated nixos-rebuild (board-worker trigger)";
      after = [ "nix-daemon.service" "network-online.target" "nixos-rebuild-trigger-dir.service" ];
      wants = [ "nix-daemon.service" "network-online.target" "nixos-rebuild-trigger-dir.service" ];
      path = [ "/run/current-system/sw/bin" ];
      # trigger.sh forwards the four activation values on to the transient unit
      # with --setenv; nothing is interpolated into the shell sources.
      environment = {
        TRIGGER_DIR = triggerDir;
        TRIGGER_FILE = triggerFile;
        TRIGGER_GROUP = triggerGroup;
        RESULT_FILE = resultFile;
        AUDIT_LOG = auditLog;
        LOCK_FILE = lockFile;
        FLAKE_REF = cfg.flakeRef;
        HOST_ATTR = cfg.hostAttr;
        ACTIVATION_UNIT = activationUnit;
        ACTIVATE_SCRIPT = lib.getExe activateScript;
        HEALTH_TIMEOUT_SEC = toString cfg.healthTimeoutSec;
        TRIGGER_USER = username;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        SyslogIdentifier = "nixos-rebuild-trigger";
        TimeoutStartSec = 3600;
        StandardOutput = "journal";
        StandardError = "journal";
        ExecStart = lib.getExe triggerScript;
      };
    };
  };
}
