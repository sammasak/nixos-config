{
  description = "NixOS config with Hyprland desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, stylix, ... }:
  let
    users = import ./lib/users.nix;
  in
  {
    nixosConfigurations = {
      acer-swift = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        specialArgs = {
          hostName = "acer-swift";
          user = "lukas";
        };

        modules = [
          # Core
          ./profiles/base.nix
          home-manager.nixosModules.home-manager
          stylix.nixosModules.stylix
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";  # Backup conflicting files instead of failing
            home-manager.extraSpecialArgs = { userConfig = users.lukas; };
          }

          # Machine type (includes both system + user config)
          ./profiles/desktop.nix
          ./profiles/laptop.nix

          # Hardware
          ./hosts/acer-swift
        ];
      };
    };
  };
}
