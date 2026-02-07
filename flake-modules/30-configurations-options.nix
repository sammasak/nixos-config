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

            system = lib.mkOption {
              type = lib.types.str;
              default = "x86_64-linux";
              description = "Target platform string for nixpkgs.lib.nixosSystem.";
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

    darwin = lib.mkOption {
      description = "nix-darwin distribution declarations.";
      default = { };
      type = lib.types.lazyAttrsOf (
        lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              description = "Primary macOS user.";
            };

            system = lib.mkOption {
              type = lib.types.str;
              default = "aarch64-darwin";
              description = "Target platform string for nix-darwin.";
            };
          };
        }
      );
    };
  };
}
