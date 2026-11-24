# The parked sessions' store on this host: msi logs in with its own host key as exec-pool-sync, whose only command is
# rrsync confined to the store, so it reads and writes session trees there and reaches nothing else. The runners'
# helpers push a parked tree here and pull it back (pkgs/exec-pool/src/sync.rs); a pull refuses devices and set-id
# files, as msi writes what this host's root then takes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  store = "${config.services.devEnvironments.stateDir}/.sessions-store";
  msi = "msi-ms7758";
  syncKey = "restrict,from=\"${
    config.sam.fleet.hosts.${msi}.address
  }\",command=\"${lib.getExe pkgs.rrsync} ${store}\" ${
    config.programs.ssh.knownHosts.${msi}.publicKey
  }";
in
{
  users.groups.exec-pool-sync = { };
  users.users.exec-pool-sync = {
    isSystemUser = true;
    group = "exec-pool-sync";
    # sshd runs the forced command through it
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [ syncKey ];
  };
  # AllowUsers is a list the other modules extend; without this sshd refuses the sync
  services.openssh.settings.AllowUsers = [ "exec-pool-sync" ];
  # the state dir is 0711 root: the user reaches its store through it and lists nothing else there
  systemd.tmpfiles.rules = [ "d ${store} 0700 exec-pool-sync exec-pool-sync -" ];

  assertions = [
    {
      # a key another module widens, or one without its forced command, would give msi a shell here
      assertion =
        config.users.users.exec-pool-sync.openssh.authorizedKeys.keys == [ syncKey ]
        && config.users.users.exec-pool-sync.openssh.authorizedKeys.keyFiles == [ ]
        && lib.elem "exec-pool-sync" config.services.openssh.settings.AllowUsers;
      message = "modules/homelab/exec-pool-store.nix: exec-pool-sync must hold only msi's restricted key (from=, command=rrsync ${store}) and be in AllowUsers.";
    }
  ];
}
