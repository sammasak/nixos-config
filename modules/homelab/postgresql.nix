# This host's one PostgreSQL server. A service module only adds a database and its same-named owner role
# (services.postgresql.ensureDatabases and ensureUsers) and orders itself after postgresql.target. It admits, by peer
# over /run/postgresql, its superuser, each database's own role and each homelab.postgresql.clients role, which only
# the system users its pg_ident map names may log in as. Only with a homelab.postgresql.remoteClients role does it
# listen on TCP: on this host's fleet address at that role's sam.fleet listener, by scram from the listener's callers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pg = config.services.postgresql;
  clients = config.homelab.postgresql.clients;
  declared = config.homelab.postgresql.remoteClients;
  # an off role exists, for its database's grants, with no listener or rule to log in by
  remote = lib.filterAttrs (_: c: c.enable) declared;
  inherit (config.sam.fleet) hosts listeners;
  host = config.networking.hostName;
  # one server, one port: every remote role names the same listener
  listenerNames = lib.unique (lib.mapAttrsToList (_: c: c.listener) remote);
  # a missing one fails the assertion below, not an attribute error
  listener =
    listeners.${lib.head listenerNames} or {
      host = null;
      port = 5432;
      from = [ ];
    };
  tcp = remote != { };
  callers = lib.concatMap (h: [ hosts.${h}.address ] ++ hosts.${h}.extraAddresses) listener.from;
  rules = [
    "local all postgres peer"
  ]
  ++ map (db: "local ${db} ${db} peer") pg.ensureDatabases
  ++ lib.mapAttrsToList (role: c: "local ${c.database} ${role} peer map=${role}") clients
  # scram: a role with no password set cannot log in, so the rule is inert until its credential lands
  ++ lib.concatLists (
    lib.mapAttrsToList (
      role: c: map (a: "host ${c.database} ${role} ${a}/32 scram-sha-256") callers
    ) remote
  );
  ident = lib.concatLists (
    lib.mapAttrsToList (role: c: map (user: "${role} ${user} ${role}") c.users) clients
  );
  owners = map (u: u.name) (lib.filter (u: u.ensureDBOwnership) pg.ensureUsers);
  roles = lib.filter (n: n != "postgres" && !(lib.hasAttr n clients) && !(lib.hasAttr n declared)) (
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
  options.homelab.postgresql.remoteClients = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether its listener's hosts may log in as the role; off, the role still exists, so its database's migrations can grant to it, but has no TCP listener or rule.";
          };
          database = lib.mkOption {
            type = lib.types.str;
            description = "The one database the role may log in to.";
          };
          listener = lib.mkOption {
            type = lib.types.str;
            description = "The sam.fleet listener on this host it connects through; its `from` hosts may log in as the role, by scram-sha-256.";
          };
        };
      }
    );
    default = { };
    description = "Login roles for other fleet hosts, over TCP. Any one turns the TCP listener on; what a role may do is the GRANTs its database's migration makes.";
  };

  config.services.postgresql = {
    enable = true;
    # the major the data directory was initialised at: an upgrade is its own change
    package = pkgs.postgresql_16;
    enableTCPIP = tcp;
    # mkForce: upstream's default without enableTCPIP still listens on localhost, and with it on every address
    settings.listen_addresses = lib.mkForce (if tcp then hosts.${host}.address else "");
    settings.port = lib.mkIf tcp listener.port;
    # mkForce: upstream's default rules allow every local role and loopback TCP; a module adds a database instead
    authentication = lib.mkForce (lib.concatMapStrings (l: l + "\n") rules);
    # mkForce: upstream maps postgres to itself, which no rule above uses
    identMap = lib.mkForce (lib.concatMapStrings (l: l + "\n") ident);
    ensureUsers = lib.mapAttrsToList (name: _: { inherit name; }) (clients // declared);
  };
  # acer's fleet address is Wi-Fi: without it a boot that binds before NetworkManager has it stops Postgres, socket too
  config.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkIf tcp 1;
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
        pg.enableTCPIP == tcp
        && pg.settings.listen_addresses == (if tcp then hosts.${host}.address else "")
        && lib.filter (l: l != "") (lib.splitString "\n" pg.authentication) == rules;
      message = "modules/homelab/postgresql.nix: Postgres must admit only postgres, each database's own role and each homelab.postgresql.clients role, by peer, and listen on TCP only on its fleet address for homelab.postgresql.remoteClients roles, by scram.";
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
    {
      assertion =
        !tcp
        || (
          lib.length listenerNames == 1
          && lib.hasAttr (lib.head listenerNames) listeners
          && listener.host == host
          && listener.from != [ ]
          && lib.all (
            role:
            lib.elem remote.${role}.database pg.ensureDatabases
            && !(lib.elem role (pg.ensureDatabases ++ [ "postgres" ] ++ lib.attrNames clients))
          ) (lib.attrNames remote)
        );
      message = "modules/homelab/postgresql.nix: homelab.postgresql.remoteClients roles name one sam.fleet listener (${toString listenerNames}) served by ${host} with callers, an ensureDatabases database each, and are never postgres, a database's owner or a peer client.";
    }
  ];
}
