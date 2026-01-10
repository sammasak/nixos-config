{
  description = "multi host, nixos, home-manager flake";

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

  outputs = {self, nixpkgs, home-manager, stylix, ...}:
  let
    mkHost = import ./lib/mkHost.nix {inherit nixpkgs home-manager stylix; };
  in
  {
    nixosConfigurations = {
      acer-swift = mkHost {
        hostName = "acer-swift";
        system = "x86_64-linux";
        user = "lukas";
        profiles = [ "desktop" "laptop" ];
        hostModule = ./hosts/acer-swift/default.nix;
        homeModule = ./home/lukas/acer-swift.nix;
      };
    };

    homeConfigurations = {
      "lukas@acer-swift" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [ ./home/lukas/acer-swift.nix ];
        extraSpecialArgs = { hostName = "acer-swift"; user = "lukas"; };
      };
    };
  };
}
