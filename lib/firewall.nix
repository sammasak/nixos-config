# Port-scoping rules for the NixOS firewall, emitted for BOTH backends.
#
# Which option is read depends on the backend — `extraInputRules` for nftables,
# `extraCommands` for iptables (nftables asserts that one is empty, hence the
# guard). Writing only one is silently INERT on the other: an nftables-only SSH
# rule once left port 22 open to anything routable, with no warning.
#
# Scoped ports deliberately do NOT go in `allowedTCPPorts`, which accepts from
# any source.
lib:
let
  inherit (lib) concatMapStrings concatStringsSep head length optional optionalString;

  # nftables accepts `{ 22 }` too; the bare form exists only to match the
  # hand-written rules this replaced byte for byte. Drop it when that stops mattering.
  nftSet = xs: if length xs == 1 then head xs else "{ ${concatStringsSep ", " xs} }";
in
{
  # `nftComment` and `dropOthers` land in the nftables output only, hence the name.
  # The assert is the point of the file. `networking.firewall.backend` is
  # `enum [ "iptables" "nftables" "firewalld" ]`; under firewalld neither output
  # is read at all and the scoping would vanish silently.
  mkDualBackendFirewall =
    {
      nftComment,
      ports,
      sources,
      interfaces,
      backend,
      dropOthers ? false,
    }:
    assert backend == "iptables" || backend == "nftables";
    let
      portSet = nftSet (map toString ports);
    in
    {
      extraInputRules =
        concatStringsSep "\n" (
          [ "# ${nftComment}" ]
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
