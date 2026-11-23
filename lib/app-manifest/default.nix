# App manifest admission, lib-only: no host imports it, so no host's toplevel depends on it. pins.nix (apps/registry.json)
# is the one file here hosts read, through the overlay; it shares names.nix and grant.nix.
{ lib }:
{
  facts = import ./facts.nix lib;
}
// rec {
  # the one upstream of a service: derived from the app name, never chosen by the manifest, so no app can point the
  # edge at another listener; the name pattern bounds it to 51 bytes, within sun_path's 108
  socket = n: "/run/apps/${n}/http.sock";
  # every refused rule's message, after the whole registry type-checks: a type error throws instead
  refusals = facts: registry: (admitted facts registry).refused;
  # each admitted app's edge sites and metrics scrape (render.nix); package: app name -> its built store path
  render =
    facts: registry: package:
    import ./render.nix {
      inherit lib facts package;
      granted = admit facts registry;
    };
  # the capabilities each admitted app gets, or a throw listing every refused rule
  admit =
    facts: registry:
    let
      inherit (admitted facts registry) refused granted;
    in
    if refused != [ ] then
      throw "app admission refused:\n${lib.concatMapStrings (m: "  ${m}\n") refused}"
    else
      granted;
  admitted =
    facts: registry:
    let
      eval = lib.evalModules {
        specialArgs = { inherit facts; };
        modules = [
          ./admission.nix
          registry
        ];
      };
      inherit (eval.config) apps grants;
      checked = builtins.deepSeq [
        apps
        grants
      ];
      granted = lib.mapAttrs (
        n: a:
        {
          inherit (grants.${n}) host owner;
          source = "${a.source.repo}@${a.source.rev}#${a.source.package}";
          ingress = lib.mapAttrs' (l: i: lib.nameValuePair "${l}.${facts.domain}" i.auth) a.ingress;
        }
        // lib.optionalAttrs (a.runtime ? static) { inherit (a.runtime) static; }
        // lib.optionalAttrs (a.runtime ? service) {
          inherit (a.runtime.service) resources metricsPath;
          socket = socket n;
          secrets = lib.attrNames a.runtime.service.secrets;
          state = lib.attrNames a.runtime.service.state;
        }
      ) apps;
    in
    {
      refused = checked (map (a: a.message) (lib.filter (a: !a.assertion) eval.config.assertions));
      granted = checked granted;
    };
}
