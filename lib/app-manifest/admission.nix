# The registry (grants and manifests) against the fleet's facts. A field's type refuses a malformed manifest or grant
# on its own; these assertions are the relations no single field can see: across apps, and against the fleet.
{
  lib,
  config,
  facts,
  ...
}:
let
  inherit (lib) mkOption types;
  names = import ./names.nix lib;
  inherit (config) apps grants;
  rule = assertion: message: { inherit assertion message; };
  others = n: list: lib.concatMapStringsSep ", " (o: "apps.${o}") (lib.remove n list);
  claimants = l: lib.attrNames (lib.filterAttrs (_: a: a.ingress ? ${l}) apps);
  listening =
    host: port:
    lib.attrNames (
      lib.filterAttrs (
        n: a: grants ? ${n} && grants.${n}.host == host && (a.runtime.service.port or null) == port
      ) apps
    );
  admit =
    n: a:
    let
      g = grants.${n};
      at = "apps.${n}";
      s = a.runtime.service or null;
      fleetPort = lib.findFirst (p: p.port == s.port && p.proto == "tcp") null facts.ports.${g.host};
    in
    [
      (rule (
        a.owner == g.owner
      ) "${at}.owner: ${a.owner} is not the owner grants.${n} approves (${g.owner}).")
      (rule (
        a.source.repo == g.repo
      ) "${at}.source.repo: ${a.source.repo} is not the repository grants.${n} allowlists (${g.repo}).")
      (rule (a.ingress == { } && s != null || g.host == facts.edge)
        "grants.${n}.host: ${g.host} is not the edge (${facts.edge}); a static site or an app with ingress runs there."
      )
    ]
    ++ lib.concatMap (l: [
      (rule (lib.elem l g.hostnames) "${at}.ingress.${l}: not in grants.${n}.hostnames.")
      (rule (!lib.elem l facts.edgeNames)
        "${at}.ingress.${l}: ${l}.${facts.domain} is already served by the edge (modules/homelab/edge.nix)."
      )
      (rule (
        claimants l == [ n ]
      ) "${at}.ingress.${l}: ${l}.${facts.domain} is also claimed by ${others n (claimants l)}.")
    ]) (lib.attrNames a.ingress)
    ++ lib.optionals (s != null) (
      [
        (rule (s.resources.memoryMiB <= g.memoryMiB)
          "${at}.runtime.service.resources.memoryMiB: ${toString s.resources.memoryMiB} is above grants.${n}.memoryMiB (${toString g.memoryMiB})."
        )
        (rule (
          fleetPort == null
        ) "${at}.runtime.service.port: ${toString s.port}/tcp on ${g.host} is ${fleetPort.by}.")
        (rule (listening g.host s.port == [ n ])
          "${at}.runtime.service.port: ${toString s.port}/tcp on ${g.host} is also ${others n (listening g.host s.port)}'s."
        )
      ]
      ++ lib.concatMap (k: [
        (rule (lib.elem k g.secrets) "${at}.runtime.service.secrets.\"${k}\": not in grants.${n}.secrets.")
        (rule (lib.elem k
          facts.secrets.${g.host}
        ) "${at}.runtime.service.secrets.\"${k}\": no sops secret of that name is declared on ${g.host}.")
      ]) (lib.attrNames s.secrets)
    );
in
{
  options = {
    apps = mkOption {
      type = names.keyed names.app (types.submodule ./v1alpha1.nix);
      default = { };
      description = "The app repositories' manifests, by app name.";
    };
    grants = mkOption {
      type = names.keyed names.app (types.submodule (import ./grant.nix facts));
      default = { };
      description = "What the platform approves for each app, by app name.";
    };
    assertions = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            assertion = mkOption { type = types.bool; };
            message = mkOption { type = types.str; };
          };
        }
      );
      internal = true;
      default = [ ];
      description = "The admission rules, each an assertion and the message it fails with.";
    };
  };

  config.assertions =
    lib.mapAttrsToList (
      n: _: rule (grants ? ${n}) "apps.${n}: no grants.${n}, so the platform has not admitted it."
    ) apps
    ++ lib.concatLists (lib.mapAttrsToList admit (lib.filterAttrs (n: _: grants ? ${n}) apps));
}
