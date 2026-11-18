# App manifest admission, lib-only: no host imports any file here, so no host's toplevel depends on it.
{ lib }:
{
  facts = import ./facts.nix lib;
  # the capabilities each admitted app gets, or a throw listing every refused rule
  admit =
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
      refused = map (a: a.message) (lib.filter (a: !a.assertion) eval.config.assertions);
      granted = lib.mapAttrs (
        n: a:
        {
          inherit (grants.${n}) host owner;
          source = "${a.source.repo}@${a.source.rev}#${a.source.package}";
          ingress = lib.mapAttrs' (l: i: lib.nameValuePair "${l}.${facts.domain}" i.auth) a.ingress;
        }
        // lib.optionalAttrs (a.runtime ? service) {
          inherit (a.runtime.service) port resources;
          secrets = lib.attrNames a.runtime.service.secrets;
          state = lib.attrNames a.runtime.service.state;
        }
      ) apps;
    in
    if refused != [ ] then
      throw "app admission refused:\n${lib.concatMapStrings (m: "  ${m}\n") refused}"
    else
      builtins.deepSeq [ apps grants ] granted;
}
