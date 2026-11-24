# sam.workers.executionPool on in QEMU beside a named environment: two idle slots boot, a slot is used, released by
# dev-env-reset@ and used again without a switch, stops and restarts alone, and sees no host secret or socket.
# The runtime-host role's closure plus three guests: `nix build .#execution-pool-vm` on msi only.
{
  pkgs,
  roleModules,
  fleetModules,
  roles,
}:
pkgs.testers.runNixOSTest {
  name = "execution-pool";
  # The fleet's modules set nixpkgs.overlays, which read-only pkgs refuses.
  node.pkgsReadOnly = false;

  nodes.machine =
    { lib, ... }:
    {
      imports = roleModules ++ fleetModules;
      # a name outside sam.fleet, so no fleet host's facts (listeners, power window) apply to the VM
      sam.profile = {
        username = "lukas";
        hostname = "vm-runtime-host";
        inherit roles;
        nativeOtel = false;
      };
      sam.hostSecrets.enable = lib.mkForce false;
      sam.storeCache.enable = lib.mkForce false;
      sam.powerSchedule.poweroff.enable = false;
      systemd.services.systemd-time-wait-sync.wantedBy = lib.mkForce [ ];
      sam.workers = {
        instances.t = {
          agent = "none";
          memory.reserved = "512M";
        };
        executionPool = {
          enable = true;
          slots = 2;
          memory.reserved = "512M";
        };
        pool.memory = "3G";
      };
      virtualisation.memorySize = 5120;
      # a VM has no client key for the named guest to bind (the hosts have lukas's own)
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
    import json

    home = "/var/lib/workers/pool1/home"
    guest = "nixos-container run pool1 -- runuser -u lukas -- "

    def inventory():
        return {s["slot"]: s for s in map(json.loads, machine.succeed("worker-pool-inventory").splitlines())}

    def t_invocation():
        return machine.succeed("systemctl show -P InvocationID container@t.service").strip()

    machine.wait_for_unit("multi-user.target")
    for n in ("t", "pool1", "pool2"):
        machine.wait_for_unit(f"container@{n}.service")
    named = t_invocation()
    generation = machine.succeed("readlink /run/current-system")

    slots = inventory()
    print(slots)
    assert sorted(slots) == ["pool1", "pool2"], f"the inventory lists the two slots alone: {sorted(slots)}"
    for s in slots.values():
        assert s["state"] == "active" and s["closure"].startswith("/nix/store/"), f"an idle slot runs its own closure: {s}"
        assert s["memory"]["min"] == str(512 << 20) and s["slice"] == "environments.slice", f"a slot reserves 512M in the pool's slice: {s}"

    # no host secret, credential or user socket inside a slot: it holds none of the host's credentials
    mounts = machine.succeed("nixos-container run pool1 -- cat /proc/self/mountinfo")
    # the host side of each mount (mountinfo's 4th field): the guest's own /run/credentials tmpfs are its systemd's
    roots = [line.split()[3] for line in mounts.splitlines()]
    host = ("/run/secrets", "/run/credentials", "/run/user", "/run/dev-env-egress", "/home/lukas/.ssh/id_ed25519", "/home/lukas/.config/gh")
    leaked = [r for r in roots if r.startswith(host) and not r.endswith(".pub")]
    assert not leaked, f"pool1 mounts host paths {leaked}"
    machine.succeed("nixos-container run pool1 -- sh -c 'test ! -e /run/secrets && test -z \"$(ls -A /var/lib/host-credentials 2>/dev/null | grep -vx -e ssh_host_ed25519_key -e [^/]*[.]pub)\"'")

    # a task, its release and the next task on the same slot, with no switch in between
    machine.succeed(guest + "bash -c 'echo one > ~/task'")
    machine.succeed("systemctl start dev-env-reset@pool1.service")
    machine.succeed(f"test ! -e {home}/task && test -d {home}")
    machine.succeed("systemctl is-active container@pool1.service")
    machine.wait_until_succeeds(guest + "true")
    assert inventory()["pool1"]["closure"] == slots["pool1"]["closure"], "the reset slot runs another closure"
    machine.succeed(guest + "bash -c 'echo two > ~/task'")
    assert machine.succeed(guest + "cat /home/lukas/task").strip() == "two", "the slot did not take a second task"

    # stop and restart one slot: the other and the named environment keep running
    machine.succeed("systemctl stop container@pool1.service")
    assert inventory()["pool1"]["state"] == "inactive", "a stopped slot reads inactive"
    machine.succeed("systemctl is-active container@pool2.service container@t.service")
    machine.succeed("systemctl start container@pool1.service")
    # boot, the reset and this start are the core's StartLimitBurst of 3: a fourth start in the window is refused
    # until reset-failed, a slot's reuse included
    rc, out = machine.execute("systemctl restart container@pool1.service 2>&1")
    assert rc != 0 and "too often" in out, f"a fourth start within the window was not refused: {out}"
    machine.succeed("systemctl reset-failed container@pool1.service && systemctl start container@pool1.service")
    machine.wait_for_unit("container@pool1.service")
    machine.wait_until_succeeds(guest + "true")
    assert inventory()["pool1"]["state"] == "active", "the restarted slot reads active"

    assert t_invocation() == named, "a slot's reset, stop or restart restarted the named environment"
    assert machine.succeed("readlink /run/current-system") == generation, "the host's generation changed"
  '';
}
