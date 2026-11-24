# acer's queue PostgreSQL for msi's runner (homelab.execPool.remoteRunners, on for acer), evaluated only: off, no TCP,
# no host rule and no password unit, but the role migration 0004 grants to; on, the role's password from sops by
# LoadCredential, one scram rule for msi's address and the exec_pool_runner role, bound to acer's fleet address at the
# exec-pool-db listener's port, which acer's firewall admits from msi alone; each wrong remote role fails its assertion.
# msi's runner logs in there with the same password and claims no lease that would outlive its 21:00 poweroff.
{ config, lib, ... }:
let
  acer = config.flake.nixosConfigurations.acer-swift;
  seed = module: (acer.extendModules { modules = [ module ]; }).config;
  # acer with remoteRunners off: its exec_pool_runner declared but disabled, beside a seeded wrong role
  bare =
    module:
    seed {
      imports = [ module ];
      homelab.execPool.remoteRunners = lib.mkForce false;
    };
  failing = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  prefix = "modules/homelab/postgresql.nix: homelab.postgresql.remoteClients";
  expectFailure =
    name: c:
    lib.assertMsg (lib.any (lib.hasPrefix prefix) (failing c)) "exec-pool-db-check: ${name} passes";
  hostRules =
    c: lib.filter (lib.hasPrefix "host") (lib.splitString "\n" c.services.postgresql.authentication);
  inherit (acer.config.sam.fleet) hosts listeners;
  l = listeners.exec-pool-db;
  off = bare { };
  on = acer.config;
  pw = on.systemd.services.exec-pool-runner-password;
  msi = config.flake.nixosConfigurations.msi-ms7758.config;
  msiRunner = msi.systemd.services.exec-pool-runner-pool1;
  acerRunner = on.systemd.services.exec-pool-runner-pool1;
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
          assert lib.assertMsg
            (
              !off.services.postgresql.enableTCPIP
              && off.services.postgresql.settings.listen_addresses == ""
              && hostRules off == [ ]
              && lib.any (u: u.name == "exec_pool_runner") off.services.postgresql.ensureUsers
            )
            "exec-pool-db-check: acer's Postgres listens on TCP with remoteRunners off, or has no exec_pool_runner for migration 0004 to grant to";
          assert lib.assertMsg (failing on == [ ]) "exec-pool-db-check: acer fails ${toString (failing on)}";
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
          assert lib.assertMsg (
            on.homelab.execPool.remoteRunners
            && !(off.systemd.services ? exec-pool-runner-password)
            && !(off.sops.secrets ? exec_pool_runner_password)
          ) "exec-pool-db-check: the password unit is not on acer alone with remoteRunners";
          assert lib.assertMsg
            (
              baseNameOf (toString on.sops.secrets.exec_pool_runner_password.sopsFile) == "exec-pool-runner.yaml"
              && lib.elem on.sops.secrets.exec_pool_runner_password.owner [
                null
                "root"
              ]
              && on.sops.secrets.exec_pool_runner_password.mode == "0400"
              &&
                pw.serviceConfig.LoadCredential == [
                  "password:${on.sops.secrets.exec_pool_runner_password.path}"
                ]
              && pw.serviceConfig.User == "postgres"
              && lib.elem "postgresql-setup.service" pw.requires
              && lib.elem "postgresql-setup.service" pw.after
              && lib.elem "exec-pool-runner-password.service" on.sops.secrets.exec_pool_runner_password.restartUnits
            )
            "exec-pool-db-check: the role's password is not set from the sops file by LoadCredential after setup";
          assert expectFailure "a listener on msi" (bare (remote "other_runner" "ollama-msi"));
          assert expectFailure "a listener fleet.nix lacks" (bare (remote "other_runner" "nope"));
          assert expectFailure "the owner role remote" (bare (remote "exec_pool" "exec-pool-db"));
          assert expectFailure "a peer client remote" (bare (remote "exec_pool_submit" "exec-pool-db"));
          assert expectFailure "a database acer lacks" (bare {
            homelab.postgresql.remoteClients.other_runner = {
              database = "nope";
              listener = "exec-pool-db";
            };
          });
          assert expectFailure "two listeners" (seed (remote "other_runner" "gateway-api"));
          assert lib.assertMsg (
            on.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" == 1
            && !(off.boot.kernel.sysctl ? "net.ipv4.ip_nonlocal_bind")
          ) "exec-pool-db-check: Postgres's fleet-address bind does not survive a boot before the address";
          assert lib.assertMsg
            (
              msiRunner.environment.EXEC_POOL_DB
              == "host=${hosts.acer-swift.address} port=${toString l.port} dbname=exec_pool user=exec_pool_runner"
              &&
                msiRunner.serviceConfig.LoadCredential == [
                  "db-password:${msi.sops.secrets.exec_pool_runner_password.path}"
                ]
              &&
                baseNameOf (toString msi.sops.secrets.exec_pool_runner_password.sopsFile) == "exec-pool-runner.yaml"
              && !msi.services.postgresql.enable
            )
            "exec-pool-db-check: msi's runner does not reach acer's queue as exec_pool_runner with the sops password";
          # a claim after 20:10 could outlive the 21:00 poweroff
          assert lib.assertMsg (
            msiRunner.environment.EXEC_POOL_OFF_TIMER == "msi-scheduled-shutdown.timer"
            && msi.systemd.timers.msi-scheduled-shutdown.timerConfig.OnCalendar == "Mon-Fri 21:00"
            && msiRunner.environment.EXEC_POOL_CLAIM_SECS == toString (50 * 60)
          ) "exec-pool-db-check: msi's runner does not stop claiming 50 minutes before its 21:00 poweroff";
          assert lib.assertMsg (
            acerRunner.environment.EXEC_POOL_DB == "host=/run/postgresql dbname=exec_pool user=exec_pool"
            && !(acerRunner.environment ? EXEC_POOL_OFF_TIMER || acerRunner.environment ? EXEC_POOL_CLAIM_SECS)
            && !(acerRunner.serviceConfig ? LoadCredential)
            && acerRunner.serviceConfig.PrivateNetwork
          ) "exec-pool-db-check: acer's own runner is not the queue's peer role with no network";
          "${toString (hostRules on)}"
        );
      };
    };
}
