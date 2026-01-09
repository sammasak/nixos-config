# mkHost - Host builder helper
# Creates a NixOS configuration with profile support and home-manager integration

{ nixpkgs, home-manager, stylix }:

{ hostName, system, user, hostModule, homeModule, profiles ? [] }:
let
  # Profile name -> file mapping
  profileMap = {
    "base" = ./../profiles/base.nix;
    "desktop" = ./../profiles/desktop.nix;
    "laptop" = ./../profiles/laptop.nix;
  };

  # Always include base, then add requested profiles
  profileModules = [ profileMap."base" ] ++
    (map (name: profileMap.${name}) profiles);
in
nixpkgs.lib.nixosSystem {
  inherit system;

  specialArgs = { inherit hostName user; };

  modules = profileModules ++ [
    hostModule

    # Stylix theming (applied to all hosts with desktop profile)
    stylix.nixosModules.stylix

    # Home manager integration
    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} = import homeModule;
    }
  ];
}
