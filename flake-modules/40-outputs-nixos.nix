{ config, lib, inputs, ... }:
let
  users = import ../lib/users.nix;

  mkNixosDistribution =
    name:
    {
      hostDir,
      system,
      username,
      roles,
    }:
    let
      roleNames = roles;
      roleModules = builtins.map (
        roleName:
        let
          moduleName = "role-${roleName}";
        in
        config.flake.modules.nixos.${moduleName}
          or (throw "Unknown role `${roleName}` in configurations.nixos.${name}.roles")
      ) roleNames;
    in
    assert lib.assertMsg (builtins.elem "base" roleNames) ''
      Host `${name}` must include role "base" in configurations.nixos.${name}.roles.
      The base role declares core typed options (`sam.profile`, `sam.userConfig`) used across modules.
    '';
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        [
          ../hosts/${hostDir}/configuration.nix
        ]
        ++ roleModules
        ++ [
          inputs.stylix.nixosModules.stylix
          inputs.sops-nix.nixosModules.sops
          inputs.home-manager.nixosModules.home-manager
          {
            nixpkgs.overlays = [ (import ../pkgs { claude-ctl-src = inputs.claude-ctl; }) ];
            sam.userConfig = users.${username} or { };

            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "backup";
              sharedModules = [
                ../modules/programs/cli/claude-code/mcp.nix
                (import ../modules/programs/cli/claude-code/skills.nix inputs.claude-code-skills)
              ];
              users.${username} =
                config.flake.modules.homeManager.default
                or (throw "Missing shared home-manager module at modules/home/default.nix");
            };
          }
        ];
    };
in
{
  config.flake.nixosConfigurations =
    lib.mapAttrs mkNixosDistribution config.configurations.nixos;
}
