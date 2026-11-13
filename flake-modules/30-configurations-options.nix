{ lib, ... }:
{
  options.configurations = {
    nixos = lib.mkOption {
      description = "NixOS distribution declarations.";
      default = { };
      type = lib.types.lazyAttrsOf (
        lib.types.submodule {
          options = {
            hostDir = lib.mkOption {
              type = lib.types.str;
              description = "Directory under hosts/ used for this distribution.";
            };

            username = lib.mkOption {
              type = lib.types.str;
              description = "Primary host user used for Home Manager and user identity lookup.";
            };

            roles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "base" ];
              description = "Role modules resolved via flake.modules.nixos.role-<name>.";
            };
          };
        }
      );
    };
  };
}
