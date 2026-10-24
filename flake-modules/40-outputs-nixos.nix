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
          inputs.disko.nixosModules.disko
          (nixos: {
            nixpkgs.overlays = [
              config.flake.overlays.default
              # pkgs.nur.* — keeps modules on plain pkgs, no specialArgs.
              inputs.nur.overlays.default
            ];
            sam.userConfig = users.${username} or { };

            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "backup";
              sharedModules = [
                inputs.nix-index-database.homeModules.default
              ]
              ++ lib.optionals nixos.config.sam.profile.devTools [
                ../modules/programs/cli/claude-code/default.nix
                (import ../modules/programs/cli/claude-code/mcp.nix inputs.skills nixos.config.sam.profile.nativeOtel nixos.config.sam.profile.hostname)
                (import ../modules/programs/cli/claude-code/skills.nix inputs.skills)
                (import ../modules/programs/cli/codex/default.nix inputs.skills nixos.config.sam.profile.nativeOtel)
              ]
              ++ lib.optionals nixos.config.sam.profile.nativeOtel [
                (import ../modules/programs/cli/native-otel.nix nixos.config.sam.profile.hostname)
              ]
              ++ lib.optionals nixos.config.sam.profile.pi [
                (import ../modules/programs/cli/pi inputs.devenv-platform)
              ]
              ++ lib.optionals (name == "lenovo") [
                ../modules/programs/cli/factum-lenovo.nix
                ../modules/programs/cli/nix-audit-lenovo.nix
              ];
              users.${username} =
                config.flake.modules.homeManager.default
                or (throw "Missing shared home-manager module at modules/home/default.nix");
            };
          })
        ];
    };
in
{
  config.flake.nixosConfigurations =
    lib.mapAttrs mkNixosDistribution config.configurations.nixos;
}
