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
            };
          }
        )
      );
    };
  };
}
