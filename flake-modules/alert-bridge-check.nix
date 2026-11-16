# lenovo's alert-bridge admits only the host that runs Alertmanager: any other source could page homelab-alerts.
# Reads every rule the live firewall backend renders for the bridge port (the unit's IP filter, which also holds on
# interfaces the firewall trusts, is the module's assertion); evaluates lenovo and black-pi only.
{ config, lib, ... }:
let
  bridge = config.flake.nixosConfigurations.lenovo.config;
  alerting = config.flake.nixosConfigurations.black-pi.config;
  port = toString bridge.homelab.alertBridge.port;
  fw = bridge.networking.firewall;
  want = [ alerting.sam.fleet.hosts.black-pi.address ];
  lines = text: lib.splitString "\n" text;
  # every rule line that names the port, against the one shape mkDualBackendFirewall renders per admitted source
  rendered =
    if fw.backend == "iptables" then
      lib.filter (lib.hasInfix "--dport ${port} ") (lines fw.extraCommands)
    else
      lib.filter (l: builtins.match ".*dport [{ ]*([0-9]+, )*${port}[,} ].*" (l + " ") != null) (
        lines fw.extraInputRules
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
