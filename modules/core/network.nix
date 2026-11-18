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
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall admitting;
  inherit (config.sam.fleet) hosts listeners public;
  host = config.networking.hostName;
  rules =
    nftComment: sources: ports: proto:
    mkDualBackendFirewall {
      inherit
        nftComment
        sources
        ports
        proto
        ;
      interfaces = [ ];
      inherit (fw) backend;
    };

  # every listener this host serves, admitting exactly the addresses of its `from` (modules/core/fleet.nix)
  served = lib.mapAttrsToList (
    name: l:
    rules "${name}: ${toString l.from}"
      (lib.concatMap (h: [ hosts.${h}.address ] ++ hosts.${h}.extraAddresses) l.from)
      [
        l.port
      ]
      l.proto
  ) (lib.filterAttrs (_: l: l.host == host) listeners);
  mayOpen = lib.filter (p: p.host == null || p.host == host) public;

  # The one check of the rendered firewall: what it opens, trusts or accepts is a listener's rule or a public entry,
  # so an upstream openFirewall, a stray allowedTCPPorts or a hand-written rule on any module fails the build.
  text = lib.splitString "\n" (
    lib.replaceStrings [ "\\\n" ] [ " " ] (
      if fw.backend == "iptables" then fw.extraCommands else fw.extraInputRules
    )
  );
  derived =
    lib.concatMap (r: map lib.trim (lib.splitString "\n" (r.extraCommands + r.extraInputRules)))
      (
        served
        ++ map (p: rules "public ${toString p.port}" [ config.sam.fleet.lanCidr ] [ p.port ] p.proto) (
          lib.filter (p: p.lan && p.port != null) mayOpen
        )
      );
  # loopback is accepted by nixos-fw before any of these
  loopback = l: lib.hasInfix " -i lo " l || lib.hasPrefix ''iifname "lo" '' (lib.trim l);
  strayLines = lib.filter (
    l: admitting fw.backend l && !lib.elem (lib.trim l) derived && !loopback l
  ) text;
  public' =
    proto: iface: port:
    lib.any (
      p: !p.lan && p.port == port && p.proto == proto && (p.interface == null || p.interface == iface)
    ) mayOpen;
  openings = lib.concatLists (
    lib.mapAttrsToList
      (
        iface: s:
        lib.concatMap
          (
            proto:
            let
              P = lib.toUpper proto;
            in
            map (port: { inherit iface proto port; }) s."allowed${P}Ports"
            ++ map (r: {
              inherit iface proto;
              port = if r.from == r.to then r.from else "${toString r.from}-${toString r.to}";
            }) s."allowed${P}PortRanges"
          )
          [
            "tcp"
            "udp"
          ]
      )
      (
        {
          "" = fw;
        }
        // fw.interfaces
      )
  );
  strayPorts = lib.filter (
    o: !public' o.proto (if o.iface == "" then null else o.iface) o.port
  ) openings;
  strayTrusted = lib.filter (
    i: i != "lo" && !lib.any (p: p.port == null && p.interface == i) mayOpen
  ) fw.trustedInterfaces;
  shapeless = lib.filter (p: p.port == null && (p.interface == null || p.lan)) public;

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

    # Baseline firewall for EVERY host: SSH, then the sam.fleet listeners it serves. A port open to any source is a
    # public entry there (edge.nix, adguardhome.nix open theirs), so a laptop running none is SSH-only.
    #
    # Break-glass if a rule here is ever wrong: the console.
    firewall = lib.mkMerge (
      [ { enable = true; } ]
      ++ map (r: { inherit (r) extraInputRules extraCommands; }) ([ sshRules ] ++ served)
    );
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
      assertion = served != [ ] -> fw.enable;
      message = "modules/core/network.nix: ${host} serves sam.fleet listeners, which have no authentication of their own; keep networking.firewall.enable.";
    }
    {
      assertion = shapeless == [ ];
      message = "modules/core/fleet.nix: a public entry without a port names a trusted interface, and is not lan: ${builtins.toJSON shapeless}.";
    }
    {
      assertion = !fw.enable || strayPorts == [ ] && strayTrusted == [ ] && strayLines == [ ];
      message = "modules/core/network.nix: ${host}'s firewall opens what sam.fleet does not list (modules/core/fleet.nix): ports to any source ${builtins.toJSON strayPorts}, trusted interfaces ${builtins.toJSON strayTrusted}, accept rules ${builtins.toJSON strayLines}. Add a listener with its callers in `from`, or a public entry with its reason; an upstream openFirewall admits any source.";
    }
  ];

  environment.systemPackages = lib.optionals hasDesktop [ pkgs.networkmanagerapplet ];
}
