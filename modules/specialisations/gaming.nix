# Boot entry for game streaming: the desktop session with Sunshine for Moonlight clients, and no inference on the GPU.
{ config, lib, ... }:
let
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
  inherit (config.sam.fleet) lanCidr public;
  host = config.networking.hostName;
  # this host's LAN-scoped public entries (modules/core/fleet.nix), rendered as network.nix expects them
  stream = lib.filter (p: p.host == host && p.lan && p.port != null) public;
  # https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#port
  # The web UI (base + 1) is left out: it sets the password and pairs clients, reach it through an SSH tunnel.
  base = config.services.sunshine.settings.port;
  offsets =
    proto:
    map (o: {
      inherit proto;
      port = base + o;
    });
  expected =
    offsets "tcp" [
      (-5)
      0
      21
    ]
    ++ offsets "udp" [
      9
      10
      11
      13
      21
    ];
  listed = map (p: { inherit (p) proto port; }) stream;
in
{
  imports = [ ./desktop.nix ];

  services.sunshine = {
    enable = true;
    # KMS capture: niri offers no wlroots screencopy
    capSysAdmin = true;
  };
  # mDNS would open 5353/udp to any source; Moonlight takes the host's address instead
  services.avahi.enable = false;

  # No screen, keyboard or greeter to log in at: the session Sunshine captures has to start by itself.
  services.displayManager.autoLogin = {
    enable = true;
    user = config.sam.profile.username;
  };

  # mkForce: games get the whole card. The units stay startable by hand, and the default boot runs them as before.
  systemd.services = lib.genAttrs [ "ollama" "ollama-model-loader" "nvidia-power-limit" ] (_: {
    wantedBy = lib.mkForce [ ];
  });

  networking.firewall = lib.mkMerge (
    map (
      p:
      lib.getAttrs [ "extraInputRules" "extraCommands" ] (mkDualBackendFirewall {
        nftComment = "public ${toString p.port}";
        sources = [ lanCidr ];
        ports = [ p.port ];
        inherit (p) proto;
        interfaces = [ ];
        inherit (config.networking.firewall) backend;
      })
    ) stream
  );

  assertions = [
    {
      assertion = lib.all (e: lib.elem e listed) expected && lib.all (l: lib.elem l expected) listed;
      message = "modules/specialisations/gaming.nix: ${host}'s lan public entries in modules/core/fleet.nix (${builtins.toJSON listed}) are not Sunshine's stream ports for base port ${toString base} (${builtins.toJSON expected}).";
    }
  ];
}
