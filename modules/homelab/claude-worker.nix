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

    # Expose the kubeconfig at /etc/workstation/kubeconfig so that scripts and
    # verification checks can use the conventional workstation path regardless of
    # where the actual kubeconfig lives (workerHome/.kube/config).
    systemd.tmpfiles.rules = [
      "d /etc/workstation 0755 root root -"
      "L /etc/workstation/kubeconfig - - - - ${cfg.workerHome}/.kube/config"
    ];

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
        # EnvironmentFile is NOT used here because systemd loads it before
        # ExecStartPre runs — if .env doesn't exist yet, the service fails
        # immediately with 'resources' before the wait loop can help.
        # Instead, the start wrapper below sources .env after ExecStartPre waits.
        ExecStartPre = let
          waitForEnv = pkgs.writeShellScript "wait-for-env" ''
            env_file="${cfg.workerHome}/.env"
            for i in $(seq 1 60); do
              [ -f "$env_file" ] && exit 0
              echo "Waiting for $env_file (attempt $i/60)..."
              sleep 1
            done
            echo "ERROR: $env_file not found after 60 seconds"
            exit 1
          '';
          linkClaudeDirs = pkgs.writeShellScript "link-claude-dirs" ''
            # Symlink skills, agents, and settings.json from the Home Manager-managed user home
            # into the workerHome so the claude process (HOME=${cfg.workerHome})
            # can discover them via ~/.claude/skills, ~/.claude/agents, and ~/.claude/settings.json.
            user_claude="/home/${username}/.claude"
            worker_claude="${cfg.workerHome}/.claude"
            mkdir -p "$worker_claude"

            # Skills: link each subdirectory individually, skipping those with a vm-exclude marker.
            src_skills="$user_claude/skills"
            dst_skills="$worker_claude/skills"
            mkdir -p "$dst_skills"
            for skill_dir in "$src_skills"/*/; do
              [ -d "$skill_dir" ] || continue
              skill_name=$(basename "$skill_dir")
              if [ -f "$skill_dir/vm-exclude" ]; then
                echo "Skipping VM-excluded skill: $skill_name"
                continue
              fi
              dst="$dst_skills/$skill_name"
              [ -L "$dst" ] || ln -sfn "$skill_dir" "$dst"
              echo "Linked skill $skill_name"
            done

            # Agents: symlink the whole directory (no per-agent exclusion needed).
            src="$user_claude/agents"
            dst="$worker_claude/agents"
            if [ -d "$src" ] && [ ! -L "$dst" ]; then
              ln -sfn "$src" "$dst"
              echo "Linked $dst -> $src"
            fi

            # Symlink settings.json so hooks and plugin config from Home Manager take effect.
            # The workerHome settings.json (only skipDangerousModePermissionPrompt) is replaced
            # by the full Home Manager-managed settings that include hooks and MCP servers.
            src="$user_claude/settings.json"
            dst="$worker_claude/settings.json"
            if [ -f "$src" ] && [ ! -L "$dst" ]; then
              ln -sfn "$src" "$dst"
              echo "Linked $dst -> $src"
            fi
          '';
        in [ "${waitForEnv}" "${linkClaudeDirs}" ];
        ExecStart = let
          startWrapper = pkgs.writeShellScript "claude-worker-start" ''
            # Source .env after ExecStartPre has confirmed the file exists
            set -a
            . "${cfg.workerHome}/.env"
            set +a
            exec ${claude-worker}/bin/claude-worker
          '';
        in "${startWrapper}";
        Restart = "on-failure";
        RestartSec = "5s";
        StartLimitBurst = 10;
        StartLimitIntervalSec = 120;
        StateDirectory = "claude-worker";
        StateDirectoryMode = "0750";
        NoNewPrivileges = false;      # must be false: rootless buildah needs newuidmap/newgidmap (setuid binaries)
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateDevices = false;       # buildah needs /dev/fuse
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = false;     # must be false: allow setuid/setgid execution for newuidmap/newgidmap
        LockPersonality = true;
        ReadWritePaths = [ cfg.workerHome "/tmp" ];
        DynamicUser = false;
      };
    };
  };
}
