# External consumer fixture: imports the agent-runtime module through the
# nixos-config input (no module code is vendored). The input URL is a placeholder;
# scripts/test-agent-runtime.sh always overrides it with this checkout.
{
  inputs = {
    nixos-config.url = "github:sammasak/nixos-config";
    nixpkgs.follows = "nixos-config/nixpkgs";
  };

  outputs =
    { nixos-config, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      runtime = nixos-config.lib.agentRuntime { inherit pkgs; };
      args = { inherit (nixos-config.inputs) factum skills; };
      templates = import ./templates.nix args;
      cases = import ./cases.nix (args // { inherit lib; });
      unknownTemplateCase = lib.findFirst (c: c.name == "host-eligible-unknown-template") (
        throw "cases.nix: host-eligible-unknown-template missing"
      ) cases;
      consumerModules = [
        nixos-config.nixosModules.agent-runtime
        templates
        {
          nixpkgs.hostPlatform = system;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          system.stateVersion = "25.11";
        }
      ];
    in
    {
      # Test-only outputs read by scripts/test-agent-runtime.sh; agentRuntimeNegative throws by design.
      agentRuntime = runtime.evalManifests { modules = [ templates ]; };

      agentRuntimeCases = map (c: { inherit (c) name expect; }) cases;
      agentRuntimeNegative = builtins.listToAttrs (
        map (c: {
          inherit (c) name;
          value = runtime.evalManifests { modules = [ templates c.module ]; };
        }) cases
      );

      # The consumer host, and the same host with one bad template.
      nixosConfigurations = {
        consumer = lib.nixosSystem { modules = consumerModules; };
        consumer-bad = lib.nixosSystem { modules = consumerModules ++ [ unknownTemplateCase.module ]; };
      };
    };
}
