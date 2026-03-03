# OpenFang agent runtime — binary packaging, MCP servers, systemd service
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optional types;
  cfg = config.homelab.openfang;
  username = config.sam.profile.username;

  # ── OpenFang binary ───────────────────────────────────────────────
  openfang = pkgs.stdenv.mkDerivation rec {
    pname = "openfang";
    version = "0.3.5";

    src = pkgs.fetchurl {
      url = "https://github.com/RightNow-AI/openfang/releases/download/v${version}/openfang-x86_64-unknown-linux-gnu.tar.gz";
      sha256 = "0jnm0qgxrw9kq6vhqwc2zjw05b2qb2phw6xff7ag7xpx4v8jhv64";
    };

    sourceRoot = ".";
    dontBuild = true;

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.openssl ];

    installPhase = ''
      runHook preInstall
      install -Dm755 openfang $out/bin/openfang
      runHook postInstall
    '';
  };

  # ── MCP server: kubernetes-mcp-server ─────────────────────────────
  kubernetes-mcp-server = pkgs.stdenv.mkDerivation rec {
    pname = "kubernetes-mcp-server";
    version = "0.0.58";

    src = pkgs.fetchurl {
      url = "https://github.com/containers/kubernetes-mcp-server/releases/download/v${version}/${pname}-linux-amd64";
      sha256 = "04x811p84ziwjcz6y0vs9j74mbpzg790ksdv629rjm8qv3w0k1m1";
    };

    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/kubernetes-mcp-server
      runHook postInstall
    '';
  };

  # ── MCP server: mcp-grafana ───────────────────────────────────────
  mcp-grafana = pkgs.stdenv.mkDerivation rec {
    pname = "mcp-grafana";
    version = "0.11.2";

    src = pkgs.fetchurl {
      url = "https://github.com/grafana/mcp-grafana/releases/download/v${version}/${pname}_Linux_x86_64.tar.gz";
      sha256 = "1l3a3839fy5wp8cw89ahw3gihcm6jisj03q9pfzj2f8gflfhlzns";
    };

    sourceRoot = ".";

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 mcp-grafana $out/bin/mcp-grafana
      runHook postInstall
    '';
  };

  # ── MCP server: flux-operator-mcp (optional) ──────────────────────
  # Distributed as part of the flux-operator releases from controlplaneio-fluxcd.
  flux-operator-mcp = pkgs.stdenv.mkDerivation rec {
    pname = "flux-operator-mcp";
    version = "0.43.0";

    src = pkgs.fetchurl {
      url = "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${version}/${pname}_${version}_linux_amd64.tar.gz";
      sha256 = "09fyfzah1r8kbbm4izk26b5z8wk846aq9f2zh42zky3q0ksf7czd";
    };

    sourceRoot = ".";

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 flux-operator-mcp $out/bin/flux-operator-mcp
      runHook postInstall
    '';
  };

  # Collect enabled MCP server packages for the service PATH
  mcpPackages =
    optional cfg.mcpServers.kubernetes.enable kubernetes-mcp-server
    ++ optional cfg.mcpServers.grafana.enable mcp-grafana
    ++ optional cfg.mcpServers.flux.enable flux-operator-mcp;
in
{
  options.homelab.openfang = {
    enable = mkEnableOption "OpenFang agent runtime";

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0:4200";
      description = "Address and port for the OpenFang listener.";
    };

    configFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path to the OpenFang config.toml (evaluated at runtime).";
    };

    mcpServers = {
      kubernetes = {
        # Default true — mkEnableOption defaults to false so we use mkOption
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to install the Kubernetes MCP server.";
        };
      };

      grafana = {
        # Default true — mkEnableOption defaults to false so we use mkOption
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to install the Grafana MCP server.";
        };
      };

      flux = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to install the Flux Operator MCP server (optional).";
        };
      };
    };

    installCli = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to install the openfang-ctl CLI tool.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = cfg.configFile != null;
      message = "homelab.openfang.configFile must be set when openfang is enabled";
    }];

    networking.firewall.allowedTCPPorts = [ 4200 ];

    # Make binaries available system-wide
    environment.systemPackages = [ openfang ]
      ++ mcpPackages
      ++ optional cfg.installCli pkgs.openfang-ctl;

    # ── Systemd service ─────────────────────────────────────────────
    systemd.services.openfang = {
      description = "OpenFang agent runtime";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        OPENFANG_LISTEN = cfg.listenAddress;
        OPENFANG_HOME = "/var/lib/openfang";
        HOME = "/var/lib/openfang";  # Override HOME to prevent /home/lukas access
        PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      };

      # Shell tools needed for shell_exec (bash provides sh) + homelab agent tools
      path = mcpPackages ++ (with pkgs; [
        bash        # shell_exec uses sh -c; must be in PATH
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
        nix         # nix develop for project-specific tool envs
        python3     # coding tasks and scripting
        playwright-driver.browsers  # browser automation via Playwright
      ]);

      serviceConfig = {
        Type = "simple";
        User = username;
        Group = "users";
        WorkingDirectory = "/var/lib/openfang";
        EnvironmentFile = "/var/lib/openfang/.env";
        # CLI format: openfang start --config <path>
        ExecStart = "${openfang}/bin/openfang start --config ${cfg.configFile}";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = "openfang";
        StateDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        ReadWritePaths = [ "/var/lib/openfang" "/tmp" ];
        DynamicUser = false;  # explicit: needs shell access as user
      };
    };
  };
}
