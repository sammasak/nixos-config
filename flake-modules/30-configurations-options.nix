{ lib, ... }:
{
  options.configurations = {
    nixos = lib.mkOption {
      description = "NixOS distribution declarations.";
      default = { };
      type = lib.types.lazyAttrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              hostDir = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Directory under hosts/ used for this distribution.";
              };

              roles = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = "Role modules resolved via flake.modules.nixos.role-<name>; also sets sam.profile.roles.";
              };

              deploy = {
                hostname = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                  description = "Address deploy-rs connects to for this host's node.";
                };

                remoteBuild = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Build the closure on the target instead of the deployer.";
                };
              };
            };
          }
        )
      );
    };
  };
}
