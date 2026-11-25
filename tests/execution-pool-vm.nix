# homelab.execPool's slots on in QEMU beside a named environment: two idle slots boot, a slot is used, released by
# dev-env-reset@ and used again without a switch, stops and restarts alone, and sees no host secret or socket.
# Both slots under slot.privateUsers (msi's); the named instance keeps the host's ids, as acer's slots do.
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
        pool.memory = "3G";
      };
      homelab.execPool = {
        enable = true;
        slots = 2;
        slot.memory = "512M";
        slot.privateUsers = true;
      };
      # a stand-in gh login, so the GitHub sidecar starts: the test reaches it, never GitHub
      sam.workers.ghHostsFile = "/var/lib/stub-gh/hosts.yml";
      systemd.services.stub-gh-hosts = {
        before = [ "dev-env-egress.service" ];
        requiredBy = [ "dev-env-egress.service" ];
        serviceConfig.Type = "oneshot";
        # once: dev-env-egress-gh.path restarts the proxy, and so this, at every change of the file
        script = ''
          [ -e /var/lib/stub-gh/hosts.yml ] && exit 0
          install -d -m 0700 -o lukas -g users /var/lib/stub-gh
          printf 'github.com:\n    oauth_token: stub\n' > /var/lib/stub-gh/hosts.yml
          chown lukas:users /var/lib/stub-gh/hosts.yml
        '';
      };
      virtualisation.memorySize = 5120;
      # the store on the disk image's ext4, as on the hosts: privateUsers binds it id-mapped, which 9p and overlayfs
      # refuse ("Failed to clone /nix/store")
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      # no sops here: the GitHub sidecar's InaccessiblePaths names it
      systemd.tmpfiles.rules = [ "d /run/secrets.d 0751 root root -" ];
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

    # each slot in its own ids (slot.privateUsers), the named instance in the host's: guest root and the slot user are
    # unprivileged host uids, and the binds, the dock, the GitHub sidecar and the nix daemon still work for its user
    bases = {n: int(machine.succeed(f"cat /var/lib/workers/{n}/.id-base")) for n in ("pool1", "pool2", "t")}
    base = bases["pool1"]
    assert bases["t"] == 0 and len({base, bases["pool2"]}) == 2 and min(base, bases["pool2"]) >= 0x70000000, f"id blocks: {bases}"
    for n in ("pool1", "pool2", "t"):
        leader = machine.succeed(f"machinectl show -P Leader {n}").strip()
        got = " ".join(machine.succeed(f"cat /proc/{leader}/uid_map").split())
        owner = int(machine.succeed(f"stat -c %u /proc/{leader}").strip())
        want = f"0 {bases[n]} 65536" if bases[n] else "0 0 4294967295"
        assert got == want and owner == bases[n], f"{n}: guest root is host uid {owner}, uid_map {got}"
    assert machine.succeed(f"stat -c %u:%g {home}").strip() == f"{base + 1000}:{base + 100}", "pool1's home is not its user's"
    machine.succeed(guest + "sh -c 'test \"$(id -u)\" = 1000 && touch ~/.probe ~/.cache/nix/probe && rm ~/.probe ~/.cache/nix/probe'")
    machine.fail(guest + "touch /var/lib/host-credentials/x")
    machine.fail("nixos-container run pool1 -- test -e /run/wrappers/bin/sudo")

    # the nix daemon serves pool1's user (allowed-users names it vu-pool1-1000), a store write included
    machine.succeed(guest + "sh -c 'echo probe > /tmp/p && nix-store --add /tmp/p'")
    machine.succeed("nixos-container run t -- runuser -u lukas -- nix store ping")

    # the dock as the runner makes it: root's cur, home and work the slot home's owner's
    dock = "/var/lib/workers/.sessions/dock/pool1/cur"
    machine.succeed(f"install -d -m 0711 {dock} && install -d -m 0700 -o {base + 1000} -g {base + 100} {dock}/home {dock}/work")
    machine.succeed(guest + "sh -c 'touch /session/cur/home/x /session/cur/work/y'")
    machine.fail(guest + "touch /session/cur/z")
    machine.succeed(f"test \"$(stat -c %u {dock}/work/y)\" = {base + 1000} && rm -r {dock}")

    # the GitHub sidecar's socket through the read-only idmapped /run/egress: any HTTP answer, never GitHub's
    machine.wait_for_unit("dev-env-egress.service")
    for n in ("pool1", "pool2"):
        code = machine.succeed(
            f"nixos-container run {n} -- runuser -u lukas -- ${pkgs.curl}/bin/curl -s -o /dev/null -w %{{http_code}} http://127.0.0.1:4102/not-a-listed-repo/info/refs"
        ).strip()
        assert code not in ("", "000"), f"{n} cannot reach the GitHub sidecar: {code}"

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
    # boot, the reset, this start and the next restart are four starts in the core's 10 minutes, but the reset cleared the
    # count: only the fourth after it, a hand restart, is refused until reset-failed
    machine.succeed("systemctl restart container@pool1.service")
    rc, out = machine.execute("systemctl restart container@pool1.service 2>&1")
    assert rc != 0 and "too often" in out, f"a fourth start since the reset was not refused: {out}"
    machine.succeed("systemctl reset-failed container@pool1.service && systemctl start container@pool1.service")
    machine.wait_for_unit("container@pool1.service")
    machine.wait_until_succeeds(guest + "true")
    assert inventory()["pool1"]["state"] == "active", "the restarted slot reads active"

    # a home made in the other block (privateUsers toggled on a running pool): the next start resets it, not refuses
    machine.succeed("systemctl stop container@pool1.service")
    machine.succeed(f"echo 0 > /var/lib/workers/pool1/.id-base && touch {home}/old")
    machine.succeed("systemctl reset-failed container@pool1.service; systemctl start container@pool1.service")
    machine.wait_until_succeeds(guest + "true")
    machine.succeed(f"test ! -e {home}/old && test \"$(cat /var/lib/workers/pool1/.id-base)\" = {base}")
    machine.succeed(guest + "touch /home/lukas/new")

    assert t_invocation() == named, "a slot's reset, stop or restart restarted the named environment"
    assert machine.succeed("readlink /run/current-system") == generation, "the host's generation changed"
  '';
}
