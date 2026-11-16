{
  config,
  pkgs,
  lib,
  ...
}:
let
  profile = config.sam.profile;
  hasDesktop = config.sam.desktop.enable;
  fw = config.networking.firewall;
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall anySourceTcp;
  openSsh = anySourceTcp config.networking.firewall config.services.openssh.ports;

  sshRules = mkDualBackendFirewall {
    nftComment = "Allow SSH only from LAN subnet and loopback (nftables backend).";
    ports = config.services.openssh.ports;
    sources = [ config.sam.fleet.lanCidr ];
    interfaces = [ "lo" ];
    # nftables path only, and inert on the iptables backend running today,
    # where nixos-fw's default refuse already covers it.
    dropOthers = true;
    backend = config.networking.firewall.backend;
  };

  # Fails evaluation when nixpkgs stops wiring a script this way, so the check below cannot go empty
  firewallScripts =
    lib.mapAttrsToList
      (
        unit: name:
        let
          exec = config.systemd.services.firewall.serviceConfig.${unit} or "";
        in
        if builtins.match "@/nix/store/[^ ]+/bin/${name} ${name}" exec == null then
          throw "modules/core/network.nix: systemd.services.firewall.serviceConfig.${unit} is not \"@<store path>/bin/${name} ${name}\" but \"${exec}\"; update the firewall script syntax check."
        else
          lib.head (lib.splitString " " (lib.removePrefix "@" exec))
      )
      {
        ExecStart = "firewall-start";
        ExecReload = "firewall-reload";
        ExecStop = "firewall-stop";
      };
in
{
  networking = {
    hostName = profile.hostname;
    networkmanager.enable = true;

    # Baseline firewall for EVERY host: SSH only. Each service opens its own
    # ports (edge.nix, adguardhome.nix), so a laptop running none is SSH-only.
    #
    # Break-glass if a rule here is ever wrong: the console.
    firewall = {
      enable = true;
      inherit (sshRules) extraInputRules extraCommands;
    };
  };

  services.openssh.openFirewall = false;

  # A shell error in extraCommands otherwise surfaces at activation (at boot on the Pis), and nftables.checkRuleset
  # is inert on the iptables backend
  system.checks = lib.optional (fw.enable && fw.backend == "iptables") (
    pkgs.runCommand "firewall-scripts-syntax-check" { } ''
      ${lib.concatMapStrings (script: "${pkgs.bash}/bin/bash -n ${script}\n") firewallScripts}
      touch $out
    ''
  );

  assertions = [
    {
      assertion = !config.services.openssh.openFirewall && openSsh == [ ];
      message = "modules/core/network.nix: SSH reaches the LAN only through the scoped rule there; keep services.openssh.openFirewall = false and sshd port(s) ${toString openSsh} out of networking.firewall allowedTCPPorts and allowedTCPPortRanges, global and per interface, which accept from any source.";
    }
  ];

  environment.systemPackages = lib.optionals hasDesktop [ pkgs.networkmanagerapplet ];
}
