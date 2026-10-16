# Port-scoping rules for the NixOS firewall, emitted for BOTH backends.
#
# Which option is read depends on the backend — `extraInputRules` for nftables,
# `extraCommands` for iptables (nftables asserts that one is empty, hence the
# guard). Writing only one is silently INERT on the other: an nftables-only SSH
# rule once left port 22 open to anything routable, with no warning. Scoped
# ports also stay out of `allowedTCPPorts`, which accepts from any source.
#
# UDP ports use the parallel `udpPorts`/`udpSources`/`udpInterfaces` (defaulting
# to the TCP sets); either proto's port list may be empty, emitting no rule.
lib:
let
  inherit (lib) concatMapStrings concatStringsSep head length optional optionals optionalString;

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
      ports ? [ ],
      sources,
      interfaces,
      backend,
      dropOthers ? false,
      udpPorts ? [ ],
      udpSources ? sources,
      udpInterfaces ? interfaces,
    }:
    assert backend == "iptables" || backend == "nftables";
    let
      # nftSet [] is an empty `{ }` nft rejects, so gate each proto on non-empty ports.
      nftProto =
        proto: pports: psources: pifaces:
        optionals (pports != [ ]) (
          let
            pset = nftSet (map toString pports);
          in
          map (iface: ''iifname "${iface}" ${proto} dport ${pset} accept'') pifaces
          ++ [ "ip saddr ${nftSet psources} ${proto} dport ${pset} accept" ]
          ++ optional dropOthers "${proto} dport ${pset} drop"
        );

      iptProto =
        proto: pports: psources: pifaces:
        concatMapStrings (
          port:
          concatMapStrings (
            iface: "ip46tables -w -A nixos-fw -i ${iface} -p ${proto} --dport ${toString port} -j nixos-fw-accept\n"
          ) pifaces
          + concatMapStrings (
            src: "iptables -w -A nixos-fw -s ${src} -p ${proto} --dport ${toString port} -j nixos-fw-accept\n"
          ) psources
        ) pports;
    in
    {
      extraInputRules =
        concatStringsSep "\n" (
          [ "# ${nftComment}" ]
          ++ nftProto "tcp" ports sources interfaces
          ++ nftProto "udp" udpPorts udpSources udpInterfaces
        )
        + "\n";

      extraCommands = optionalString (backend == "iptables") (
        iptProto "tcp" ports sources interfaces + iptProto "udp" udpPorts udpSources udpInterfaces
      );
    };
}
