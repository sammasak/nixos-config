{
  config,
  lib,
  options,
  ...
}:
{
  imports = [
    ../core/automation.nix
    ../core/boot.nix
    ../core/system.nix
    ../core/agent-options.nix
    ../core/users.nix
    ../core/network.nix
    ../core/services.nix
    ../core/ssh-known-hosts.nix
    ../core/packages.nix
    ../core/fonts.nix
    ../core/sops.nix
    ../core/resource-hygiene.nix
    ../core/store-cache.nix
    ../homelab/native-otel-relay.nix
    ../themes/Catppuccin # Stylix: off when headless under runtime-host, always off under rf-lab
    ../homelab/deploy-target.nix
  ];

  assertions =
    let
      rfUnits = builtins.filter (s: builtins.match "rf-.*" s != null) (
        builtins.attrNames config.systemd.services
      );
    in
    lib.optional (!lib.elem "rf-lab" config.sam.profile.roles) {
      assertion = !(options.sam ? rfLab) && rfUnits == [ ];
      message = "only a host with the rf-lab role may import modules/rf-lab or run rf-* units (#42); found: ${
        lib.concatStringsSep ", " (lib.optional (options.sam ? rfLab) "modules/rf-lab" ++ rfUnits)
      }.";
    };
}
