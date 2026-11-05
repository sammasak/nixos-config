# External consumer fixture: imports the agent-runtime module through the
# nixos-config input (nothing copied) and evaluates two templates, a real
# nixosSystem that imports the module, and the negative cases.
{
  inputs = {
    nixos-config.url = "github:sammasak/nixos-config";
    nixpkgs.follows = "nixos-config/nixpkgs";
  };

  outputs =
    { nixos-config, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      runtime = nixos-config.lib.agentRuntime { inherit pkgs; };
      args = { inherit (nixos-config.inputs) factum skills; };
      templates = import ./templates.nix args;
      cases = import ./cases.nix (args // { inherit (nixpkgs) lib; });
    in
    {
      agentRuntime = runtime.evalManifests { modules = [ templates ]; };

      agentRuntimeCases = map (c: { inherit (c) name expect; }) cases;
      agentRuntimeNegative = builtins.listToAttrs (
        map (c: {
          inherit (c) name;
          value = runtime.evalManifests { modules = [ templates c.module ]; };
        }) cases
      );

      nixosConfigurations.consumer = nixpkgs.lib.nixosSystem {
        modules = [
          nixos-config.nixosModules.agent-runtime
          templates
          {
            nixpkgs.hostPlatform = system;
            boot.loader.grub.enable = false;
            fileSystems."/".device = "/dev/disk/by-label/nixos";
            system.stateVersion = "25.11";
          }
        ];
      };
    };
}
