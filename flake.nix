{
  description = "NixOS + Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    stylix.url = "github:danth/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    claude-code-skills.url = "github:sammasak/claude-code-skills";
    claude-code-skills.flake = false;

    claude-ctl.url = "github:sammasak/claude-ctl/v0.0.1";
    claude-ctl.flake = false;
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      collectFlakeModules =
        dir:
        let
          entries = builtins.readDir dir;
          names = builtins.sort builtins.lessThan (builtins.attrNames entries);
          toImports =
            name:
            let
              entryType = entries.${name};
              path = dir + "/${name}";
            in
            if entryType == "directory" then
              collectFlakeModules path
            else if entryType == "regular" && builtins.match ".*\\.nix" name != null then
              [ path ]
            else
              [ ];
        in
        builtins.concatLists (builtins.map toImports names);
      rawFlake = flake-parts.lib.mkFlake { inherit inputs; } {
        imports = collectFlakeModules ./flake-modules;
      };
    in
    builtins.removeAttrs rawFlake [ "modules" ];
}
