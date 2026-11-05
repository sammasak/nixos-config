# Agent runtime: nspawn proof and enforcement (#135, #137)

The M0 proof (#135) and the M1 enforcement (#137: capabilities, fixed-size
volumes, admission, fail-closed start) for the ephemeral nspawn agent runtime
([epic #133](https://github.com/sammasak/nixos-config/issues/133)) lives in
`tests/agent-runtime-nspawn.nix`, exposed as
`packages.x86_64-linux.agent-runtime-nspawn` by
`flake-modules/55-agent-runtime-test.nix`. It is a QEMU `nixosTest`: nothing
in it touches a live host, and `nix flake check` only evaluates it. Build it on
acer under the heavy-work lock:

```sh
flock /tmp/$(hostname)-heavy-work.lock nix build -L .#packages.x86_64-linux.agent-runtime-nspawn
```

Passing it is not permission to deploy and is not the MVP; the epic's MVP
definition of done still applies.

## What the fixture declares

Two templates and one host policy, declared through the typed module
(`sam.agentRuntime`, `docs/agent-runtime.md`) and evaluated with
`flake.lib.agentRuntime`'s `evalManifests`. Each template gets its own factory
script; the factories share one admission state. A factory reads its mounts,
budgets and sources from the evaluated manifest, binds the manifest read-only at
`/etc/agent-runtime/template.json`, and the export compares the exported copy
byte for byte with the manifest.

| | `rust-worker-m0` | `tiny` |
|---|---|---|
| repository | `rf-proto`: `sammasak/rf-proto`, `ref.type = commit`, `lock` = the pinned flake input (`flake.lock`), read-only at `/src/rf-proto`, copied into `/workspace/rf-proto` | none |
| skill | `rust-engineering` (pinned `skills` input), read-only at `/skills/rust-engineering` | `lean-code` |
| packages | bash, coreutils, findutils, gnugrep, gnused, gawk, diffutils, util-linux, glibc.bin, cargo, rustc, gcc (one `buildEnv`) | bash, coreutils |
| writable volumes (MiB / inodes) | workspace 256/20000, home 64/5000, tmp 128/20000, cache 128/20000, output 32/1000 = 608 MiB | 16/1000 each = 80 MiB |
| resources | `cpus = 1`, `memoryMiB = 512`, `tasksMax = 512` | 1, 64, 64 |

Host policy: `maxConcurrentInstances = 3`, `reserve = { memoryMiB = 2600; diskMiB = 512; }`
(sized against the 4 GiB, 4 GiB-disk test VM so that two rust instances fit
and a third does not).

`pkgs.closureInfo` over the environment, the source and the skill gives the
closure the instance needs; the fixture mounts the whole host store read-only
(see the limitations below for why that is a confidentiality finding, not a
boundary). The fixture copies the locked source itself; driving
`agent-runtime-assign`/`materialize`/`export` (#136) from the factory is the
lifecycle adapter's job (#138).

## NixOS `containers.<name>` or a unit factory

The question in #135 was whether an evaluated `nixosSystem` container `path` is
the right vehicle for dynamic ephemeral instances. On the pinned nixpkgs
(`nixos/modules/virtualisation/nixos-containers.nix`):

- a declarative `containers.<name>` entry becomes a `container@<name>.service`
  instance with its config under `/etc/nixos-containers/<name>.conf`, written by
  the host's system activation, so adding or renaming an instance is a host
  switch;
- `nixos-container create` (the imperative path) writes the same config file
  plus `/var/lib/nixos-containers/<name>` and a per-container Nix profile, which
  is persistent state with its own GC roots;
- both boot a full NixOS inside (`--boot`, stage-2, systemd as PID 1), and bind
  `/nix/var/nix/db` and, with `nix.enable`, the host daemon socket.

None of that is wanted for an instance that exists for one assignment: no host
switch, no persistent per-instance directory, no init system, no daemon socket.
The fixture therefore uses the smallest explicit factory instead, the same
primitives the NixOS module wraps, without its persistence. The effective
command, as the factory printed it in the passing run:

```
systemd-run --unit=agent-runtime-<id> --wait --pipe --collect \
  -p MemoryMax=512M -p MemorySwapMax=0 -p TasksMax=512 -p CPUQuota=100% -p KillMode=mixed \
  --setenv=SYSTEMD_LOG_TARGET=journal \
  systemd-nspawn --quiet --keep-unit --settings=no --register=yes -M agent-runtime-<id> -D /run/agent-runtime/<id>/root \
    --private-users=<base>:65536 --private-users-ownership=chown \
    --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes \
    --drop-capability=<nspawn's default set minus CAP_SETUID,CAP_SETGID,CAP_SETPCAP> \
    --bind-ro=/nix/store:/nix/store[:idmap] \
    --bind-ro=<rf-proto store path>:/src/rf-proto[:idmap] \
    --bind-ro=<skills store path>/skills/rust-engineering:/skills/rust-engineering[:idmap] \
    --bind-ro=<manifest>:/etc/agent-runtime/template.json \
    --bind=/var/lib/agent-runtime/<id>/mnt/{cache,home,output,tmp,workspace}:<their paths> \
    /bin/sh -c "exec setpriv --reuid=<uid> --regid=<uid> --clear-groups --bounding-set=-all --inh-caps=-all --no-new-privs \
      /bin/sh -c '<script> > /tmp/run.log 2>&1'"
```

### create: admission, UID range, volumes

Under one host-wide lock, `create`:

1. refuses an id that is not a DNS label, or is `exports` (exit 64);
2. admits the instance against the host policy, or refuses with exit 75 and the
   reason: live instances against `maxConcurrentInstances`; the sum of live
   reservations' `memoryMiB` plus this one against `MemTotal - reserve.memoryMiB`;
   this instance's volume total plus `reserve.diskMiB` against the free space of
   `/var/lib/agent-runtime` (already-created instances' images are allocated, so
   free space accounts for them);
3. takes the first of 64 UID ranges of 65536 IDs from host UID 1048576 that no
   reservation holds;
4. writes `/var/lib/agent-runtime/<id>/reservation` (`memoryMiB diskMiB uidbase template`)
   before anything else, then creates one `fallocate`d image per volume,
   `mkfs.ext4 -m 0 -N <inodes> -E nodiscard,root_owner=<mapped owner>` (nodiscard:
   the default discard would punch the allocation back out of the file), and
   loop-mounts it `nosuid,nodev` under `mnt/<volume>`; `tmp` is 1777 and owned
   by the mapped root, the rest 0700/0755 and owned by the mapped agent;
5. builds the root tree (a few directories, `etc/{os-release,passwd,group,nsswitch.conf}`,
   two symlinks). Any failure after the reservation rolls the instance back.

`destroy` takes the same lock, stops the unit, unmounts every volume, removes
the images and the root tree, and removes the reservation last: a teardown that
fails (a busy mount) leaves the instance counted, and a second `destroy`
finishes it. `check-clean` asserts no mount, loop device, unit, machine, nspawn
process or directory carries the id.

### Capabilities

nspawn has no "drop all", and the payload has to switch to `agent` inside. The
factory drops every capability of nspawn's default set except `CAP_SETUID`,
`CAP_SETGID` and `CAP_SETPCAP`; `setpriv` then empties the bounding and
inheritable sets and sets no-new-privileges before it executes the payload, so
the payload, as `agent` or as container root, has every capability set at 0.
Container root without `CAP_DAC_OVERRIDE` cannot write the agent's volumes, so
the run log lives on the 1777 `tmp` volume. nspawn's stub init (PID 1 in the
container) keeps the three capabilities.

This is the shape #138 should grow into (idempotent operations keyed by the
instance id, transient unit per instance); it is not yet that adapter.

## What the test proves

1. **Ids**: `exports`, `../x`, `A` and `-x` are refused.
2. **Idle instance**: create (five volumes), run `true`, stop, destroy: the
   runtime's own cost. `:idmap` on the store bind is tried first; the refused
   start keeps the reservation, and the fallback used is recorded.
3. **Probe as container root**: records `/proc/self/ns/*`, uid and gid maps,
   cgroup, capability sets, the full mountinfo, devices and interfaces, and the
   host records its own namespaces, maps and mountinfo. Asserted: only the
   `time` namespace is shared with the host; root maps to a non-root host range;
   `CapInh`, `CapPrm`, `CapEff`, `CapBnd` and `CapAmb` are 0, `NoNewPrivs` 1,
   `Seccomp` 2; a host process cannot be signalled; a host SysV segment is
   invisible; `hostname`, `mount -t tmpfs`, `remount,rw` of `/nix/store`,
   `/src/rf-proto` and `/`, `mknod`, writing `/proc/sys` and `/sys`, reading
   `/proc/kcore` and writing the agent's workspace are denied; writes to the
   store, the environment, the source and the skill are denied; the Nix daemon
   socket, the systemd private socket, a Docker socket, host sentinels in
   `/root` and `/home` and `SSH_AUTH_SOCK` are absent; only `lo` exists.
4. **Cold and warm**, each a fresh instance: as `agent` (capabilities 0,
   asserted), write HOME, cache and TMP, copy the pinned source, `cargo test
   --offline` (rf-proto's real suite), export the test binary and the manifest
   with `SHA256SUMS`; the host verifies the sums, compares the manifest,
   destroys and checks clean.
5. **Two concurrent instances**: both in `machinectl`; distinct host UIDs for
   guest UID 1000; every namespace but `time` distinct; each sees only its own
   workspace marker, only its own SysV segment, and cannot signal the other's
   leader PID.
6. **Admission**: with two rust instances live, a third is refused for memory;
   a `tiny` instance is admitted and a fourth instance is refused for the
   instance count; with a ballast file leaving 612 MiB free, a rust instance
   (608 + 512 reserve) is refused for disk while a `tiny` one (80 + 512) is
   admitted. Refused creates leave nothing behind; the reservations return to
   zero.
7. **Fail closed**: with `user.max_user_namespaces = 0` the start fails
   (`Failed to fork inner child: No space left on device`), the payload never
   runs, and the reservation stays until `destroy`.
8. **Failed teardown**: a host process holding the workspace mount makes
   `destroy` fail; the reservation is still counted; after the holder stops, a
   second `destroy` releases it.
9. **tasksMax**: a fork bomb (`xargs -P 0` of 712 sleeps) is held at
   `pids.current = pids.max = 512`, the kernel counts the `max` event, the
   instance ends on its own.
10. **memoryMiB**: a memory hog is OOM-killed inside the unit's cgroup
    (`Finished with result: oom-kill`).
11. **cpus**: three busy loops for 5 s get one core: CPU time 5.136 s over a
    5.139 s runtime on the two-core VM.
12. **Bytes and inodes**: `dd` into the workspace stops at `No space left on
    device`, `touch` in HOME stops at 4992 of 4992 inodes; the host's free disk
    is the same before and after.
13. **Host unchanged**: store entry count and mtime, sentinels, no mount, loop
    device, machine or unit left, `/var/lib/agent-runtime` holds only `exports`,
    host free disk back within 16 MiB of the start.

## Observed on acer (QEMU, 2026-11-05)

Versions: kernel 6.18.56 (the test VM's), systemd 261 (261.3), nixpkgs
26.11pre-git (`fe13242`), rf-proto `d878c58`, skills `9284403`. The raw log is
in the PR.

- `uid_map`/`gid_map`: `0 1048576 65536` for the first instance; concurrent
  instances get distinct ranges (agent = host UID 1049576 and 1115112).
- Namespaces shared with the host: `time` only (nspawn does not unshare it).
- `:idmap` on the store bind is refused: nspawn exits 1 before the payload
  (`Failed to clone /nix/store: Invalid argument`). The VM's store is an
  overlay over virtiofs, which has no idmapped-mount support, so the run used
  a plain read-only bind and the store shows as `65534:65534 dr-xr-xr-x`. On
  an ext4 host store the NixOS containers module uses `:idmap`; that is
  expected, not proven here.
- A nested user namespace can be created from inside but its `uid_map` cannot
  be written (`unshare --user --map-root-user`: `write failed
  /proc/self/uid_map: Operation not permitted`); see the limitations.
- `/dev`: char console core fd full fuse mqueue net null ptmx pts random shm
  stderr stdin stdout tty urandom zero.
- The OOM kill names the mapped agent's host UID and nothing outside the
  cgroup.

| run | create | startup | work | total | memory peak | CPU | instance disk | teardown |
|---|---|---|---|---|---|---|---|---|
| idle (`true`) | 269 ms | | | 340 ms | 4 MiB | | 367 B | 159 ms |
| cold (`cargo test`) | 264 ms | 401 ms | 3241 ms | 3669 ms | 375.3 MiB | 3.22 s | 22.9 MB | 220 ms |
| warm (`cargo test`) | 263 ms | 390 ms | 2694 ms | 3113 ms | 118.1 MiB | 2.74 s | 22.9 MB | 219 ms |
| tasksMax bomb | | | | | | | | 158 ms |
| memoryMiB hog | | | | | 512 MiB (the ceiling) | | | 155 ms |

Create is the five volumes (allocate, mkfs, mount) and the root tree; startup
is host `create` to the workload's first line; work is the workload's own
marks; total adds the unit's exit. With `cpus = 1` the cargo run is slower than
the two-core M0 numbers (2.0 s / 1.7 s). The cold peak counts the page cache
the first read of the toolchain charged to the cgroup. Instance disk is what
the volumes and root tree hold before `destroy`; the reservation is the full
608 MiB, allocated up front. The required closure is 80 store paths, 2.2 GB
NAR, shared read-only, never copied. The export is 1.99 MB. Teardown is
`destroy` alone (five unmounts, image removal).

Fixture findings worth keeping:

- `systemd-run --wait` with `RemainAfterExit=yes` never returns (the unit stays
  active), so the factory reads the memory peak from systemd-run's summary.
- A failed transient unit keeps its name until `reset-failed` or `--collect`,
  so the factory does both.
- nspawn's own errors arrive as empty lines through `systemd-run --pipe`, so
  the unit runs with `SYSTEMD_LOG_TARGET=journal` and a failed run prints the
  unit's journal; the payload logs into the instance and the factory prints it.
- Stopping a running instance from the host (`systemctl stop`) left the
  backgrounded `systemd-run --wait` client running past 60 s; every instance in
  the passing run ends on its own. #138's timeout path has to bound the client,
  not only the unit.
- nixpkgs' test instrumentation sets `vm.panic_on_oom = 2`, which turns a
  cgroup OOM into a kernel panic; the test node sets the kernel's 0. A host
  that sets 2 cannot run memory-bounded instances safely.
- nspawn appends its own `uid=`/`gid=` to `--tmpfs` options, so a tmpfs cannot
  be handed to `agent` from outside; the ext4 volumes are created with the
  mapped owner instead.
- Bash `$((65536 * x % 64))` is `(65536 * x) % 64 = 0`: an earlier fixture
  gave every instance UID base 1048576. Allocation is explicit.

## Security limitations

1. nspawn is a shared-kernel boundary. Container root maps to an unprivileged
   host UID range, but a kernel vulnerability reachable from the container is a
   host vulnerability, and the `time` namespace is shared. Nested user
   namespaces can be created (their maps cannot be written, but creation alone
   reaches more kernel code). Approved repositories only; not for hostile code.
2. The whole host `/nix/store` is visible read-only. Every closure on the host,
   including configuration that embeds material it should not, is readable from
   the instance; read-only is not confidential. The instance needs 80 paths
   (`closureInfo` above); a closure-only bind set is the candidate mitigation,
   at the cost of one bind per path or a per-template store view.
3. `remount,rw` and every mount are denied (no `CAP_SYS_ADMIN`, and the binds
   are locked in the user namespace); a bind with `idmap` depends on the backing
   filesystem supporting idmapped mounts (the run records which one it used).
4. Admission compares memory against `MemTotal`, not what other host workloads
   use at the moment, and its state lives in `/var/lib/agent-runtime`: it
   survives a crash, but a crashed instance stays counted until it is destroyed
   (#138 owns recovery). The UID ranges (64 slots) are per host.
5. The volumes bound bytes and inodes per mount; the cgroup bounds memory
   (`MemorySwapMax=0`), tasks and CPU. I/O bandwidth is not bounded.
6. No credentials enter the instance yet (no token, no SSH agent, no HOME from
   the host). Per-run credential injection is #137's next slice, never through
   the store or the manifest.
7. The export is a plain copy out of `/output` before destruction; there is no
   retention policy and no crash recovery (#138, devenv-platform #95).
8. Private network means no network at all. Minimal egress (DNS and TLS to
   approved endpoints) is #137's next slice.
9. `--register=yes` lists the instance in `machinectl` while it runs; that is
   diagnostics, not Herdr visibility (#139).
