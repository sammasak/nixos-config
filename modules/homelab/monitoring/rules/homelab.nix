# rules/homelab.yaml with the homelab:node:planned_off expression rendered from sam.fleet.hosts (modules/core/fleet.nix):
# the yaml holds the placeholder as a plain block scalar, so it still parses. Returns the rendered file's store path
# (a plain toFile, so evaluating black-pi's config on x86 never builds an aarch64 derivation) and the windowed hosts.
#
# A host is windowed when it sleeps, has a power window and the owner does not also power it off by hand
# (power.manualOff); the rest of the sleeping hosts are planned off at any time. PromQL time is UTC with no time zone,
# so a window "Mon-Fri <wake> / Mon-Fri <off>" (the fleet's time.timeZone, Europe/Stockholm, UTC+1 or +2:
# modules/core/system.nix) becomes the union of both seasons:
#   from <off hour> - 2h UTC (the summer off, the earlier of the two) to <wake> read as UTC (the winter wake is an hour
#   and the summer wake two hours earlier in UTC, so the exporter has that long to come up), plus Saturday and Sunday.
# Only that shape is rendered; any other window fails the build rather than being rendered wrongly.
{ lib, hosts }:
let
  windowed = lib.filterAttrs (_: h: h.sleeps && h.power != null && !h.power.manualOff) hosts;
  names = lib.attrNames windowed;
  sleeping = lib.attrNames (lib.filterAttrs (_: h: h.sleeps) hosts);

  # "Mon-Fri HH:MM" -> { h, m }; leading zeros dropped for fromJSON
  at =
    what: s:
    let
      m = lib.match "Mon-Fri ([0-9]{2}):([0-9]{2})" s;
      num = x: builtins.fromJSON (if x == "00" then "0" else lib.removePrefix "0" x);
    in
    assert lib.assertMsg (m != null && num (lib.elemAt m 0) < 24 && num (lib.elemAt m 1) < 60)
      "rules/homelab.nix: ${what} '${s}' is not 'Mon-Fri HH:MM'; only that window shape renders to PromQL";
    {
      h = num (lib.elemAt m 0);
      m = num (lib.elemAt m 1);
    };

  windows = lib.unique (
    map (n: {
      wake = at "${n} wake" windowed.${n}.power.wake;
      off = at "${n} off" windowed.${n}.power.off;
    }) names
  );
  window = lib.head windows;
  from = window.off.h - 2;
  until = window.wake;

  matcher =
    neg:
    if lib.length names == 1 then
      "node${lib.optionalString neg "!"}=\"${lib.head names}\""
    else
      "node${if neg then "!~" else "=~"}\"${lib.concatStringsSep "|" names}\"";
  series = extra: "max by (node) (up{job=\"node-exporter\",sleeps=\"true\"${extra}})";

  untilClause =
    if until.m == 0 then
      "hour() < ${toString until.h}"
    else
      "hour() < ${toString until.h} or (hour() == ${toString until.h} and minute() < ${toString until.m})";

  lines =
    if names == [ ] then
      [ (series "") ]
    else
      [
        (series ",${matcher true}")
        "or ("
        "  ${series ",${matcher false}"}"
        "  and on () ("
        "    hour() >= ${toString from} or ${untilClause}"
        "    or day_of_week() == 0 or day_of_week() == 6"
        "  )"
        ")"
      ];
  expr = lib.concatMapStringsSep "\n" (l: "          " + l) lines;
  placeholder = "          @PLANNED_OFF_EXPR@";
  src = builtins.readFile ./homelab.yaml;
in
assert lib.assertMsg (lib.length windows <= 1)
  "rules/homelab.nix: the windowed hosts ${toString names} do not share one window; planned_off renders one";
assert lib.assertMsg (names == [ ] || (window.off.m == 0 && window.off.h >= 2 && from > until.h))
  "rules/homelab.nix: a power window must power off on the hour, after its wake: ${builtins.toJSON windows}";
assert lib.assertMsg (lib.all (
  n: lib.elem n sleeping
) names) "rules/homelab.nix: a windowed host must sleep";
assert lib.assertMsg (lib.hasInfix placeholder (
  src
)) "rules/homelab.nix: homelab.yaml no longer holds ${placeholder}";
{
  inherit windowed;
  file = builtins.toFile "homelab.yaml" (lib.replaceStrings [ placeholder ] [ expr ] src);
}
