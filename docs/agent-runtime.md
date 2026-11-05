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

One template, as a plain Nix attrset for now (the typed module is #134's
deliverable; the fixture reads the same fields it will expose):

| field | value |
|---|---|
| repository | `sammasak/rf-proto`, `ref.type = commit`, the pinned flake input `rf-proto` (`flake.lock`), mounted read-only at `/src/rf-proto`, copied into the writable `/workspace/rf-proto` |
| skill | `rust-engineering` from the pinned `skills` input, read-only at `/skills/rust-engineering` |
| packages | bash, coreutils, findutils, gnugrep, gnused, gawk, diffutils, util-linux, cargo, rustc, gcc, as one `buildEnv` |
| filesystem | `/workspace` (host-backed bind, writable), `/home/agent` (tmpfs), `/tmp` (tmpfs), `/workspace/export` (the export contract) |
| budget | `MemoryMax=1G`, `TasksMax=512`, `CPUQuota=200%` on the transient unit |

`pkgs.closureInfo` over the environment, the source and the skill gives the
closure the instance needs; the fixture mounts the whole host store read-only
(see the limitations below for why that is a confidentiality finding, not a
boundary).

## NixOS `containers.<name>` or a unit factory

The question in #135 was whether an evaluated `nixosSystem` container path is
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
primitives the NixOS module wraps, without its persistence:

```
systemd-run --unit=agent-runtime-<id> --wait --pipe -p MemoryMax=.. -p TasksMax=.. -p CPUQuota=.. -p KillMode=mixed \
  systemd-nspawn --keep-unit --settings=no --register=yes -M agent-runtime-<id> -D /run/agent-runtime/<id>/root \
    --private-users=<base>:65536 --private-users-ownership=chown \
    --private-network --as-pid2 --resolv-conf=off --timezone=off \
    --bind-ro=/nix/store:/nix/store[:idmap] \
    --bind-ro=<rf-proto store path>:/src/rf-proto[:idmap] \
    --bind-ro=<skills store path>/skills/rust-engineering:/skills/rust-engineering[:idmap] \
    --bind=/var/lib/agent-runtime/<id>/workspace:/workspace \
    --tmpfs=/tmp:mode=1777,size=256M --tmpfs=/home/agent:mode=0755,uid=1000,gid=1000,size=256M \
    --user=agent <script>
```

The root tree is a few directories and three files (`etc/os-release`,
`etc/passwd`, `etc/group`) under `/run/agent-runtime/<id>/root`, built by the
factory's `create` step; the UID base is a fixed function of the instance id so
the factory can `chown` the workspace before the start. `destroy` stops the
unit, unmounts anything left and removes both directories; `check-clean`
asserts no mount, unit, machine, process or directory carries the id.

This is the shape #138 should grow into (idempotent operations keyed by the
instance id, transient unit per instance); it is not yet that adapter.

## What the test proves

As container root (the probe): the UID map, capability sets, mounts, devices
and network interfaces are recorded; the store, the source bind, the skill bind
and the root are read-only to a write and to `mount -o remount,rw`; `mknod`
and writing `/proc/sys` are denied; the host's Nix daemon socket, systemd
control socket, Docker socket, `/home/lukas`, a root sentinel and
`SSH_AUTH_SOCK` are absent; only `lo` exists; writes succeed in `/workspace`
and `/tmp`.

As the unprivileged user `agent`, twice (cold, then warm): copy the pinned
source into the workspace, `cargo test --offline`, export the test binary with
its sha256 and a manifest naming the template, repository, ref, skill and
environment; the host verifies the sha256 after the unit has exited, then
destroys the instance and asserts the leak check. Afterwards the host store's
entry count and mtime are unchanged and no mount, machine or unit remains.

## Observed on acer (QEMU, 2026-11-05)

Raw test log in the PR. What the probe recorded as container root:

- `uid_map: 0 1048576 65536`: container root is host UID 1048576; the store
  shows as `65534:65534 dr-xr-xr-x` (nobody) because the bind is not idmapped.
- `:idmap` on the store bind was refused in the VM (`Failed to clone
  /nix/store: Invalid argument`): the test VM's store is an overlay over
  virtiofs, which has no idmapped-mount support; the fixture fell back to a
  plain read-only bind and still passed. On a host whose store is ext4 the
  NixOS containers module uses `:idmap`, so that is the expected production
  form; it is not proven here.
- `CapEff`/`CapBnd` `00000000fdecbfff`: nspawn's default retained set for
  the container's root (within its user namespace), and `NoNewPrivs` was 0
  until the factory passed `--no-new-privileges=yes` (now asserted 1). The
  capability bounding set is #137's work.
- Mounts: `/` tmpfs, `/nix/store`, `/src/rf-proto` and
  `/skills/rust-engineering` read-only, `/workspace` ext4 rw (the host
  directory), `/tmp` and `/home/agent` tmpfs with the mapped owner, `/proc/sys`
  read-only, `/sys` read-only, cgroup2 delegated.
- `/dev`: console core fd full fuse mqueue net null ptmx pts random shm stderr
  stdin stdout tty urandom zero. Network: `lo` only.
- Denied: writes to the store, the environment, the source and the skill
  binds; `remount,rw` of `/nix/store`, `/src/rf-proto` and `/`; `mknod`;
  writing `/proc/sys/kernel/sysrq`. Absent: the Nix daemon socket, the
  systemd control socket, a Docker socket, `/home/lukas`, the host's root
  sentinel, `SSH_AUTH_SOCK`. Writes in `/workspace` and `/tmp` succeed.
- The probe instance: service runtime 1.4 s, CPU 0.5 s, memory peak 5.7 MiB
  (systemd-run's summary).

Two fixture findings worth keeping: a failed transient unit keeps its name
until `reset-failed` or `--collect`, so the factory does both; and stdout
passed through `systemd-run --pipe` arrived as empty lines on the test
backdoor, so the workload logs into its workspace and the factory prints that
file.

| run | startup | cargo test | teardown | memory peak |
|---|---|---|---|---|
| cold | (filled from the PR log) | | | |
| warm | | | | |

## Security limitations (initial list, M0)

1. nspawn is a shared-kernel boundary. Container root maps to an unprivileged
   host UID range, but a kernel vulnerability reachable from the container is a
   host vulnerability. Approved repositories only; not for hostile code.
2. The whole host `/nix/store` is visible read-only. Every closure on the host,
   including configuration that embeds material it should not, is readable from
   the instance. A closure-only bind set (`closureInfo` lists the paths) is the
   candidate mitigation for #137; the fixture records the closure for it.
3. Read-only means not writable, not confidential, and `remount,rw` is denied
   because the mount is locked in the user namespace; a bind with `idmap`
   depends on the backing filesystem supporting idmapped mounts (the probe
   falls back to a plain bind and the run records which one it used).
4. The writable workspace is a host directory bind with no byte or inode
   bound; the tmpfs mounts have a size but no inode bound; the unit has
   `MemoryMax`, `TasksMax` and `CPUQuota` only. Physical bounds and admission
   are #137.
5. No credentials enter the instance in M0 (no token, no SSH agent, no HOME
   from the host). The credential path is designed in #137, never through the
   store or the manifest.
6. The export is a plain copy out of the workspace before destruction; there is
   no retention policy, no size cap and no crash recovery (#138, devenv-platform
   #95).
7. Private network means no network at all in M0. Egress policy, DNS and TLS
   to approved endpoints are #137.
8. `--register=yes` lists the instance in `machinectl` while it runs; that is
   diagnostics, not Herdr visibility (#139).
