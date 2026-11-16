# Authentik's off-host copy spans two hosts: acer dumps and serves `latest` to backup-pull (authentik.nix), lenovo pulls
# it (authentik-offhost.nix). Neither host's evaluation sees the other half, so a module dropped from lenovo or a pull
# aimed elsewhere would leave acer's only copy on acer, found at restore time.
{ config, lib, ... }:
let
  acer = config.flake.nixosConfigurations.acer-swift.config;
  lenovo = config.flake.nixosConfigurations.lenovo.config;
  offhost = lenovo.systemd.services.authentik-offhost or { script = ""; };
  wiring = {
    "acer-swift runs authentik-backup from a timer" =
      acer.systemd.services ? authentik-backup
      && lib.elem "timers.target" (acer.systemd.timers.authentik-backup.wantedBy or [ ]);
    "lenovo runs authentik-offhost from a timer" =
      lenovo.systemd.services ? authentik-offhost
      && lib.elem "timers.target" (lenovo.systemd.timers.authentik-offhost.wantedBy or [ ]);
    "lenovo pulls backup-pull@acer with its ssh host key" =
      lib.hasInfix "-i /etc/ssh/ssh_host_ed25519_key" offhost.script
      && lib.hasInfix "backup-pull@${acer.sam.fleet.hosts.acer-swift.address} " offhost.script;
  };
  broken = lib.attrNames (lib.filterAttrs (_: ok: !ok) wiring);
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        authentik-backup-wiring = pkgs.writeText "authentik-backup-wiring" (
          assert lib.assertMsg (broken == [ ]) "authentik-backup-check: ${lib.concatStringsSep "; " broken}";
          lib.concatStringsSep "\n" (lib.attrNames wiring)
        );
      };
    };
}
