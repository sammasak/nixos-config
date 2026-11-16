# llm-gateway as a host service. From the LAN lenovo reaches 8081 and black-pi's Prometheus 9091; Caddy reaches 8081
# over loopback. Any process on acer still reaches 9091 and the keyless 11435 over loopback. llm-gateway.toml is the
# one deployed config: a model or provider change lands there. Without state.sqlite3 the unit is skipped, not failed, and a
# database restored after the switch needs `systemd-tmpfiles --create` (the Z rule below), then
# `systemctl start llm-gateway`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  fw = config.networking.firewall;
  api = 8081;
  admin = 9091;
  state = "/var/lib/llm-gateway";
  configText = builtins.readFile ./llm-gateway.toml;
  configFile = pkgs.writeText "llm-gateway.toml" configText;
  # every key file the config names, so a provider added there needs its key in the sops file to build: the gateway
  # reads each one at startup, enabled or not
  keyFiles = lib.unique (
    lib.concatLists (
      builtins.filter builtins.isList (
        builtins.split "/run/secrets/(llm-gateway/[^\"[:space:]]+)" configText
      )
    )
  );
  backup = pkgs.writers.writePython3Bin "llm-gateway-backup" { doCheck = false; } (
    builtins.readFile ./llm-gateway-backup.py
  );
in
{
  # a static user: the sops secrets need an owner at activation, before the unit runs
  users.users.llm-gateway = {
    isSystemUser = true;
    group = "llm-gateway";
  };
  users.groups.llm-gateway = { };
  sops.secrets = lib.genAttrs keyFiles (_: {
    sopsFile = ../../secrets/homelab/llm-gateway.yaml;
    owner = "llm-gateway";
    group = "llm-gateway";
    mode = "0400";
    restartUnits = [ "llm-gateway.service" ];
  });

  # Z: a migrated database keeps the pod's uid (65532) or root's, and the gateway then cannot write it
  systemd.tmpfiles.rules = [
    "d ${state} 0700 llm-gateway llm-gateway -"
    "Z ${state} - llm-gateway llm-gateway -"
  ];

  systemd.services.llm-gateway = {
    description = "llm-gateway: OpenAI-compatible routing to models that cannot bill by usage";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${state}/state.sqlite3";
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.llmGateway} ${configFile}";
      User = "llm-gateway";
      Group = "llm-gateway";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 60;
      ReadWritePaths = [ state ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      # an idle start peaks at 3.3 MB; OOMScoreAdjust below Ollama's 1000, since every caller goes through it
      MemoryMax = "256M";
      MemorySwapMax = 0;
      OOMScoreAdjust = -100;
    };
  };

  systemd.services.llm-gateway-backup = {
    description = "Back up llm-gateway's state database, with a restore check";
    unitConfig.ConditionPathExists = "${state}/state.sqlite3";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe backup} backup ${state}/state.sqlite3 /var/lib/llm-gateway-backup";
      User = "llm-gateway";
      Group = "llm-gateway";
      StateDirectory = "llm-gateway-backup";
      StateDirectoryMode = "0700";
      PrivateNetwork = true;
      ProtectSystem = "strict";
      # writable on purpose: SQLite cannot open a WAL database read-only once the gateway has shut down cleanly
      ReadWritePaths = [ state ];
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
  systemd.timers.llm-gateway-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:20:00";
      Persistent = true;
    };
  };
  environment.systemPackages = [ backup ];

  networking.firewall = lib.mkMerge [
    {
      inherit
        (mkDualBackendFirewall {
          nftComment = "llm-gateway answers lenovo's host on the LAN.";
          ports = [ api ];
          sources = [ config.sam.fleet.hosts.lenovo-21CB001PMX.address ];
          interfaces = [ ];
          inherit (fw) backend;
        })
        extraInputRules
        extraCommands
        ;
    }
    {
      inherit
        (mkDualBackendFirewall {
          nftComment = "llm-gateway's admin port answers black-pi's Prometheus.";
          ports = [ admin ];
          sources = [ config.sam.fleet.hosts.black-pi.address ];
          interfaces = [ ];
          inherit (fw) backend;
        })
        extraInputRules
        extraCommands
        ;
    }
  ];

  assertions = [
    {
      assertion =
        fw.enable
        &&
          anySourceTcp fw [
            api
            admin
          ] == [ ];
      message = "modules/homelab/llm-gateway.nix: keep the firewall on and ports ${toString api} and ${toString admin} out of allowedTCPPorts and allowedTCPPortRanges, global and per interface; admit a caller with a source-scoped rule.";
    }
    {
      assertion = lib.all (i: i == "lo") fw.trustedInterfaces;
      message = "modules/homelab/llm-gateway.nix: a trusted interface bypasses the firewall and reaches the gateway's listeners; trust only loopback, not ${toString (lib.remove "lo" fw.trustedInterfaces)}.";
    }
  ];
}
