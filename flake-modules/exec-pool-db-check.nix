# acer's queue PostgreSQL for msi's runner (homelab.execPool.remoteRunners), evaluated only: off, no TCP and no host
# rule; on, one scram rule for msi's address and the exec_pool_runner role, bound to acer's fleet address at the
# exec-pool-db listener's port, which acer's firewall admits from msi alone; each wrong remote role fails its assertion.
{ config, lib, ... }:
let
  acer = config.flake.nixosConfigurations.acer-swift;
  seed = module: (acer.extendModules { modules = [ module ]; }).config;
  failing = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  prefix = "modules/homelab/postgresql.nix: homelab.postgresql.remoteClients";
  expectFailure =
    name: c:
    lib.assertMsg (lib.any (lib.hasPrefix prefix) (failing c)) "exec-pool-db-check: ${name} passes";
  hostRules =
    c: lib.filter (lib.hasPrefix "host") (lib.splitString "\n" c.services.postgresql.authentication);
  inherit (acer.config.sam.fleet) hosts listeners;
  l = listeners.exec-pool-db;
  off = acer.config;
  on = seed { homelab.execPool.remoteRunners = true; };
  remote = role: listener: {
    homelab.postgresql.remoteClients.${role} = {
      database = "exec_pool";
      inherit listener;
    };
  };
  fw = on.networking.firewall;
  admits =
    a: lib.hasInfix "-s ${a} -p tcp --dport ${toString l.port} -j nixos-fw-accept" fw.extraCommands;
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        exec-pool-db-acer-swift = pkgs.writeText "exec-pool-db-acer-swift" (
          assert lib.assertMsg (
            l.host == "acer-swift" && l.from == [ "msi-ms7758" ]
          ) "exec-pool-db-check: the listener is ${builtins.toJSON l}";
          assert lib.assertMsg (
            !off.services.postgresql.enableTCPIP
            && off.services.postgresql.settings.listen_addresses == ""
            && hostRules off == [ ]
          ) "exec-pool-db-check: acer's Postgres listens on TCP with remoteRunners off";
          assert lib.assertMsg (
            failing on == [ ]
          ) "exec-pool-db-check: the seeded acer fails ${toString (failing on)}";
          assert lib.assertMsg
            (
              on.services.postgresql.settings.listen_addresses == hosts.acer-swift.address
              && on.services.postgresql.settings.port == l.port
            )
            "exec-pool-db-check: Postgres binds ${on.services.postgresql.settings.listen_addresses}:${toString on.services.postgresql.settings.port}";
          assert lib.assertMsg (
            hostRules on == [
              "host exec_pool exec_pool_runner ${hosts.msi-ms7758.address}/32 scram-sha-256"
            ]
          ) "exec-pool-db-check: the host rules are ${builtins.toJSON (hostRules on)}";
          assert lib.assertMsg (lib.any (u: u.name == "exec_pool_runner" && !(u.ensureDBOwnership or false))
            on.services.postgresql.ensureUsers
          ) "exec-pool-db-check: no exec_pool_runner role without ownership";
          assert lib.assertMsg (
            admits hosts.msi-ms7758.address
            && !admits hosts.lenovo-21CB001PMX.address
            && !admits on.sam.fleet.lanCidr
            && !lib.elem l.port fw.allowedTCPPorts
          ) "exec-pool-db-check: acer's firewall admits port ${toString l.port} beyond msi";
          assert expectFailure "a listener on msi" (seed (remote "exec_pool_runner" "ollama-msi"));
          assert expectFailure "a listener fleet.nix lacks" (seed (remote "exec_pool_runner" "nope"));
          assert expectFailure "the owner role remote" (seed (remote "exec_pool" "exec-pool-db"));
          assert expectFailure "a peer client remote" (seed (remote "exec_pool_submit" "exec-pool-db"));
          assert expectFailure "a database acer lacks" (seed {
            homelab.postgresql.remoteClients.exec_pool_runner = {
              database = "nope";
              listener = "exec-pool-db";
            };
          });
          assert expectFailure "two listeners" (
            seed (
              lib.recursiveUpdate (remote "exec_pool_runner" "exec-pool-db") (remote "other_runner" "gateway-api")
            )
          );
          assert lib.assertMsg (
            on.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" == 1
            && !(off.boot.kernel.sysctl ? "net.ipv4.ip_nonlocal_bind")
          ) "exec-pool-db-check: Postgres's fleet-address bind does not survive a boot before the address";
          "${toString (hostRules on)}"
        );
      };
    };
}
