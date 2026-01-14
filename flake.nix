{
  description = "NixOS + nix-darwin + Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    stylix.url = "github:danth/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, nix-darwin, stylix, ... }:
  let
    users = import ./lib/users.nix;
    mkHome = { user, desktop ? false }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.backupFileExtension = "backup";
      home-manager.extraSpecialArgs = { userConfig = users.${user}; inherit desktop; };
      home-manager.users.${user} = import ./home/${user}.nix;
    };
  in {
    nixosConfigurations = {
      acer-swift = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { hostName = "acer-swift"; user = "lukas"; };
        modules = [
          ./nixos/common.nix
          ./nixos/desktop.nix
          ./nixos/laptop.nix
          ./nixos/automation.nix
          ./hosts/acer-swift
          stylix.nixosModules.stylix
          home-manager.nixosModules.home-manager
          (mkHome { user = "lukas"; desktop = true; })
        ];
      };
      lenovo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { hostName = "lenovo-21CB001PMX"; user = "lukas"; };
        modules = [
          ./nixos/common.nix
          ./nixos/desktop.nix
          ./nixos/laptop.nix
          ./nixos/automation.nix
          ./hosts/lenovo-21CB001PMX
          stylix.nixosModules.stylix
          home-manager.nixosModules.home-manager
          (mkHome { user = "lukas"; desktop = true; })
        ];
      };
    };

    darwinConfigurations = {
      work-mac = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { user = "lukas"; };
        modules = [
          ./darwin/common.nix
          home-manager.darwinModules.home-manager
          (mkHome { user = "lukas"; desktop = false; })
        ];
      };
    };
  };
}
