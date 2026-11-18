# lenovo's alert-bridge admits only the host that runs Alertmanager: any other source could page homelab-alerts.
# Reads every rule the live firewall backend renders for the bridge port (the unit's IP filter, which also holds on
# interfaces the firewall trusts, is the module's assertion); evaluates lenovo and black-pi only.
{ config, lib, ... }:
let
  bridge = config.flake.nixosConfigurations.lenovo.config;
  alerting = config.flake.nixosConfigurations.black-pi.config;
  port = toString bridge.homelab.alertBridge.port;
  fw = bridge.networking.firewall;
  want = [
    alerting.sam.fleet.hosts.black-pi.address
  ]
  ++ alerting.sam.fleet.hosts.black-pi.extraAddresses;
  lines = text: lib.splitString "\n" text;
  inherit (import ../lib/firewall.nix lib) admitsPort;
  admits = backend: admitsPort backend port;
  # every rule line that admits the bridge port, against the one shape mkDualBackendFirewall renders per admitted source
  rendered = lib.filter (admits fw.backend) (
    lines (if fw.backend == "iptables" then fw.extraCommands else fw.extraInputRules)
  );
  # rules the matcher must catch, whichever backend lenovo runs
  seeds = {
    iptables = [
      "iptables -w -A nixos-fw -p tcp -m multiport --dports 80,9099 -j nixos-fw-accept"
      "iptables -w -A nixos-fw -p tcp --dport 9000:9100 -j nixos-fw-accept"
      "iptables -w -A nixos-fw -p tcp ! --dport 22 -j nixos-fw-accept"
      "iptables -w -A nixos-fw -p tcp --destination-port 9099 -j nixos-fw-accept"
      "iptables -w -A nixos-fw -p tcp -m multiport --ports 9099 -j nixos-fw-accept"
    ];
    nftables = [
      "tcp dport { 22, 9000-9100 } accept"
      "tcp dport @ports accept"
      "tcp dport != 22 accept"
    ];
  };
  missed = lib.concatLists (lib.mapAttrsToList (backend: lib.filter (l: !admits backend l)) seeds);
  expected =
    if fw.backend == "iptables" then
      map (src: "iptables -w -A nixos-fw -s ${src} -p tcp --dport ${port} -j nixos-fw-accept") want
    else
      [
        "ip saddr ${
          if lib.length want == 1 then lib.head want else "{ ${lib.concatStringsSep ", " want} }"
        } tcp dport ${port} accept"
      ];
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        alert-bridge-sources =
          assert lib.assertMsg
            (
              bridge.sam.fleet.listeners.alert-bridge.host == bridge.networking.hostName
              && alerting.services.prometheus.alertmanager.enable
            )
            "alert-bridge-check: lenovo no longer admits the bridge, or black-pi no longer runs Alertmanager; update this check";
          assert lib.assertMsg (
            missed == [ ]
          ) "alert-bridge-check: the matcher misses rules that admit port ${port}: ${builtins.toJSON missed}";
          assert lib.assertMsg (rendered == expected)
            "alert-bridge-check: lenovo's ${fw.backend} rules for port ${port} are ${builtins.toJSON rendered}; only ${builtins.toJSON expected} may admit it";
          pkgs.writeText "alert-bridge-sources" (builtins.toJSON want);
      };
    };
}
