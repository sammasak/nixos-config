# Claude Worker — HTTP API service wrapping claude CLI with a persistent goals queue.
# Replaces openfang as the autonomous agent runtime in workstation VM images.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optional types;
  cfg = config.homelab.claudeWorker;
  username = config.sam.profile.username;

  # ── Build claude-worker binary from source ────────────────────────────
  claude-worker = pkgs.rustPlatform.buildRustPackage {
    pname = "claude-worker";
    version = "0.1.0";
    src = ./claude-worker;
    cargoLock.lockFile = ./claude-worker/Cargo.lock;
    buildInputs = [ pkgs.openssl ];
    nativeBuildInputs = [ pkgs.pkg-config ];
    meta.mainProgram = "claude-worker";
  };
in
{
  options.homelab.claudeWorker = {
    enable = mkEnableOption "Claude Worker agent runtime";

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0:4200";
      description = "Address and port for the HTTP listener.";
    };

    workerHome = mkOption {
      type = types.str;
      default = "/var/lib/claude-worker";
      description = "Base directory for goals queue, logs, and workspace (mounted from vdb PVC).";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ 4200 ];

    environment.systemPackages = [ claude-worker ];

    # ── Systemd service ─────────────────────────────────────────────────
    systemd.services.claude-worker = {
      description = "Claude Worker agent runtime";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        CLAUDE_WORKER_HOME = cfg.workerHome;
        CLAUDE_WORKER_LISTEN = cfg.listenAddress;
        HOME = cfg.workerHome;
        XDG_DATA_HOME = "${cfg.workerHome}/.local/share";
      };

      # Tools needed by claude CLI and hook scripts
      path = [ "/run/wrappers" ] ++ (with pkgs; [
        bash
        coreutils
        git
        gh
        curl
        jq
        kubectl
        fluxcd
        sops
        age
        yq-go
        nix
        buildah
        shadow        # newuidmap/newgidmap for user namespaces
        claude-code   # claude CLI for spawning headless sessions
      ]);

      serviceConfig = {
        Type = "simple";
        User = username;
        Group = "users";
        WorkingDirectory = cfg.workerHome;
        EnvironmentFile = "${cfg.workerHome}/.env";
        ExecStart = "${claude-worker}/bin/claude-worker";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = "claude-worker";
        StateDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateDevices = false;       # buildah needs /dev/fuse
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        ReadWritePaths = [ cfg.workerHome "/tmp" ];
        DynamicUser = false;
      };
    };
  };
}
