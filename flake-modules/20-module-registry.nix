let
  sortNames = names: builtins.sort builtins.lessThan names;

  listRegularNixFiles =
    dir:
    let
      entries = builtins.readDir dir;
      names = sortNames (builtins.attrNames entries);
    in
    builtins.filter (
      name:
      entries.${name} == "regular" && builtins.match ".*\\.nix" name != null
    ) names;

  listDirectories =
    dir:
    let
      entries = builtins.readDir dir;
      names = sortNames (builtins.attrNames entries);
    in
    builtins.filter (name: entries.${name} == "directory") names;

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
  hostDirs = listDirectories ../hosts;

  hostDirsWithHome = builtins.filter (
    host: builtins.pathExists (../hosts + "/${host}/home.nix")
  ) hostDirs;
in
{
  flake.modules = {
    nixos = mkAttrs roleFiles (file: "role-${stripNixSuffix file}") (file: ../modules/roles + "/${file}");

    homeManager = mkAttrs hostDirsWithHome (host: "host-${host}") (host: ../hosts + "/${host}/home.nix");
  };
}
