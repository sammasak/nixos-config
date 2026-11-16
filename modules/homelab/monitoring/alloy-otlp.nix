# alloy-otlp on acer: the OTLP intake behind otlp.sammasak.dev (Caddy reaches 4318 over loopback, edge.nix),
# sanitizing the harness telemetry and sending metrics to black-pi's Prometheus through a durable queue and logs to
# its Loki. On acer, not black-pi, so the queue sits on the far side of a black-pi outage. One
# process by construction: the session sum (homelab-gitops#226) is per process. On nixpkgs' Alloy 1.17.1, which leaves
# exemplars in place (./alloy-otlp.alloy); they stop at the queue, as Prometheus stores none.
# scripts/test-alloy-otlp-*.{sh,py} run this unit's ExecStart, as evaluated, against the deployed config.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  fw = config.networking.firewall;
  alloy = pkgs.grafana-alloy;
  otlpPort = 4318;
  httpPort = 12346;
  blackPi = hosts.black-pi.address;
  configFile = pkgs.writeText "alloy-otlp.alloy" (
    lib.replaceStrings [ "@prometheus@" "@loki@" ] [ "http://${blackPi}:9090" "http://${blackPi}:3100" ]
      (builtins.readFile ./alloy-otlp.alloy)
  );
  stability = "--stability.level=experimental";
  # the config reads the token from the environment, as the pod did; $(<) drops the newline, as the relay's cat does
  withToken = pkgs.writeShellScript "alloy-otlp-token" ''
    OTLP_BEARER_TOKEN="$(<"$CREDENTIALS_DIRECTORY/token")"
    export OTLP_BEARER_TOKEN
    exec "$@"
  '';
  args = [
    withToken
    "${alloy}/bin/alloy"
    "run"
    stability
    "--disable-reporting"
    "--server.http.listen-addr=0.0.0.0:${toString httpPort}"
    "--storage.path=/var/lib/alloy-otlp"
    configFile
  ];
in
{
  system.checks = [
    (pkgs.runCommand "alloy-otlp-config-check" { nativeBuildInputs = [ alloy ]; } ''
      alloy validate ${stability} ${configFile}
      touch $out
    '')
  ];

  systemd.services.alloy-otlp = {
    description = "OTLP intake: sanitized harness telemetry to black-pi's Prometheus and Loki";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "sops-nix.service"
    ];
    environment.GOMEMLIMIT = "200MiB";
    serviceConfig = {
      ExecStart = utils.escapeSystemdExecArgs args;
      ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 30 --retry-delay 2 --retry-connrefused --retry-max-time 60 http://127.0.0.1:${toString httpPort}/-/ready";
      TimeoutStartSec = 90;
      Restart = "always";
      RestartSec = 10;
      # the same directory as the pod's hostPath; systemd moves it under /var/lib/private for the dynamic user
      DynamicUser = true;
      StateDirectory = "alloy-otlp";
      StateDirectoryMode = "0700";
      LoadCredential = [ "token:${config.sops.secrets.native_otlp_auth.path}" ];
      # the pod's limit; memory_limiter in the config holds 128MiB
      MemoryMax = "256M";
      MemorySwapMax = 0;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  # black-pi's Prometheus scrapes the collector's own metrics; 4318 has no rule, so only loopback (Caddy) reaches it
  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "alloy-otlp's metrics answer black-pi's Prometheus.";
        ports = [ httpPort ];
        sources = [ blackPi ];
        interfaces = [ ];
        inherit (fw) backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  assertions = [
    {
      # declared by native-otel-relay.nix from the file acer is a recipient of; this unit adds no recipient
      assertion = config.sops.secrets ? native_otlp_auth;
      message = "modules/homelab/monitoring/alloy-otlp.nix: the bearer token is the relay's native_otlp_auth; set sam.profile.nativeOtel.";
    }
    {
      assertion =
        fw.enable
        &&
          anySourceTcp fw [
            otlpPort
            httpPort
          ] == [ ]
        && lib.all (i: i == "lo") fw.trustedInterfaces;
      message = "modules/homelab/monitoring/alloy-otlp.nix: keep the firewall on, ports ${toString otlpPort} and ${toString httpPort} out of allowedTCPPorts, and trust only loopback: no LAN host may reach the intake.";
    }
  ];
}
