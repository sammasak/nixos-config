{
  # Colmena hive for managing all NixOS hosts from one machine.
  #
  # Usage examples:
  #   colmena apply --on acer-swift
  #   colmena apply --on lenovo
  #   colmena apply
  let
    flake = builtins.getFlake (toString ./.);
    inherit (flake) inputs;
    users = import ./lib/users.nix;

    mkNode = {
      hostDir,
      targetHost,
      targetUser ? "lukas",
      system ? "x86_64-linux",
    }: { ... }:
    let
      vars = import ./hosts/${hostDir}/variables.nix;
    in
    {
      deployment = {
        inherit targetHost targetUser;
      };

      nixpkgs.system = system;

      _module.args = {
        inherit inputs;
        host = hostDir;
        user = vars.username;
      };

      imports = [
        ./hosts/${hostDir}/configuration.nix

        inputs.stylix.nixosModules.stylix
        inputs.sops-nix.nixosModules.sops

        inputs.home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
            extraSpecialArgs = {
              inherit inputs;
              host = hostDir;
              userConfig = users.${vars.username} or { };
            };
            users.${vars.username} = import ./hosts/${hostDir}/home.nix;
          };
        }
      ];
    };
  in
  {
    meta = {
      nixpkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
      specialArgs = { inherit inputs; };
    };

    acer-swift = mkNode {
      hostDir = "acer-swift";
      targetHost = "acer-swift";
    };

    lenovo = mkNode {
      hostDir = "lenovo-21CB001PMX";
      targetHost = "lenovo-21CB001PMX";
    };
  }
