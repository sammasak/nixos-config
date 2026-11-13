{ config, lib, inputs, ... }:
let
  users = import ../lib/users.nix;

  # Home Manager as every host gets it; a worker container (modules/workers) reuses it.
  fleetHome =
    os:
    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "backup";
        sharedModules = [
          inputs.nix-index-database.homeModules.default
        ]
        ++ lib.optionals os.config.sam.profile.devTools [
          ../modules/programs/cli/claude-code/default.nix
          (import ../modules/programs/cli/claude-code/mcp.nix inputs.skills)
          (import ../modules/programs/cli/claude-code/skills.nix inputs.skills)
          (import ../modules/programs/cli/codex/default.nix inputs.skills)
          ../modules/programs/cli/coordinator-wakeup.nix
        ]
        ++ lib.optionals (os.config.sam.profile.nativeOtel || os.config.sam.claude.telemetry.enable) [
          ../modules/programs/cli/native-otel.nix
        ]
        ++ lib.optionals os.config.sam.profile.pi [
          (import ../modules/programs/cli/pi inputs.devenv-platform)
        ]
        ++ lib.optionals os.config.sam.cliTools.factum.enable [
          ../modules/programs/cli/factum.nix
        ]
        ++ lib.optionals os.config.sam.cliTools.nixAudit.enable [
          ../modules/programs/cli/nix-audit.nix
        ];
        users.${os.config.sam.profile.username} =
          config.flake.modules.homeManager.default
          or (throw "Missing shared home-manager module at modules/home/default.nix");
      };
    };

  # Every host's modules after its configuration and roles; the runtime-host VM test (52-runtime-host-vm-test.nix) reuses them.
  fleetModules = [
    inputs.stylix.nixosModules.stylix
    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    inputs.disko.nixosModules.disko
    ../modules/workers
    (os: {
      nixpkgs.overlays = [
        config.flake.overlays.default
        # pkgs.nur.*: keeps modules on plain pkgs, no specialArgs.
        inputs.nur.overlays.default
      ];
      sam.userConfig = users.${os.config.sam.profile.username};
      sam.workers.guestModules = [ inputs.home-manager.nixosModules.home-manager fleetHome ];
    })
    fleetHome
  ];

  mkNixosDistribution =
    name:
    {
      hostDir,
      roles,
      ...
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
      modules =
        [
          ../hosts/${hostDir}/configuration.nix
          ({ config, ... }: {
            sam.profile.roles = roles;
            assertions = [{
              assertion = config.sam.profile.roles == roles;
              message = "sam.profile.roles is set from configurations.nixos.${name}.roles; remove any other definition.";
            }];
          })
        ]
        ++ roleModules
        ++ fleetModules;
    };
in
{
  config._module.args.fleetModules = fleetModules;
  config.flake.nixosConfigurations =
    lib.mapAttrs mkNixosDistribution config.configurations.nixos;
}
