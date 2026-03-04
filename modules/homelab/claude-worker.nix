# Claude Worker — HTTP API service wrapping claude CLI with a persistent goals queue.
# Replaces openfang as the autonomous agent runtime in workstation VM images.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optional types;
  cfg = config.homelab.claudeWorker;
  # Parse port from listenAddress (e.g. "0.0.0.0:4200" → 4200)
  listenPort = lib.toInt (lib.last (lib.splitString ":" cfg.listenAddress));
  isPublic = !(lib.hasPrefix "127." cfg.listenAddress) && !(lib.hasPrefix "::1" cfg.listenAddress);
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
      default = "127.0.0.1:4200";
      description = "Address and port for the HTTP listener. Override to 0.0.0.0:4200 only when cluster-external access is required.";
    };

    workerHome = mkOption {
      type = types.str;
      default = "/var/lib/claude-worker";
      description = "Base directory for goals queue, logs, and workspace (mounted from vdb PVC).";
    };
  };

  config = mkIf cfg.enable {
    # Only open the firewall when binding to a non-loopback address.
    networking.firewall.allowedTCPPorts = lib.mkIf isPublic [ listenPort ];

    environment.systemPackages = [ claude-worker ];

    # ── Promtail — ship claude-worker logs to Loki ───────────────────────
    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 9080;
          grpc_listen_port = 0;
        };
        positions = {
          filename = "/var/lib/promtail/positions.yaml";
        };
        clients = [
          { url = "http://monitoring-loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"; }
        ];
        scrape_configs = [
          {
            job_name = "claude-worker";
            static_configs = [
              {
                targets = [ "localhost" ];
                labels = {
                  job = "claude-worker";
                  vm = config.networking.hostName;
                  __path__ = "${cfg.workerHome}/logs/current.log";
                };
              }
            ];
            pipeline_stages = [
              {
                json = {
                  expressions = {
                    type = "type";
                    session_id = "session_id";
                  };
                };
              }
              {
                labels = {
                  type = null;
                  session_id = null;
                };
              }
            ];
          }
        ];
      };
    };

    systemd.services.promtail = {
      after = [ "claude-worker.service" ];
      wants = [ "claude-worker.service" ];
    };

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
        SHELL = "${pkgs.bash}/bin/bash";
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
