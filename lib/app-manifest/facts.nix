# What admission knows of the fleet: sam.fleet as modules/core/fleet.nix states it, plus what only a host evaluation
# knows (the names the edge serves, the snippets it defines, each host's sops secret names), handed in as data so
# admission stays lib-only.
lib:
{
  fleet,
  edgeNames,
  forwardAuth,
  secrets,
}:
let
  hosts = lib.attrNames fleet.hosts;
  taken =
    h:
    lib.mapAttrsToList (n: l: {
      inherit (l) port proto;
      by = "sam.fleet.listeners.${n}";
    }) (lib.filterAttrs (_: l: l.host == h) fleet.listeners)
    ++ map (p: {
      inherit (p) port proto;
      by = "sam.fleet.public";
    }) (lib.filter (p: p.port != null && (p.host == null || p.host == h)) fleet.public);
in
{
  inherit hosts edgeNames forwardAuth;
  inherit (fleet) edge edgeMetrics;
  # edge.nix's domain; a rename leaves edgeNames empty, which the flake check refuses
  domain = "sammasak.dev";
  ports = lib.genAttrs hosts taken;
  secrets = lib.genAttrs hosts (h: secrets.${h} or [ ]);
}
