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
in
{
  inherit hosts edgeNames forwardAuth;
  inherit (fleet) edge edgeMetrics;
  # edge.nix's domain; a rename leaves edgeNames empty, which the flake check refuses
  domain = "sammasak.dev";
  secrets = lib.genAttrs hosts (h: secrets.${h} or [ ]);
}
