# This host's one PostgreSQL server. A service module only adds a database and its same-named owner role
# (services.postgresql.ensureDatabases and ensureUsers) and orders itself after postgresql.target. The server has no
# TCP listener and admits, by peer over /run/postgresql, its superuser, each database's own role and each
# homelab.postgresql.clients role, which only the system users its pg_ident map names may log in as.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pg = config.services.postgresql;
  clients = config.homelab.postgresql.clients;
  rules = [
    "local all postgres peer"
  ]
  ++ map (db: "local ${db} ${db} peer") pg.ensureDatabases
  ++ lib.mapAttrsToList (role: c: "local ${c.database} ${role} peer map=${role}") clients;
  ident = lib.concatLists (
    lib.mapAttrsToList (role: c: map (user: "${role} ${user} ${role}") c.users) clients
  );
  owners = map (u: u.name) (lib.filter (u: u.ensureDBOwnership) pg.ensureUsers);
  roles = lib.filter (n: n != "postgres" && !(lib.hasAttr n clients)) (
    map (u: u.name) pg.ensureUsers
  );
in
{
  options.homelab.postgresql.clients = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          database = lib.mkOption {
            type = lib.types.str;
            description = "The one database the role may log in to.";
          };
          users = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "The system users that may log in as the role, by peer.";
          };
        };
      }
    );
    default = { };
    description = "Login roles with no database of their own, for system users other than their namesake. What a role may do is the GRANTs its database's migration makes.";
  };

  config.services.postgresql = {
    enable = true;
    # the major the data directory was initialised at: an upgrade is its own change
    package = pkgs.postgresql_16;
    enableTCPIP = false;
    # mkForce: upstream's default without enableTCPIP still listens on localhost
    settings.listen_addresses = lib.mkForce "";
    # mkForce: upstream's default rules allow every local role and loopback TCP; a module adds a database instead
    authentication = lib.mkForce (lib.concatMapStrings (l: l + "\n") rules);
    # mkForce: upstream maps postgres to itself, which no rule above uses
    identMap = lib.mkForce (lib.concatMapStrings (l: l + "\n") ident);
    ensureUsers = lib.mapAttrsToList (name: _: { inherit name; }) clients;
  };
  config.systemd.services.postgresql.serviceConfig = {
    MemoryMax = "512M";
    MemorySwapMax = 0;
    OOMScoreAdjust = -300;
  };

  config.assertions = [
    {
      assertion = lib.versions.major pg.package.version == "16" && pg.dataDir == "/var/lib/postgresql/16";
      message = "modules/homelab/postgresql.nix: Postgres is ${pg.package.version} on ${pg.dataDir}, but the data directory is major 16 at /var/lib/postgresql/16. Upgrade the data (dump and restore, or pg_upgrade) as its own change, then move this pin and authentik-offhost.nix's pg_restore.";
    }
    {
      assertion =
        !pg.enableTCPIP
        && pg.settings.listen_addresses == ""
        && lib.filter (l: l != "") (lib.splitString "\n" pg.authentication) == rules;
      message = "modules/homelab/postgresql.nix: Postgres must have no TCP listener and admit only postgres, each database's own role and each homelab.postgresql.clients role, by peer.";
    }
    {
      assertion =
        lib.all (db: lib.elem db owners) pg.ensureDatabases
        && lib.all (r: lib.elem r pg.ensureDatabases) roles;
      message = "modules/homelab/postgresql.nix: every database in ensureDatabases needs an ensureUsers entry of the same name with ensureDBOwnership, and every role a database of its name: the peer rules admit only those pairs.";
    }
    {
      assertion = lib.all (
        role:
        lib.elem clients.${role}.database pg.ensureDatabases
        && clients.${role}.users != [ ]
        && !(lib.elem role (pg.ensureDatabases ++ [ "postgres" ]))
      ) (lib.attrNames clients);
      message = "modules/homelab/postgresql.nix: a homelab.postgresql.clients role needs an ensureDatabases database and at least one user, and is never postgres or a database's owner: its users would get the owner's rights.";
    }
  ];
}
