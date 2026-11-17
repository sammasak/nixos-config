# The provisioned dashboards, parsed, with their host variables filled from sam.fleet.hosts: a dashboard declares
# `{"name": "node", "type": "custom"}` and gets the fleet's hosts as its options, so no dashboard
# lists a host by hand. `dashboards` is what grafana.nix provisions; flake-modules/grafana-dashboards-check.nix checks
# them and seeds `render`.
{ lib, hosts }:
let
  derived = {
    node = lib.attrNames hosts;
  };
  fill =
    f: v:
    let
      values = derived.${v.name};
      multi = v.multi or false;
      current =
        if multi || values == [ ] then
          {
            text = [ "All" ];
            value = [ "$__all" ];
          }
        else
          {
            text = lib.head values;
            value = lib.head values;
          };
    in
    assert lib.assertMsg (v.type or null == "custom" && !(v ? query || v ? options || v ? current))
      "dashboards/${f}: variable ${v.name} is filled from sam.fleet.hosts; declare it as {\"name\": \"${v.name}\", \"type\": \"custom\"} without query, options or current";
    v
    // {
      query = lib.concatStringsSep "," values;
      options = map (h: {
        text = h;
        value = h;
        selected = false;
      }) values;
      inherit current;
    };
  render =
    f: d:
    d
    // lib.optionalAttrs (d ? templating) {
      templating = d.templating // {
        list = map (v: if derived ? ${v.name} then fill f v else v) d.templating.list;
      };
    };
in
{
  inherit render;
  dashboards =
    lib.mapAttrs
      (
        f: _:
        render f (
          builtins.addErrorContext "while parsing dashboards/${f}" (lib.importJSON (./dashboards + "/${f}"))
        )
      )
      (lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix ".json" f) (builtins.readDir ./dashboards));
}
