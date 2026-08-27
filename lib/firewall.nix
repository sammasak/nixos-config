# Port-scoping rules for the NixOS firewall, emitted for BOTH backends.
#
# Which rule option is read depends on the backend: `extraInputRules` for
# nftables, `extraCommands` for iptables (nftables asserts that one is empty,
# hence the guard). Writing only one is silently INERT on the other backend —
# an nftables-only SSH rule once left port 22 open to anything routable, with
# no warning. Emitting both makes a backend switch a non-event.
#
# Scoped ports deliberately do NOT go in `allowedTCPPorts`, which accepts from
# any source; anything unmatched falls through to the default drop.
lib:
let
  inherit (lib) concatMapStrings concatStringsSep head length optional optionalString;

  # nftables takes a single value bare and several in a braced set.
  nftSet = xs: if length xs == 1 then head xs else "{ ${concatStringsSep ", " xs} }";
in
{
  # `comment` heads the nftables block so a rendered ruleset says which module
  # emitted it. `dropOthers` adds an explicit nftables drop, which only matters
  # for a port some other rule would otherwise accept from anywhere.
  mkDualBackendFirewall =
    {
      comment,
      ports,
      sources,
      interfaces,
      backend,
      dropOthers ? false,
    }:
    let
      portSet = nftSet (map toString ports);
    in
    {
      extraInputRules =
        concatStringsSep "\n" (
          [ "# ${comment}" ]
          ++ map (iface: ''iifname "${iface}" tcp dport ${portSet} accept'') interfaces
          ++ [ "ip saddr ${nftSet sources} tcp dport ${portSet} accept" ]
          ++ optional dropOthers "tcp dport ${portSet} drop"
        )
        + "\n";

      extraCommands = optionalString (backend == "iptables") (
        concatMapStrings (
          port:
          concatMapStrings (
            iface: "ip46tables -w -A nixos-fw -i ${iface} -p tcp --dport ${toString port} -j nixos-fw-accept\n"
          ) interfaces
          + concatMapStrings (
            src: "iptables -w -A nixos-fw -s ${src} -p tcp --dport ${toString port} -j nixos-fw-accept\n"
          ) sources
        ) ports
      );
    };
}
