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
  inherit (config.services.devEnvironments) stateDir;
  store = "${stateDir}/.sessions-store";
  # rsync 3.5's receiver opens every directory above its destination to read it, and the 0711 state dir refuses that
  # to the sync user (change_dir#3, code 3), so rrsync gets the store through a bind whose parents it can read
  served = "/var/lib/exec-pool-store";
  msi = "msi-ms7758";
  # -no-lock: rrsync's lock is the whole store's, so a drain's pushes from msi's slots at once failed all but one;
  # each session has its own directory, guarded by its generation mark (pkgs/exec-pool/src/sync.rs)
  syncKey = "restrict,from=\"${
    config.sam.fleet.hosts.${msi}.address
  }\",command=\"${lib.getExe pkgs.rrsync} -no-lock ${served}\" ${
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
  # unmounted, the mount point is root's and refuses every write: a push fails and is counted, never lands beside
  systemd.mounts = [
    {
      what = store;
      where = served;
      type = "none";
      options = "bind,nosuid,nodev,noexec";
      after = [ "systemd-tmpfiles-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
    }
  ];

  assertions = [
    {
      # a key another module widens, or one without its forced command, would give msi a shell here
      assertion =
        config.users.users.exec-pool-sync.openssh.authorizedKeys.keys == [ syncKey ]
        && config.users.users.exec-pool-sync.openssh.authorizedKeys.keyFiles == [ ]
        && lib.elem "exec-pool-sync" config.services.openssh.settings.AllowUsers;
      message = "modules/homelab/exec-pool-store.nix: exec-pool-sync must hold only msi's restricted key (from=, command=rrsync -no-lock ${served}) and be in AllowUsers.";
    }
  ];
}
