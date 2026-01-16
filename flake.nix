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

  outputs = { self, nixpkgs, home-manager, nix-darwin, stylix, ... }@inputs:
  let
    users = import ./lib/users.nix;

    # Helper function to create NixOS hosts
    mkHost = { hostDir, system ? "x86_64-linux" }:
    let
      vars = import ./hosts/${hostDir}/variables.nix;
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        host = hostDir;
        user = vars.username;
      };
      modules = [
        # Host-specific configuration
        ./hosts/${hostDir}/configuration.nix

        # Stylix theming
        stylix.nixosModules.stylix

        # Home Manager
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
            extraSpecialArgs = {
              inherit inputs;
              host = hostDir;
              userConfig = users.${vars.username} or {};
            };
            users.${vars.username} = import ./hosts/${hostDir}/home.nix;
          };
        }
      ];
    };

    # Darwin helper (unchanged for now)
    mkDarwin = { user }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.backupFileExtension = "backup";
      home-manager.extraSpecialArgs = { userConfig = users.${user}; desktop = false; };
      home-manager.users.${user} = import ./home/${user}.nix;
    };
  in {
    nixosConfigurations = {
      acer-swift = mkHost { hostDir = "acer-swift"; };
      lenovo = mkHost { hostDir = "lenovo-21CB001PMX"; };
    };

    darwinConfigurations = {
      work-mac = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { user = "lukas"; };
        modules = [
          ./darwin/common.nix
          home-manager.darwinModules.home-manager
          (mkDarwin { user = "lukas"; })
        ];
      };
    };
  };
}
