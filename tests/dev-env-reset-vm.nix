# dev-env-reset@<name> on one environment in QEMU: it refuses while a clone holds uncommitted work and while an agent
# process runs, and otherwise leaves a fresh home with the old one in .trash and the container running again.
# The runtime-host role's closure plus a guest: `nix build .#dev-env-reset-vm` on msi only.
{
  pkgs,
  roleModules,
  fleetModules,
  roles,
}:
pkgs.testers.runNixOSTest {
  name = "dev-env-reset";
  # The fleet's modules set nixpkgs.overlays, which read-only pkgs refuses.
  node.pkgsReadOnly = false;

  nodes.machine =
    { lib, ... }:
    {
      imports = roleModules ++ fleetModules;
      sam.profile = {
        username = "lukas";
        hostname = "msi-ms7758";
        inherit roles;
        nativeOtel = false;
      };
      sam.hostSecrets.enable = lib.mkForce false;
      systemd.services.systemd-time-wait-sync.wantedBy = lib.mkForce [ ];
      sam.workers.instances.t.agent = "none";
      sam.workers.pool.memory = "3G";
      virtualisation.memorySize = 4096;
      # a VM has no client key for the guest to bind (the hosts have lukas's own)
      systemd.services.stub-client-key = {
        before = [ "container@t.service" ];
        requiredBy = [ "container@t.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 -o lukas -g users /home/lukas/.ssh
          [ -e /home/lukas/.ssh/id_ed25519 ] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /home/lukas/.ssh/id_ed25519
          chown lukas:users /home/lukas/.ssh/id_ed25519 /home/lukas/.ssh/id_ed25519.pub
        '';
      };
    };

  testScript = ''
    home = "/var/lib/workers/t/home"
    guest = "nixos-container run t -- runuser -u lukas -- "

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("container@t.service")
    machine.succeed(f"touch {home}/marker")

    machine.succeed(guest + "bash -c '${pkgs.git}/bin/git init -q ~/r && touch ~/r/x'")
    rc, out = machine.execute("systemctl start dev-env-reset@t.service")
    jl = machine.succeed("journalctl -u dev-env-reset@t.service -o cat --no-pager")
    print(jl)
    assert rc != 0 and "uncommitted changes" in jl, "a dirty clone did not stop the reset"
    machine.succeed(f"test -e {home}/marker")
    machine.succeed(guest + "rm -rf /home/lukas/r")

    machine.succeed(guest + "bash -c 'cd ~ && ${pkgs.git}/bin/git init -q -b main d && cd d && ${pkgs.git}/bin/git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a && ${pkgs.git}/bin/git checkout -q --detach && ${pkgs.git}/bin/git -c user.name=t -c user.email=t@t commit -q --allow-empty -m b && ${pkgs.git}/bin/git branch -q -D main'")
    rc, out = machine.execute("systemctl start dev-env-reset@t.service")
    jl = machine.succeed("journalctl -u dev-env-reset@t.service -o cat --no-pager")
    assert rc != 0 and "commits on no remote" in jl, "a commit on a detached HEAD did not stop the reset"
    machine.succeed(guest + "rm -rf /home/lukas/d")

    # as an agent runs: started by the guest's systemd, so in the container unit's cgroup (nixos-container run is not)
    machine.succeed("systemd-run -M t --uid=lukas --unit=fake-agent -- ${pkgs.bash}/bin/bash -c 'exec -a claude ${pkgs.bash}/bin/bash -c \"${pkgs.coreutils}/bin/sleep 600; true\"'")
    machine.wait_until_succeeds("systemctl -M t is-active fake-agent.service")
    rc, out = machine.execute("systemctl start dev-env-reset@t.service")
    jl = machine.succeed("journalctl -u dev-env-reset@t.service -o cat --no-pager")
    assert rc != 0 and "an agent is running" in jl, "a running agent did not stop the reset"
    machine.succeed(f"test -e {home}/marker")
    machine.succeed("systemctl -M t stop fake-agent.service")

    machine.succeed("systemctl start dev-env-reset@t.service")
    machine.succeed(f"test ! -e {home}/marker && test -d {home}")
    machine.succeed("ls /var/lib/workers/.trash | grep -q '^t-'")
    machine.succeed("test -e $(ls -d /var/lib/workers/.trash/t-* | head -n 1)/home/marker")
    machine.succeed("systemctl is-active container@t.service")
  '';
}
