let
  listRegularNixFiles =
    dir:
    let
      entries = builtins.readDir dir;
    in
    builtins.filter (
      name:
      entries.${name} == "regular" && builtins.match ".*\\.nix" name != null
    ) (builtins.attrNames entries);

  mkAttrs =
    names: mkName: mkValue:
    builtins.listToAttrs (
      builtins.map (name: {
        name = mkName name;
        value = mkValue name;
      }) names
    );

  stripNixSuffix = name: builtins.replaceStrings [ ".nix" ] [ "" ] name;

  roleFiles = listRegularNixFiles ../modules/roles;
  homeFiles = listRegularNixFiles ../modules/home;
in
{
  # Lookups through flake.modules nest these files deeper, which fixes their merge order (docs/flake-wiring.md):
  # importing the plain paths instead moves every host's toplevel, waybar/swaync CSS included (#315).
  flake.modules = {
    nixos = mkAttrs roleFiles (file: "role-${stripNixSuffix file}") (file: ../modules/roles + "/${file}");

    homeManager = mkAttrs homeFiles stripNixSuffix (file: ../modules/home + "/${file}");
  };
}
