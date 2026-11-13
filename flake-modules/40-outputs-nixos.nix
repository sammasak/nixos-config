{ config, lib, inputs, ... }:
let
  users = import ../lib/users.nix;

  # Home Manager as every host gets it; a worker container (modules/workers) reuses it under host name "worker".
  fleetHome =
    host: os:
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
          # a host's Codex follows nativeOtel even with Claude's telemetry off (acer, msi); an environment has no
          # nativeOtel (no relay, no secret), so its Codex follows the sam.claude.telemetry its host sets
          (import ../modules/programs/cli/codex/default.nix inputs.skills (os.config.sam.profile.nativeOtel || os.config.sam.claude.telemetry.enable))
          ../modules/programs/cli/coordinator-wakeup.nix
        ]
        ++ lib.optionals (os.config.sam.profile.nativeOtel || os.config.sam.claude.telemetry.enable) [
          (import ../modules/programs/cli/native-otel.nix os.config.sam.claude.telemetry.resourceAttributes)
        ]
        ++ lib.optionals os.config.sam.profile.pi [
          (import ../modules/programs/cli/pi inputs.devenv-platform)
        ]
        ++ lib.optionals (host == "lenovo") [
          ../modules/programs/cli/factum-lenovo.nix
        ]
        ++ lib.optionals (lib.elem host [ "lenovo" "acer-swift" "msi-ms7758" ]) [
          ../modules/programs/cli/nix-audit.nix
        ];
        users.${os.config.sam.profile.username} =
          config.flake.modules.homeManager.default
          or (throw "Missing shared home-manager module at modules/home/default.nix");
      };
    };

  # Every host's modules after its configuration and roles; the runtime-host VM test (52-runtime-host-vm-test.nix) reuses them.
  fleetModules =
    name:
    [
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
        sam.workers.guestModules = [ inputs.home-manager.nixosModules.home-manager (fleetHome "worker") ];
      })
      (fleetHome name)
    ];

  mkNixosDistribution =
    name:
    {
      hostDir,
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
      modules =
        [
          ../hosts/${hostDir}/configuration.nix
        ]
        ++ roleModules
        ++ fleetModules name;
    };
in
{
  config._module.args.fleetModules = fleetModules;
  config.flake.nixosConfigurations =
    lib.mapAttrs mkNixosDistribution config.configurations.nixos;
}
