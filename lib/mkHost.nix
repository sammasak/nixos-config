{ nixpkgs, home-manager }:

{hostName, system, user, hostModule, homeModule }:
nixpkgs.lib.nixosSystem {
  inherit system;

  specialArgs = { inherit hostName user;};

  modules = [
    ./../modules/nixos/base.nix
    hostModule


    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} = import homeModule;
    }
  ];
}


