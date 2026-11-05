# Agent runtime: M0 nspawn proof (#135)

The M0 proof for the ephemeral nspawn agent runtime
([epic #133](https://github.com/sammasak/nixos-config/issues/133)) lives in
`tests/agent-runtime-nspawn.nix`, exposed as
`packages.x86_64-linux.agent-runtime-nspawn` by
`flake-modules/55-agent-runtime-test.nix`. It is a QEMU `nixosTest`: nothing
in it touches a live host, and `nix flake check` only evaluates it. Build it on
acer under the heavy-work lock:

```sh
flock /tmp/$(hostname)-heavy-work.lock nix build -L .#packages.x86_64-linux.agent-runtime-nspawn
```

Passing M0 is not permission to deploy and is not the MVP; the epic's MVP
definition of done still applies.

## What the fixture declares

One template, `rust-worker-m0`, declared through the typed module
(`sam.agentRuntime.templates`, `docs/agent-runtime.md`) and evaluated with
`flake.lib.agentRuntime`'s `evalManifests`. The factory reads its mounts,
budgets and sources from the evaluated manifest, binds the manifest read-only
at `/etc/agent-runtime/template.json`, and the export compares the exported
copy byte for byte with the manifest.

| field | value |
|---|---|
| repository | `rf-proto`: `sammasak/rf-proto`, `ref.type = commit`, `lock` = the pinned flake input `rf-proto` (`flake.lock`), mounted read-only at `/src/rf-proto`, copied into the writable `/workspace/rf-proto` |
| skill | `rust-engineering` from the pinned `skills` input, read-only at `/skills/rust-engineering` |
| packages | bash, coreutils, findutils, gnugrep, gnused, gawk, diffutils, util-linux, glibc.bin, cargo, rustc, gcc, as one `buildEnv` |
| filesystem | `/workspace` (host directory bind), `/output` (host directory bind, the export contract), `/home/agent` and `/var/cache/agent` (tmpfs, agent-owned 0700), `/tmp` (tmpfs 1777); each tmpfs gets the template's `sizeMiB` and `inodes` |
| resources | `cpus = 2`, `memoryMiB = 1024`, `tasksMax = 512` become `CPUQuota=200%`, `MemoryMax=1024M` (`MemorySwapMax=0`), `TasksMax=512` on the transient unit |

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
  -p MemoryMax=1024M -p MemorySwapMax=0 -p TasksMax=512 -p CPUQuota=200% -p KillMode=mixed \
  systemd-nspawn --quiet --keep-unit --settings=no --register=yes -M agent-runtime-<id> -D /run/agent-runtime/<id>/root \
    --private-users=<base>:65536 --private-users-ownership=chown \
    --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes \
    --bind-ro=/nix/store:/nix/store[:idmap] \
    --bind-ro=<rf-proto store path>:/src/rf-proto[:idmap] \
    --bind-ro=<skills store path>/skills/rust-engineering:/skills/rust-engineering[:idmap] \
    --bind-ro=<manifest>:/etc/agent-runtime/template.json \
    --bind=/var/lib/agent-runtime/<id>/workspace:/workspace \
    --bind=/var/lib/agent-runtime/<id>/output:/output \
    --tmpfs=/tmp:mode=1777,size=256M,nr_inodes=100000 \
    --tmpfs=/home/agent:mode=0700,uid=1000,gid=1000,size=256M,nr_inodes=100000 \
    --tmpfs=/var/cache/agent:mode=0700,uid=1000,gid=1000,size=512M,nr_inodes=100000 \
    /bin/sh -c "exec setpriv --reuid=<uid> --regid=<uid> --clear-groups --no-new-privs /bin/sh -c '<script> > /workspace/run.log 2>&1'"
```

The root tree is a few directories, `etc/{os-release,passwd,group,nsswitch.conf}`
and three symlinks under `/run/agent-runtime/<id>/root` (447 bytes), built by
`create`. `create` also allocates the instance's UID range: the first of 64
slots of 65536 IDs from host UID 1048576 that no live instance holds, under a
lock, recorded in `/var/lib/agent-runtime/<id>/uidbase`, so the workspace can
be chowned to the mapped agent before the start and two live instances never
share a range. `destroy` stops the unit, unmounts anything left and removes
both directories, which frees the slot; `check-clean` asserts no mount, unit,
machine, nspawn process or directory carries the id.

This is the shape #138 should grow into (idempotent operations keyed by the
instance id, transient unit per instance); it is not yet that adapter.

## What the test proves

1. **Idle instance**: create, run `true`, stop, destroy: the runtime's own
   start cost and memory. The same run decides the store bind: `:idmap` is
   tried first and the fallback used is recorded.
2. **Probe as container root**: records `/proc/self/ns/*`, uid and gid maps,
   cgroup, capability sets, the full mountinfo, devices and interfaces, and the
   host records its own namespaces, maps and mountinfo. Asserted: the user,
   mount, PID, IPC, UTS and network namespaces differ from the host's (cgroup
   differs too; only `time` is shared); root maps to a non-root host range;
   `NoNewPrivs` is 1; a host process's PID cannot be signalled; a host SysV
   shared-memory segment is invisible; setting the hostname succeeds inside
   its own UTS namespace and the host's stays `machine`; the store, the
   environment, the source and the skill binds reject writes; `remount,rw` of
   `/nix/store`, `/src/rf-proto` and `/` is denied, as are `mknod` and writing
   `/proc/sys`; the Nix daemon socket, the systemd private socket, a Docker
   socket, `/home/lukas`, a host root sentinel and `SSH_AUTH_SOCK` are absent;
   only `lo` exists; writes in `/workspace` and `/tmp` succeed.
3. **Cold and warm**, each a fresh instance: as the unprivileged `agent`, copy
   the pinned source into the workspace, `cargo test --offline` (the real test
   suite of rf-proto, dynamic toolchain from the store), export the test binary
   and the template manifest with `SHA256SUMS`; the host verifies the sums
   after the unit has exited, compares the manifest, destroys and checks clean.
4. **Two concurrent instances**: both registered in `machinectl` at the same
   time, distinct host UIDs for the same guest UID 1000, every namespace except
   `time` distinct between them, and each sees only its own marker in its
   workspace.
5. **tasksMax**: a fork bomb (`xargs -P 0` of 712 sleeps) is held at
   `pids.current = pids.max = 512` with the kernel's `max` event counted; the
   instance finishes on its own and the host stays up.
6. **memoryMiB**: a memory hog (`head -c 2048M /dev/zero | tail`) is OOM-killed
   inside the unit's cgroup and systemd reports `Finished with result:
   oom-kill`.
7. **Host unchanged**: the store's entry count and mtime, the sentinel, no
   mount, machine or unit left, `/var/lib/agent-runtime` holds only `exports`.

## Observed on acer (QEMU, 2026-11-05, run 16)

Versions: kernel 6.18.56 (the test VM's), systemd 261 (261.3), nixpkgs
26.11pre-git (`fe13242`), rf-proto `d878c58`, skills `9284403`, template digest
`36f6ea2c…`. The raw log is in the PR.

- `uid_map`/`gid_map`: `0 1048576 65536` for the first instance; the second
  concurrent one got `1114112` (agent = host UID 1115112 against 1049576).
- Namespaces shared with the host: `time` only (nspawn does not unshare it).
- `:idmap` on the store bind was refused (`Failed to clone /nix/store: Invalid
  argument`): the VM's store is an overlay over virtiofs, which has no
  idmapped-mount support, so the run used a plain read-only bind and the store
  shows as `65534:65534 dr-xr-xr-x`. On an ext4 host store the NixOS
  containers module uses `:idmap`; that is expected, not proven here.
- `CapEff`/`CapBnd` `00000000fdecbfff`: nspawn's default retained set for the
  container's root, within its user namespace. Narrowing it is #137's work.
- `/dev`: char console core fd full fuse mqueue net null ptmx pts random shm
  stderr stdin stdout tty urandom zero; 6 PIDs visible to the probe.
- The OOM kill: `Memory cgroup out of memory: Killed process (tail) …
  UID:1049576`, the mapped agent, nothing outside the cgroup.

| run | startup | work | total | memory peak | CPU | instance disk | teardown |
|---|---|---|---|---|---|---|---|
| idle (`true`) | | | 311 ms | 4 MiB | | 447 B | 30 ms |
| cold (`cargo test`) | 168 ms | 2008 ms | 2209 ms | 374.1 MiB | 3.03 s | 22.9 MB | 29 ms |
| warm (`cargo test`) | 179 ms | 1716 ms | 1922 ms | 115 MiB | 2.62 s | 22.9 MB | 29 ms |
| tasksMax bomb | | | 20.6 s | 251.3 MiB | 2.51 s | | 23 ms |
| memoryMiB hog | | | | 1 GiB (the ceiling) | | | 52 ms |

Startup is host `create` to the workload's first line; work is the workload's
own marks; total adds the unit's exit. The cold peak counts the page cache the
first read of the toolchain charged to the cgroup; the warm run reuses it.
Instance disk is the workspace, output and root tree before `destroy` (rf-proto
plus its `target/`). The required closure is 80 store paths, 2.2 GB NAR (the
Rust and GCC toolchains), shared read-only, never copied. The export is 1.99 MB
(test binary, manifest, sums). Teardown is `destroy` alone; `check-clean` adds
about 50 ms.

Fixture findings worth keeping:

- `systemd-run --wait` with `RemainAfterExit=yes` never returns (the unit stays
  active), so the factory reads the memory peak from systemd-run's summary.
- A failed transient unit keeps its name until `reset-failed` or `--collect`,
  so the factory does both.
- stdout through `systemd-run --pipe` arrived as empty lines on the test
  backdoor, so the workload logs into its workspace and the factory prints it.
- Stopping a running instance from the host (`systemctl stop`) left the
  backgrounded `systemd-run --wait` client running past 60 s in run 14; the
  passing fixture lets every instance end on its own. #138's timeout path has to
  bound the client, not only the unit.
- nixpkgs' test instrumentation sets `vm.panic_on_oom = 2`, which turns a
  cgroup OOM into a kernel panic (run 15); the test node sets the kernel's 0.
  A host that sets 2 cannot run memory-bounded instances safely.
- Bash `$((65536 * x % 64))` is `(65536 * x) % 64 = 0`: the earlier fixture
  gave every instance UID base 1048576. Allocation is now explicit.

## Security limitations (M0)

1. nspawn is a shared-kernel boundary. Container root maps to an unprivileged
   host UID range, but a kernel vulnerability reachable from the container is a
   host vulnerability, and the `time` namespace is shared. Approved
   repositories only; not for hostile code.
2. The whole host `/nix/store` is visible read-only. Every closure on the host,
   including configuration that embeds material it should not, is readable from
   the instance; read-only is not confidential. The instance needs 80 paths
   (`closureInfo` above); a closure-only bind set is the candidate mitigation
   for #137, at the cost of one bind per path or a per-template store view.
3. `remount,rw` is denied because the mount is locked in the user namespace;
   a bind with `idmap` depends on the backing filesystem supporting idmapped
   mounts (the run records which one it used).
4. The UID range allocation is per live instance on one host (64 slots); it is
   not persisted across a host crash and not coordinated between hosts. #138
   owns recovery.
5. The workspace and output are host directory binds with no byte or inode
   bound; the tmpfs mounts have size and inode bounds; the unit has
   `MemoryMax`, `MemorySwapMax=0`, `TasksMax` and `CPUQuota` only. Physical
   disk bounds and aggregate admission are #137.
6. No credentials enter the instance in M0 (no token, no SSH agent, no HOME
   from the host). The credential path is designed in #137, never through the
   store or the manifest.
7. The export is a plain copy out of `/output` before destruction; there is no
   retention policy, no size cap and no crash recovery (#138, devenv-platform
   #95).
8. Private network means no network at all in M0. Egress policy, DNS and TLS
   to approved endpoints are #137.
9. `--register=yes` lists the instance in `machinectl` while it runs; that is
   diagnostics, not Herdr visibility (#139).
