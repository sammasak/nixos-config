{
  description = "multi host, nixos, home-manager flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, nixpkgs, home-manager, ...}:
  let 
    mkHost = import ./lib/mkHost.nix {inherit nixpkgs home-manager; };
  in
  {
    nixosConfigurations = {
      acer-swift = mkHost {
        hostName = "acer-swift";
        system = "x86_64-linux";
        user = "lukas";
        hostModule = ./hosts/acer-swift/default.nix;
        homeModule = ./home/lukas/acer-swift.nix;
      };
    };
  };
}
