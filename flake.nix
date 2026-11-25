{
  description = "Six-host NixOS fleet: typed host table, role modules, Home Manager, sops-nix, deploy-rs";

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

    skills.url = "git+ssh://git@github.com/sammasak/skills";
    skills.flake = false;

    factum.url = "git+ssh://git@github.com/sammasak/factum?rev=5bb7fa304db7d8ae7d422e8d6356bf06b90d3b41";
    factum.flake = false;

    nix-audit.url = "git+ssh://git@github.com/sammasak/nix-audit?rev=38789c530998164335637c6b6982b5ddc9e0fda1";
    nix-audit.flake = false;

    llm-gateway.url = "git+ssh://git@github.com/sammasak/llm-gateway?rev=8ec12bf580f19e0e1f665093287ebd5ef9ddb84d";
    llm-gateway.flake = false;

    rf-proto.url = "git+ssh://git@github.com/sammasak/rf-proto?rev=89e08d25d3057f3b68ef5d8a3508238789f8b7de";
    rf-proto.flake = false;

    herman.url = "git+ssh://git@github.com/sammasak/herman?rev=7f41955749fc473d11173ffbc18e76973a7bb224";
    herman.flake = false;

    # The fork's flake (its own nixpkgs, CUDA 13 and toolchain) for the runner's recipe and the sm_86 kernel pack;
    # paddock-serve is the serving branch it builds the runner from (modules/homelab/paddock.nix).
    paddock.url = "git+ssh://git@github.com/sammasak/paddock?ref=asus/devshell-driver-lib&rev=355df36cc5eceef56e2eb108373162a79b131579";
    paddock-serve.url = "git+ssh://git@github.com/sammasak/paddock?ref=asus/ssd-expert-backing&rev=11d7253b8921884d62fa27cbc4d2dbb8864ec4ef";
    paddock-serve.flake = false;

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Private repo: ssh URL (github: 404s without a token). Supplies the Pi
    # router/free extension to hosts with sam.profile.pi.
    devenv-platform.url = "git+ssh://git@github.com/sammasak/devenv-platform";
    devenv-platform.flake = false;

    import-tree.url = "github:mightyiam/import-tree";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, import-tree, ... }:
    let
      rawFlake = flake-parts.lib.mkFlake { inherit inputs; } (import-tree ./flake-modules);
    in
    builtins.removeAttrs rawFlake [ "modules" ];
}
