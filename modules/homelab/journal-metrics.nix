{
  config,
  lib,
  pkgs,
  ...
}:
let
  directory = "/run/journal-metrics";
  helper = pkgs.writeShellApplication {
    name = "journal-metrics";
    runtimeInputs = [
      pkgs.curl
      pkgs.gawk
      pkgs.coreutils
    ];
    text = builtins.readFile ../../scripts/journal-metrics.sh;
  };
in
{
  config = lib.mkIf config.homelab.journalCollector.enable {
    users.users.journal-metrics = {
      isSystemUser = true;
      group = "journal-metrics";
    };
    users.groups.journal-metrics = { };
    services.prometheus.exporters.node.extraFlags = [
      "--collector.textfile.directory=${directory}"
    ];
    systemd.services.journal-metrics = {
      description = "Collect bounded local journal delivery counters";
      after = [ "alloy.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe helper} ${directory} http://127.0.0.1:12345/metrics";
        # A preserved DynamicUser runtime directory lives under /run/private, which node-exporter cannot traverse.
        DynamicUser = false;
        User = "journal-metrics";
        Group = "journal-metrics";
        RuntimeDirectory = "journal-metrics";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = "yes";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        MemoryMax = "16M";
        MemorySwapMax = 0;
        TimeoutStartSec = 15;
      };
    };
    systemd.timers.journal-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
        RandomizedDelaySec = "10s";
        AccuracySec = "5s";
      };
    };
    assertions = [
      {
        assertion = config.services.prometheus.exporters.node.enable;
        message = "journal-metrics requires the existing node-exporter textfile collector.";
      }
    ];
  };
}
