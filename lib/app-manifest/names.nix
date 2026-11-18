# The name shapes the contract and its grant share, and `keyed`: attrsOf whose names must match a pattern. attrsOf
# rebuilds itself from its functor when it holds submodules, so substSubModules must return `keyed` again or the
# name check silently goes.
lib:
let
  keyed =
    pattern: elem:
    let
      base = lib.types.attrsOf elem;
    in
    base
    // {
      description = "attribute set with names matching `${pattern}` of ${elem.description}";
      merge =
        loc: defs:
        let
          bad = lib.filter (k: builtins.match pattern k == null) (
            lib.concatMap (d: lib.attrNames d.value) defs
          );
        in
        if bad == [ ] then
          base.merge loc defs
        else
          throw "The option `${lib.showOption loc}' has names ${builtins.toJSON bad} that do not match `${pattern}`.";
      substSubModules = m: keyed pattern (elem.substSubModules m);
    };
in
{
  inherit keyed;
  memoryMiB = lib.types.ints.between 16 2048;
  app = "[a-z][a-z0-9-]{0,30}";
  label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";
  login = "[A-Za-z0-9](-?[A-Za-z0-9]){0,38}";
  repo = "[A-Za-z0-9-]+/[A-Za-z0-9._-]+";
  attr = "[A-Za-z0-9_][A-Za-z0-9._-]*";
  secret = "[a-z0-9_-]+(/[a-z0-9_-]+)*";
  credential = "[A-Za-z0-9_][A-Za-z0-9._-]*";
  # an absolute HTTP path the edge and the scrape interpolate: no space, brace, quote or query can end the directive
  path = "/[A-Za-z0-9._~/-]*";
}
