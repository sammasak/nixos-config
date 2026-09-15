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

    # Firefox add-ons (rycee's firefox-addons set) for declarative extensions.
    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";
    nur.inputs.flake-parts.follows = "flake-parts";

    # Weekly prebuilt nix-index DB: powers `, cmd` (comma) without ever
    # running nix-index locally.
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    claude-code-skills.url = "github:sammasak/claude-code-skills";
    claude-code-skills.flake = false;

    import-tree.url = "github:mightyiam/import-tree";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, import-tree, ... }:
    let
      rawFlake = flake-parts.lib.mkFlake { inherit inputs; } (import-tree ./flake-modules);
    in
    builtins.removeAttrs rawFlake [ "modules" ];
}
