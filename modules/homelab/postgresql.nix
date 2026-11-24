# This host's one PostgreSQL server. A service module only adds a database and its same-named owner role
# (services.postgresql.ensureDatabases and ensureUsers) and orders itself after postgresql.target. The server has no
# TCP listener and admits, by peer over /run/postgresql, its superuser and each database's own role alone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pg = config.services.postgresql;
  rules = [ "local all postgres peer" ] ++ map (db: "local ${db} ${db} peer") pg.ensureDatabases;
  owners = map (u: u.name) (lib.filter (u: u.ensureDBOwnership) pg.ensureUsers);
  roles = lib.filter (n: n != "postgres") (map (u: u.name) pg.ensureUsers);
in
{
  services.postgresql = {
    enable = true;
    # the major the data directory was initialised at: an upgrade is its own change
    package = pkgs.postgresql_16;
    enableTCPIP = false;
    # mkForce: upstream's default without enableTCPIP still listens on localhost
    settings.listen_addresses = lib.mkForce "";
    # mkForce: upstream's default rules allow every local role and loopback TCP; a module adds a database instead
    authentication = lib.mkForce (lib.concatMapStrings (l: l + "\n") rules);
  };
  systemd.services.postgresql.serviceConfig = {
    MemoryMax = "512M";
    MemorySwapMax = 0;
    OOMScoreAdjust = -300;
  };

  assertions = [
    {
      assertion = lib.versions.major pg.package.version == "16" && pg.dataDir == "/var/lib/postgresql/16";
      message = "modules/homelab/postgresql.nix: Postgres is ${pg.package.version} on ${pg.dataDir}, but the data directory is major 16 at /var/lib/postgresql/16. Upgrade the data (dump and restore, or pg_upgrade) as its own change, then move this pin and authentik-offhost.nix's pg_restore.";
    }
    {
      assertion =
        !pg.enableTCPIP
        && pg.settings.listen_addresses == ""
        && lib.filter (l: l != "") (lib.splitString "\n" pg.authentication) == rules;
      message = "modules/homelab/postgresql.nix: Postgres must have no TCP listener and admit only postgres and each database's own role, by peer.";
    }
    {
      assertion =
        lib.all (db: lib.elem db owners) pg.ensureDatabases
        && lib.all (r: lib.elem r pg.ensureDatabases) roles;
      message = "modules/homelab/postgresql.nix: every database in ensureDatabases needs an ensureUsers entry of the same name with ensureDBOwnership, and every role a database of its name: the peer rules admit only those pairs.";
    }
  ];
}
