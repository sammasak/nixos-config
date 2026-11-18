# Port-scoping rules for the NixOS firewall, emitted for BOTH backends.
#
# Which option is read depends on the backend — `extraInputRules` for nftables,
# `extraCommands` for iptables (nftables asserts that one is empty, hence the
# guard). Writing only one is silently INERT on the other: an nftables-only SSH
# rule once left port 22 open to anything routable, with no warning. Scoped
# ports also stay out of `allowedTCPPorts`, which accepts from any source.
lib:
let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    head
    length
    optional
    optionalString
    ;

  # nftables accepts `{ 22 }` too; the bare form exists only to match the
  # hand-written rules this replaced byte for byte. Drop it when that stops mattering.
  nftSet = xs: if length xs == 1 then head xs else "{ ${concatStringsSep ", " xs} }";
in
{
  # Does a rendered rule line admit `port` (a string)? Reads iptables `--dport`/`--dports`/multiport/ranges and
  # nftables sets; fails closed: a port rule it cannot read (a named set, a negation) counts as admitting it.
  admitsPort =
    backend: port: l:
    let
      m = builtins.match (
        if backend == "iptables" then ".*--dports? ([0-9:,]+).*" else ".*dport ([{][^}]*[}]|[0-9-]+).*"
      ) l;
      covers = lib.any (
        item:
        let
          r = builtins.match "([0-9]+)[-:]([0-9]+)" item;
        in
        if r == null then
          item == port
        else
          lib.toInt (lib.head r) <= lib.toInt port && lib.toInt port <= lib.toInt (lib.last r)
      );
    in
    lib.any (w: lib.hasInfix w l) [
      "dport"
      "destination-port"
      "multiport"
    ]
    && (
      m == null
      || lib.hasInfix "!" l
      || covers (
        lib.filter (i: i != "") (
          lib.splitString "," (lib.replaceStrings [ " " "{" "}" ] [ "" "" "" ] (lib.head m))
        )
      )
    );

  # Does a rendered rule line (backslash continuations joined) let traffic in to this host, on any port: an accept
  # target, a variable target (unreadable, so fails closed), or a RETURN out of nixos-fw or INPUT, whose policy
  # accepts. Forwarding (networking.nat's nixos-filter-forward, the workers' dev-env-forward) and the nat, mangle
  # and raw tables reach no listener here, so they are not read.
  admitting =
    backend: l:
    if backend == "iptables" then
      builtins.match ".*(-[AI] +(FORWARD|nixos-filter-forward|dev-env-forward)|-t +(nat|mangle|raw))( .*|$)" l
      == null
      && (
        builtins.match ".*(-j|-g|--jump|--goto) +(nixos-fw-accept|ACCEPT|[\"$]).*" l != null
        || (
          builtins.match ".*-[AI] +(nixos-fw|INPUT) .*" l != null
          && builtins.match ".*(-j|--jump) +RETURN.*" l != null
        )
      )
    else
      builtins.match "[[:space:]]*#.*" l == null
      && builtins.match "(.*[[:space:];])?accept([[:space:];].*)?" l != null;

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
      proto ? "tcp",
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
          ++ map (iface: ''iifname "${iface}" ${proto} dport ${portSet} accept'') interfaces
          ++ [ "ip saddr ${nftSet sources} ${proto} dport ${portSet} accept" ]
          ++ optional dropOthers "${proto} dport ${portSet} drop"
        )
        + "\n";

      extraCommands = optionalString (backend == "iptables") (
        concatMapStrings (
          port:
          concatMapStrings (
            iface:
            "ip46tables -w -A nixos-fw -i ${iface} -p ${proto} --dport ${toString port} -j nixos-fw-accept\n"
          ) interfaces
          + concatMapStrings (
            src: "iptables -w -A nixos-fw -s ${src} -p ${proto} --dport ${toString port} -j nixos-fw-accept\n"
          ) sources
        ) ports
      );
    };
}
