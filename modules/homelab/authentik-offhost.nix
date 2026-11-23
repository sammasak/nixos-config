# The off-host copy of Authentik's nightly dump: lenovo pulls acer's `latest` an hour after it is written. It logs in
# with its own host key as backup-pull, whose only command is that cat (authentik.nix), so a compromised acer cannot
# write here and lenovo can read nothing else there.
{ config, pkgs, ... }:
let
  dir = "/var/lib/authentik-offhost";
  acer = config.sam.fleet.hosts.acer-swift.address;
in
{
  imports = [ ./backup-metrics.nix ];
  homelab.backupMetrics.jobs.authentik-offhost = "archive_list";

  systemd.tmpfiles.rules = [ "d ${dir} 0700 root root -" ];
  systemd.services.authentik-offhost = {
    description = "Copy Authentik's latest dump from acer";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      out=${dir}/authentik-$(date +%Y%m%d-%H%M%S).dump
      ${pkgs.openssh}/bin/ssh -i /etc/ssh/ssh_host_ed25519_key -o BatchMode=yes -o IdentitiesOnly=yes \
        backup-pull@${acer} > "$out.partial"
      ${pkgs.postgresql_16}/bin/pg_restore --list "$out.partial" >/dev/null
      mv "$out.partial" "$out"
      ls -1t ${dir}/authentik-*.dump | tail -n +8 | xargs -r rm -f
    '';
  };
  systemd.timers.authentik-offhost = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:05:00";
      Persistent = true;
    };
  };
  system.checks = [
    (pkgs.runCommand "authentik-offhost-script-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
      shellcheck --severity=warning ${config.systemd.services.authentik-offhost.serviceConfig.ExecStart}
      touch $out
    '')
  ];
}
