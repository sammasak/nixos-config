{ config, lib, inputs, ... }:
let
  users = import ../lib/users.nix;

  mkDarwinDistribution =
    _name:
    { user, system }:
    inputs.nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        config.flake.modules.darwin.common
        inputs.home-manager.darwinModules.home-manager
        {
          sam.darwin.user = user;
          sam.userConfig = users.${user} or { };

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
            users.${user} =
              config.flake.modules.homeManager."darwin-${user}"
              or (throw "Missing darwin home-manager module for `${user}`");
          };
        }
      ];
    };
in
{
  config.flake.darwinConfigurations =
    lib.mapAttrs mkDarwinDistribution config.configurations.darwin;
}
