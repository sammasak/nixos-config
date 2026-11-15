# llm-gateway as a host service. Pods reach 8081 and 9091 on the trusted Cilium interfaces, and cluster policies
# admit only Traefik and Prometheus there; from the LAN only lenovo reaches 8081. Any process on acer, and a
# hostNetwork pod, still reaches 9091 and the keyless 11435 over loopback. llm-gateway.toml is the one deployed
# config: a model or provider change lands there. Without state.sqlite3 the unit is skipped, not failed, and a
# database restored after the switch needs `systemd-tmpfiles --create` (the Z rule below), then
# `systemctl start llm-gateway`.
# FIXME: no sops.secrets yet: sops-nix fails evaluation on a missing file, and the six keys' file is the owner's
# (homelab-gitops #265); until it lands the gateway would stop at its first key read.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/firewall.nix lib) anySourceTcp ciliumInterfaces mkDualBackendFirewall;
  fw = config.networking.firewall;
  api = 8081;
  admin = 9091;
  state = "/var/lib/llm-gateway";
  configFile = pkgs.writeText "llm-gateway.toml" (builtins.readFile ./llm-gateway.toml);
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

  networking.firewall = {
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
  };

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
      assertion = lib.all (i: lib.elem i ciliumInterfaces) fw.trustedInterfaces;
      message = "modules/homelab/llm-gateway.nix: a trusted interface bypasses the firewall and reaches the gateway's listeners; trust only loopback and Cilium's, not ${toString (lib.subtractLists ciliumInterfaces fw.trustedInterfaces)}.";
    }
  ];
}
