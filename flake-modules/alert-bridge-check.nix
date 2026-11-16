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
  # does a port list ("9099", "9000:9100", "80,9099", "{ 22, 9000-9100 }") cover the bridge port
  covers =
    ports:
    lib.any
      (
        item:
        let
          r = builtins.match "([0-9]+)[-:]([0-9]+)" item;
        in
        if r == null then
          item == port
        else
          lib.toInt (lib.head r) <= lib.toInt port && lib.toInt port <= lib.toInt (lib.last r)
      )
      (
        lib.filter (i: i != "") (
          lib.splitString "," (lib.replaceStrings [ " " "{" "}" ] [ "" "" "" ] ports)
        )
      );
  portsOf =
    l:
    let
      m = builtins.match (
        if fw.backend == "iptables" then ".*--dports? ([0-9:,]+).*" else ".*dport ([{][^}]*[}]|[0-9-]+).*"
      ) l;
    in
    if m == null then null else lib.head m;
  # every rule line whose ports cover the bridge port (single, list or range), against the one shape
  # mkDualBackendFirewall renders per admitted source
  rendered = lib.filter (l: portsOf l != null && covers (portsOf l)) (
    lines (if fw.backend == "iptables" then fw.extraCommands else fw.extraInputRules)
  );
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
            (bridge.homelab.alertBridge.openFirewall && alerting.services.prometheus.alertmanager.enable)
            "alert-bridge-check: lenovo no longer admits the bridge, or black-pi no longer runs Alertmanager; update this check";
          assert lib.assertMsg (rendered == expected)
            "alert-bridge-check: lenovo's ${fw.backend} rules for port ${port} are ${builtins.toJSON rendered}; only ${builtins.toJSON expected} may admit it";
          pkgs.writeText "alert-bridge-sources" (builtins.toJSON want);
      };
    };
}
