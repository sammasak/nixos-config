# Agent runtime: nspawn proof, enforcement and lifecycle (#135, #137, #138)

The M0 proof (#135), the M1 enforcement (#137: capabilities, fixed-size
volumes, admission, fail-closed start) and the lifecycle (#138: concurrent
instances, cancel, timeout, crash and reboot recovery, export, teardown) of the
ephemeral nspawn agent runtime
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
`flake.lib.agentRuntime`'s `evalManifests`. The test drives the shipped
`agent-runtime-instance` (`docs/agent-runtime.md`) with the evaluated manifests
and `sam.agentRuntime.hostPolicy`; both templates share one admission state.

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
boundary). `create` assigns and materializes the locked source (#136) into the
workspace volume; `export` turns the agent's changes into a patch.

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
The runtime therefore uses the smallest explicit factory instead, the same
primitives the NixOS module wraps, without its persistence:
`agent-runtime-instance` (lifecycle, admission, records and exit classes in
`docs/agent-runtime.md`). Its `start`, with the paths it fills in:

```
systemd-run --unit=agent-runtime-<id> --collect --service-type=exec \
  -p MemoryMax=512M -p MemorySwapMax=0 -p TasksMax=512 -p CPUQuota=100% -p RuntimeMaxSec=<timeout> \
  -p KillMode=mixed -p TimeoutStopSec=30 -p Delegate=yes \
  -p ExecStopPost="agent-runtime-instance --state /var/lib/agent-runtime record-exit <id>" \
  --setenv=SYSTEMD_LOG_TARGET=console \
  systemd-nspawn --quiet --keep-unit --settings=no --register=yes --console=pipe -M agent-runtime-<id> -D /run/agent-runtime/<id>/root \
    --private-users=<base>:65536 --private-users-ownership=chown \
    --private-network --as-pid2 --resolv-conf=off --timezone=off --no-new-privileges=yes \
    --drop-capability=<nspawn's default set minus CAP_SETUID,CAP_SETGID,CAP_SETPCAP> \
    --bind-ro=/nix/store:/nix/store[:idmap] --bind-ro=<template manifest>:/etc/agent-runtime/template.json \
    --bind-ro=<skills store path>/skills/<name>:/skills/<name>[:idmap] \
    --bind=/var/lib/agent-runtime/<id>/vol/workspace/workspace:/workspace \
    --bind=/var/lib/agent-runtime/<id>/vol/{home,tmp,cache,output}:<their paths> \
    --setenv=PATH=<the template's packages> --setenv=HOME=... --setenv=TMPDIR=... \
    -- setpriv --reuid=<uid> --regid=<uid> --clear-groups --bounding-set=-all --inh-caps=-all --no-new-privs -- PROGRAM ARG...
```

The payload is argv, never spliced into a shell string. Its stdout and stderr,
and nspawn's own, go to the unit's journal (`logs`, and the export's
`run.log`).

### Volumes

Every writable mount (workspace, home, tmp, cache, output) is its own
`fallocate`d ext4 image, `mkfs.ext4 -m 0 -N <inodes> -E nodiscard,root_owner=<mapped owner>`
(nodiscard: the default discard would punch the allocation back out of the
file), loop-mounted `nosuid,nodev` under `vol/<name>`. `tmp` is 1777 and owned
by the mapped root, the rest are 0700/0755 and owned by the mapped agent. The
workspace volume holds materialize's records at its root and the checkouts in
`workspace/`, which is the part bound at `/workspace`.

### Capabilities

nspawn has no "drop all", and the payload has to switch to `agent` inside. The
tool drops every capability of nspawn's default set except `CAP_SETUID`,
`CAP_SETGID` and `CAP_SETPCAP`; `setpriv` then empties the bounding and
inheritable sets and sets no-new-privileges before it executes the payload, so
the payload, as `agent` or as container root, has every capability set at 0.
nspawn's stub init (PID 1 in the container) keeps the three capabilities.

## What the test proves

Every subtest drives `agent-runtime-instance`; each teardown is followed by a
per-instance check (no mount, loop device, nspawn directory, unit, machine or
state directory for the id), and the host inventory (units, mounts, nspawn
directories, loop devices, state, live GC roots, processes in the mapped UID
ranges, network links) is printed before, during and after.

1. **Ids**: `exports`, `../x`, `A` and `-x` are refused before anything exists.
2. **Idle instance**: create (five volumes), run `true`, destroy: the runtime's
   own cost.
3. **Probe as container root**: records `/proc/self/ns/*`, uid and gid maps,
   cgroup, capability sets, open file descriptors (0-3 only), the full
   mountinfo, devices and interfaces. Asserted: only `time` is shared with the
   host and the namespaces equal what `start` recorded from the leader; root
   maps to the instance's own range; all capability sets 0, `NoNewPrivs` 1,
   `Seccomp` 2; a host process cannot be signalled, a host SysV segment is
   invisible; `hostname`, mounts, `remount,rw`, `mknod`, `/proc/sys`, `/sys`,
   `/proc/kcore`, and writes to the store, the environment, the skill and the
   agent's workspace are denied; no Nix daemon, systemd or Docker socket, no
   host sentinels, no `SSH_AUTH_SOCK`, only `lo`.
4. **Lifecycle**: two rust instances and one `tiny` live at once with three
   distinct UID ranges and seven distinct namespaces each (all but `time`); a
   third rust instance is refused for memory and a fourth instance for the
   count; both jobs run `cargo test --offline` on the materialized pinned
   source as `agent` (capabilities 0), change `README.md` and leave an untracked
   binary file; the live run directories hold GC roots for the pinned source;
   each export carries a patch with that edit and a `GIT binary patch`, the
   output artifacts with their sums, the log and `bundle.json` whose sums
   verify. Destroying `job-a` leaves the running `hold-c` untouched; `hold-c`
   sees only its own workspace marker and SysV segment and cannot signal
   `job-a`'s leader.
5. **Duplicates**: create with the same task returns the record, another task
   is `conflict`; a second start does not re-run (same invocation, the
   marker payload never runs); cancel, export and destroy twice are no-ops.
6. **Cancellation**: destroy refuses a running instance; cancel twice; the
   outcome is `cancelled`; destroy refuses it unexported; the export is a
   recovery bundle.
7. **Timeout**: `--timeout-sec 3` ends a sleeper as `timed-out`.
8. **Crash mid-run**: SIGKILL of the instance's nspawn is `failed` with
   `serviceResult = signal`; export and destroy leave nothing.
9. **Supervisor crash**: killing the CLI that waits on an instance leaves the
   instance running; its outcome is still recorded by the unit.
10. **Killed create**: a create SIGKILLed after its reservation is `incomplete`,
    blocks a new create of the id, and `reconcile` rolls it back.
11. **Disk admission**, **fail closed** without user namespaces (`Failed to
    fork inner child`, payload never ran, reservation held), **failed teardown**
    (a busy mount keeps the reservation until a second destroy).
12. **Budgets**: a fork bomb held at `pids.current = pids.max = 512`; a memory
    hog `oom-killed` with a recovery bundle; three busy loops held to one core;
    `dd` and `touch` stopped by the workspace's bytes and HOME's inodes with the
    host's free disk unchanged.
13. **Host reboot**: a running instance and a created one, then a hard crash of
    the VM. After the boot, `reconcile` reports `ambiguous` and `created`;
    starting the ambiguous one is refused (`not replayed`); both stay counted;
    the created one starts and succeeds (its volumes are mounted again); the
    ambiguous one exports a recovery bundle and is destroyed.
14. **Per-run credential**: a `tiny` instance started with `--credential` sees
    the token read-only at `/run/agent-runtime/credentials/token`, owned by the
    mapped `agent` (`1000:400`), and cannot write it. The secret never reaches
    the persistent state dir or the store; the printed `logs` view masks it
    (`<redacted>`). A second instance started with the same host file reads only
    its own token. The export redacts the diagnostic log in place and refuses
    (class `credential`, exit 5) when an `/output` artifact carries the secret,
    reading the still-mounted token itself rather than depending on the caller.
15. **Minimal egress**: an `egress` instance (`network.allow = [ "allowed.test"
    ]`) reaches `https://allowed.test/` over TLS (`endpoint-ok`) through the
    name pinned in its `/etc/hosts`, and is refused both a non-allowlisted
    host-local address (`10.9.0.9`) and a non-allowlisted address reachable only
    by the host routing on its behalf (`10.8.0.5` in a netns), proving the
    `forward` hook and not just `input`; the host itself can reach `10.8.0.5`,
    so the refusal is the filter, not missing routing. After `destroy` the veth
    and the `art_<id>` nft table are gone. No port 53 is ever opened.
16. **Credentials, two instances at once**: `ca` and `cb` run concurrently
    with different tokens; each reads only its own (hash checked), cannot read
    the other's host path `/run/agent-runtime/<peer>/cred/token`, and finds no
    file named `token` anywhere in its trees but its own; neither token appears
    in the other's logs.
17. **DNS closed**: the egress instance resolves its pinned allowlist name
    (`getent ahostsv4 allowed.test` → 10.9.0.1) and nothing else
    (`denied.test`: rc 2), and a raw DNS query to a resolver on the host and to
    one routed off it gets no answer, though both answer the host.
18. **Two egress starts at once**: `eg1` and `eg2` start together and are held
    running; for each, the veth its nft table filters has the host index that
    its own container's `host0@ifN` names (so a swap fails), and both reach the
    allowlisted host and are refused the routed one.
19. **Minted credential**: a `ghread` instance (`capabilities = [ "github-read" ]`,
    allowlist `api.test`) gets a 6 s token from a stand-in issuer: read 200,
    push 403, read after expiry 401; the record holds scopes and expiry, never
    the token; teardown revokes it at the issuer. An issuer granting
    `github-push` too is refused (class `credential`, nothing started) and its
    token is revoked at the issuer, and a TTL beyond the run's limit is refused
    (class `usage`). A relative `--credential-issuer` is recorded absolute, so a
    `destroy` from another directory still revokes; a revoke that fails is a
    `{"warning": …}` on `destroy`'s stderr (the token not in it), not silence.
    A start retried after one that died between minting and its marker revokes
    the stale token and drops its issuer record, so an operator `--credential`
    token on the retry is never sent to `revoke`.
20. **Host unchanged**: the inventory is empty again (links as before), no
    reservation, the store's entries unchanged, the sentinels in place, host
    disk back to the start minus the kept exports.

## Observed on acer (QEMU, 2026-11-05)

Versions: kernel 6.18.56 (the test VM's), systemd 261 (261.3), nixpkgs
26.11pre-git (`fe13242`), rf-proto `d878c58`, skills `9284403`. The raw log is
in the PR.

- UID maps `0 <base> 65536`: three live instances got bases 1048576, 1114112
  and 1179648.
- Namespaces shared with the host: `time` only (nspawn does not unshare it).
- The store bind is plain by default; `start --idmap` asks for `:idmap`, which
  the test VM refuses (`Failed to clone /nix/store: Invalid argument`: its store
  is an overlay over virtiofs, without idmapped-mount support). The store shows
  as `65534:65534` inside. On an ext4 host store `:idmap` is expected to work;
  that is not proven here.
- A nested user namespace can be created from inside but its `uid_map` cannot
  be written (`unshare --user --map-root-user`: `write failed
  /proc/self/uid_map: Operation not permitted`); see the limitations.
- The payload's open file descriptors are 0, 1, 2 and the directory `ls` reads.

| run | create | startup | work | memory peak | CPU | instance disk | export | teardown |
|---|---|---|---|---|---|---|---|---|
| idle (`true`) | 1128 ms | | 167 ms (unit runtime) | 4.0 MiB | | | | 203 ms |
| job-a (`cargo test`, concurrent) | 1175 ms | 4.0 s | 4443 ms | 355 MiB | 3.64 s | 22.9 MB | 2.03 MB | 346 ms |
| job-b (`cargo test`, concurrent) | 1257 ms | 4.6 s | 3936 ms | 157 MiB | 3.46 s | 22.9 MB | 2.03 MB | 363 ms |
| tasksMax bomb | | | | | | | | 184 ms |
| memoryMiB hog | | | | 512 MiB (the ceiling) | | | | 303 ms |
| cpus (3 loops, 5 s) | | | 5.159 s | | 5.166 s | | | 218 ms |

Create is admission, assign (the GC roots), five volumes (allocate, mkfs,
mount, fsync) and materialize; startup is from before the first create of the
lifecycle subtest to the job's first line, with three creates in between; work
is the job's own marks. The jobs ran concurrently with `cpus = 1` each on the
two-core VM. Teardown is `destroy` alone (reclaim, five unmounts, image and
record removal). The whole lifecycle subtest (three creates, two real jobs, two
exports, three destroys) took 12.2 s; the whole test script 114.8 s. The
required closure is 80 store paths, 2.2 GB NAR, shared read-only, never copied.

Findings worth keeping:

- With nspawn's cgroup subtree under the unit, `ExecStopPost` cannot be spawned
  (`Failed to spawn 'stop-post' task: Device or resource busy`) unless the unit
  has `Delegate=yes`, which runs control processes in `.control`.
- With `Delegate=yes` the payload killed by the OOM killer usually exits (137)
  before systemd acts on the OOM event, and the unit's result is `exit-code`;
  `record-exit` reads the kernel's `oom_kill` count from `memory.events`.
- nspawn logging natively to the journal and exiting at once loses the unit
  attribution (journald reads it from the dead PID); `SYSTEMD_LOG_TARGET=console`
  sends its errors through the unit's stdout stream, which keeps it.
- A hard crash lost records written seconds earlier (a `starting` marker among
  them, which would have made the interrupted run look `created` and runnable):
  every record is fsynced with its directory, and create syncs the volumes
  before the record that completes it.
- #136's `assign` registered each GC root at its staging path and then renamed
  the directory, so the pinned sources were never protected from GC; it now
  roots them again at their final path.
- A SIGKILLed nspawn leaves `/run/systemd/nspawn/<machine>` and its
  `unix-export` mount behind; teardown removes both.
- `systemd-run --wait` with `RemainAfterExit=yes` never returns; stopping a
  `--wait`ed unit from outside left the client waiting. `start` runs the unit
  detached and `wait` polls the recorded outcome.
- nixpkgs' test instrumentation sets `vm.panic_on_oom = 2`, which turns a
  cgroup OOM into a kernel panic; the test node sets the kernel's 0. A host
  that sets 2 cannot run memory-bounded instances safely.
- nspawn appends its own `uid=`/`gid=` to `--tmpfs` options, so a tmpfs cannot
  be handed to `agent` from outside; the ext4 volumes are created with the
  mapped owner instead.

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
4. Admission compares the sum of reservations against `MemTotal - reserve` and
   checks that `MemAvailable` minus the new instance still covers the reserve;
   a later surge of other host workloads is not re-checked while instances run.
   The reservations are durable files in `/var/lib/agent-runtime`: a crashed or
   ambiguous instance stays counted until it is destroyed. The UID ranges (64
   slots) are per host; nothing coordinates hosts.
5. The volumes bound bytes and inodes per mount; the cgroup bounds memory
   (`MemorySwapMax=0`), tasks and CPU. I/O bandwidth is not bounded.
6. A per-run credential (`start --credential FILE`) is copied to a private
   per-instance tmpfs dir under `/run/agent-runtime/<id>/cred`, owned by the
   mapped `agent`, and bound read-only at `/run/agent-runtime/credentials`; it
   never comes from the manifest, the store or the persistent state dir, and the
   tmpfs is gone on teardown. Nothing about it is kept at rest. Redaction masks the
   secret in the printed `logs` view and in the exported log; the raw secret
   still lives in the payload's own files and the private tmp volume until
   teardown, which is acceptable only because that volume is private and
   discarded. The export refuses an `/output` artifact that carries the secret.
   A minted credential (`--credential-issuer`) is checked against the
   template's `capabilities` and the run's lifetime before anything starts, and
   revoked at teardown (`docs/agent-runtime.md`). Open on an owner decision:
   the production issuer (a GitHub App and its key in sops); the VM proves the
   contract with a stand-in.
7. Exports are kept under `/var/lib/agent-runtime/exports` with no retention
   policy or size cap beyond each part's own bound (patches up to the output
   budget, the log's last 1 MiB, the output volume); retention is
   devenv-platform #95.
8. The default template has no network at all. An `allowlist` template gets a
   veth, and once its leader is up the host resolves `network.allow` once,
   pins the names into the instance's `/etc/hosts` (`hosts: files` in nsswitch,
   delivered as a read-only bind so nspawn's boot-time rewrite cannot clobber
   it), and installs an nft table filtering the instance's veth on **both** the
   `input` and `forward` hooks: established/related and `tcp dport 443` to each
   resolved address accepted, everything else dropped. Port
   53 is never opened, so a made-up name cannot resolve and there is no
   query-based exfiltration path. Enforcement is by address at run start, so a
   name that moves mid-run is not followed.
9. `--register=yes` lists the instance in `machinectl` while it runs; that is
   diagnostics, not Herdr visibility (#139).
