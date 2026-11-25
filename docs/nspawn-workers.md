# Developer environments (nspawn)

An environment is a long-running developer machine declared in a worker host's
configuration: a stock NixOS container (`containers.<name>`, systemd-nspawn) on
acer-swift, msi-ms7758 or asus-b460m with the fleet's tooling (Claude Code, Codex, git, gh,
devenv), its own persistent home, and a workspace in the host's Herdr with the
agent running in it. It runs while declared; its home is deleted only once its
name is in `retired`, or replaced by a fresh one with `dev-env-reset@<name>` (Reset, below). Modules:
`modules/workers/core.nix` (`services.devEnvironments`, nothing of this
fleet: the part meant for publishing) and `modules/workers/default.nix`, the
fleet adapter (`sam.workers.*`, the fleet's guest modules, credentials and the
Herdr workspace as the session surface).

## Declare one

In `hosts/<host>/configuration.nix`, then deploy that host (`just deploy msi-ms7758`,
`just deploy acer-swift`):

```nix
sam.workers.instances = {
  fix-ci = { model = "opus"; prompt = "Fix issue #123 in sammasak/nixos-config, end to end."; };
  shell = { agent = "none"; };
};
```

| Option | Default | Effect |
|--------|---------|--------|
| `agent` | `"claude"` | `claude` (`--dangerously-skip-permissions`), `codex` (not signed in on these hosts), or `none` (a fish shell) |
| `model` | `null` | the agent's `--model` |
| `prompt` | `null` | sent once the agent is idle, only on a start with no earlier Claude session |
| `credentials` | `null` | which of the host's credentials it gets (`id_ed25519`, `gh-hosts.yml`); `null` is all. `[ ]` is an agent that cannot push |
| `egress.github.repos` | `[ ]` | `owner/repo` the instance reaches through the host's proxy (git and REST); non-empty, it gets neither credential; a repo whose devenv imports a private input needs that input listed too (factum and herman need `sammasak/devenv-platform`), else no `devenv shell` works; git and nix fetch it through the proxy rewrite without an SSH key. Any other repository: a git fetch alone, sent without the token, so only a public one answers |
| `egress.github.graphql` | `false` | also pass GraphQL, which no repository list bounds; nearly every `gh pr`/`gh issue` command needs it. Without it a pull request is opened and commented on with `gh api` over REST (`repos/<repo>/pulls`, `repos/<repo>/issues/<n>/comments`), as a pool task is told |
| `telemetry` | the host's `nativeOtel` | on by default on a `nativeOtel` host, so every environment's work can be reviewed later; `false` opts one out. The guest's Claude exports OTLP metrics and events (no content), and its Codex metrics, as `host.name=<host>,worker.name=<name>` to its `127.0.0.1:4319`, which `otlp.sock` passes (`POST` to exactly `/v1/metrics` or `/v1/logs`, bodies up to 1MiB, stamped `X-Otel-Worker: <name>` over whatever the guest sent; the stamp names the worker on logs and on metric points as `worker`) to the host's `native-otel-relay`; the relay adds the token, which never enters the guest, and limits each environment to 20 requests/s (burst 50) apart from the host's own clients. Setting it `true` on a host without `sam.profile.nativeOtel` fails evaluation; setting `sam.claude.telemetry` in a guest module instead fails too. acer, msi and asus are `nativeOtel` hosts (lenovo too, which runs no environments). Details in [native-otel-canary.md](native-otel-canary.md) |
| `memory.reserved` | `"2G"` | `MemoryMin`: never reclaimed for a neighbour; above it, whatever the pool has idle |
| `cpu.reserved` | `2` | cores: `CPUWeight` 100 per core, its share under contention; idle cores are all usable |
| `rootInGuest` | `false` | its own 65536 uids (`--private-users`): guest root is an unprivileged host uid, and the user gets passwordless sudo. Its home and caches are owned on disk by its mapped ids (not id-mapped), so the option needs a fresh instance: an existing environment toggled either way refuses to start until it is retired or declared under a new name, it has its own sshd key and HostKeyAlias `<name>.environments.<prefix>`, and the state dir and per-container profiles and roots are mounted nosuid. Ran on msi (root1, root2) |

A guest's telemetry attributes and content flags are self-asserted: its user can
rewrite `OTEL_*` or hand-build OTLP. The gateway enforces an attribute allowlist
on `/v1/logs` and `/v1/metrics` (prompts, tool input, identities and error text
are dropped there, whatever a guest sends). On logs and metric points it sets `worker`
from the stamped `X-Otel-Worker`. A `host.name` a guest claims is bounded to the fleet allowlist,
not otherwise verified.

Host-wide: `sam.workers.pool.memory` (below) and `sam.workers.ntfyUrl` (null, or the ntfy topic that hears of failures, see Alerts).

Every environment of a host runs in `environments.slice`, whose `MemoryMax` is
the host's `sam.workers.pool.memory` (protecting the host and its services) and whose
`MemoryLow` is the sum of the reserves. An environment has no ceiling of its
own and the pool no `MemoryHigh`: the only limit is the pool's `MemoryMax`,
with the pool's swap (zram) capped at a quarter of it, so one gate alone uses what
its neighbours leave idle, down to their reserves (`MemoryMin`). nix builds
run in the host's daemon, outside the pool; acer, msi and asus bound that daemon
(2 jobs of 2 cores, `MemoryHigh` 4G, `MemoryMax` 6G), so a build
fails before the host's services do. msi powers off at 21:00
(Mon-Fri window); its environments come back at its next boot.
Inside, the cgroup files read `max`: `/etc/dev-environment` holds these limits as shell `key=value` (bytes: `memory_reserved`, `pool_memory`, `pool_swap`; `cpu_weight`, `nix_max_jobs`, `nix_cores`).

## Execution pool

`homelab.execPool` (`modules/homelab/exec-pool-options.nix`, slots in `modules/workers/execution-pool.nix`; on acer-swift three slots, on msi-ms7758 four, no named worker beside them) declares reusable slots for the
pool's tasks (`docs/records/execution-pool-contract.md`): `pool1` .. `pool<slots>`, each an instance with
`agent = "none"` and no prompt, so a slot has the named instances' pool ceiling, reserves, `rootInGuest`, reset and
retire. Changing `slots` is a reviewed deploy; a task is released with `dev-env-reset@<slot>`, which switches nothing.

| Option | Default | Effect |
|--------|---------|--------|
| `enable` | `false` | off, nothing moves (pinned by `scripts/test-workers-eval.py`) |
| `slots` | `0` | how many slots (unsigned) |
| `memory.reserved`, `cpu.reserved` | `"2G"`, `2` | each slot's, as an instance's |
| `credentials` | `[ ]` | which host credentials a slot may hold; never `id_ed25519` (asserted) |
| `github.repos` | sammasak's repositories tasks hand back to, and nixos-config's private inputs | each slot's `egress.github.repos`: git and gh to these repositories through the host's GitHub proxy, no credential in the slot; a host in `sam.fleet.listeners.github-egress`'s `from` (msi) forwards to that listener's host (acer), which applies its own list ([execution-pool-credentials.md](records/execution-pool-credentials.md)) |
| `agents` | `[ ]` | agents a task may run in a slot (`claude`): each slot's `headlessAgents`, the egress route a named worker of that agent has (the anthropic proxy, no credential in the guest), while its `agent` stays `none` and no session starts |
| `slot.privateUsers` | `false` | each slot's `rootInGuest` without its sudo: its own 65536 uids, so guest root is an unprivileged host uid, with its own sshd key and fetcher cache (emptied by every reset, so a turn's first `devenv shell` fetches its inputs again). A slot whose home was made in the other block resets it at its next start instead of refusing (`dev-env-fresh-on-toggle`), so flipping it is one deploy. Off everywhere; not yet booted in a VM or on a host |

Evaluation fails when a slot's name is also declared in `sam.workers.instances` or `retired`, or when the slots and
the named instances reserve more than `pool.memory`. `worker-pool-inventory` prints one JSON line per slot from its
units: `slot`, `state`, `sub`, `closure`, `memory.min`/`.low`, `cpu.weight`, `slice`. `nix build .#execution-pool-vm`
(msi) boots two slots beside a named instance, reuses one across a reset and restarts it alone.

Every slot has `sessionDock` (an instance option, off for named workers): `/session` is bound read-write from
`<stateDir>/.sessions/dock/<slot>`, root's 0755 under `.sessions/dock` (0755) and `.sessions` (0711). The exec helper
makes a session turn's home and checkout afresh there and removes them at the park once its work is on the remote
(`docs/records/execution-pool-contract.md`, Session state); reset, retire, the trash sweep and records never touch
`.sessions`, and gcroots only reads it. Under `slot.privateUsers` the dock's `home` and `work` take the slot home's
mapped owner, as the runner makes them with the slot home's uid and gid.

A slot's user is in no group but its own and has no sudo (named instances keep the fleet's groups). What a slot binds
from its host is pinned per slot by `scripts/test-workers-eval.py` (`check_slot_reach`): its home, caches and dock,
its egress sockets, the lock lanes, an sshd host key (the environments' shared one, or with `slot.privateUsers` its
own, readable by guest root alone) and the host user's public key, beside the stock store, nix db, daemon socket and per-container profiles and roots; no secret,
token or private key of the host user, and its container unit loads no credential.

## Sizing

Reserved per environment, spiking allowed. Measured on both hosts (8 cores,
16G RAM, 7.8G zram) under the earlier hard caps: acer `demo` (6G cap,
CPUQuota 390%) peaked at 5.2G of which 1.1G anon, the rest page cache, and was
CPU-throttled 947 s of 1275 s used while cores sat idle; msi `skills91`
(3584M cap, 300%) hit `memory.max` 20138 times, swapped 218M and was throttled
591 s of 869 s. Hard caps cost real time and bought nothing on an idle host.

| Host | Pool | Prefix | Host's own use | At most (by reserve) | Recommended |
|------|------|--------|----------------|----------------------|-------------|
| acer-swift | 7G, 8 cores | `acer` | host services and system about 7.5G (measured before the k3s removal, an upper bound) | 3 | 2 |
| msi-ms7758 | 10G, 8 cores | `msi` | about 2.8G | 5 | 3 |
| asus-b460m | 20G, 10 cores | `asus` | not measured yet (32 GB RAM) | 10 | 4 |

The reserve sum is what eval enforces; the recommendation is lower because a
build in an environment spikes to 4 to 5G.

Burst, measured on msi (10G pool, two environments): one alone reached 10.06G
with 4.6G in swap and no kill. A 17G runaway was killed by the kernel after
23 s (that process only; containers and agents stayed up) while a neighbour
holding 1.5G kept it, its slowest pass over that memory 4.3 s against 0.2 s.
With `MemoryHigh` on the pool and only `MemoryLow` per environment the same
runaway was never killed: it stalled for 18 minutes at the limit and the
neighbour was reclaimed to 59M.

## Lifecycle

| Step | How | Measured (msi) |
|------|-----|----------------|
| Create | add `instances.<name>` on the host, deploy | 37 s deploy, guest boots in 1.9 s (6.8 s before the unused guest services went) |
| First use of a repo | clone, `devenv shell` | closure already in the host store: 20 s (herman), 26 s (factum), of which 12 to 15 s fetching input tarballs, 5 s evaluation, 2 s small builds, no substitution; closure not yet in the host store: 88 to 92 s (about 63 downloads, 3.9 GB, plus local assembly of the Rust toolchain); fresh clone of a lock the environment has seen: 6.5 s (factum), 17.6 s (herman, msi); 0.2 to 0.6 s after that |
| Work | brief the agent through Herdr, or `ssh <name>.<prefix>` | hours to days; the home persists |
| Host reboot or redeploy | nothing | container autostarts 6 to 7 s into userspace, the agent is back in Herdr at 14 to 15 s and resumes its conversation; home and the shared `~/.cache/nix` are intact (`devenv shell` 7 to 10 s). Whatever ran in the environment is killed and not restarted: the resumed agent is told so, once per start of the container, and re-checks its work. A host with `sam.workers.shutdownNotice` tells its named agents at that time to push before a scheduled poweroff; msi has no named agent left, its pool runner claims only work whose hold ends before the poweroff |
| Resize (`memory`, `cpu`) or edit `prompt` | edit the declaration, deploy | live, no restart (checked on msi: 6G to 5G and back, same container start time) |
| Change `agent`, `model`, credentials | edit the declaration, deploy | restarts that one environment, home kept |
| Stop | remove the declaration, deploy | units stop, home kept |
| Retire | move the name from `instances` to `retired`, deploy; drop it from `retired` any time later, except on a host that declares no instance, where the last name stays until `.trash` is empty (the daily `dev-environments-trash` timer that ages it out, and the activation, exist only while `instances` or `retired` is set) | 23 s; profile and GC roots deleted, the home's unsent platform records shipped (at most 30 s), the home moved to `<stateDir>/.trash/<name>-<date>` and deleted by that timer (or an activation) a week later (recover it with `mv` meanwhile); each timer run records one `kind=trash-sweep` line to Loki (`seen= deleted= bytes= result=`, counts only); a `.trash` that is a link, a file or another mount is refused and fails the timer's unit |
| Reset | `sudo systemctl start dev-env-reset@<name>` (the coordinator, through the deploy user, or the owner); no deploy. It refuses, and changes nothing, while a `claude` or `codex` process runs in the guest or a clone under its home has uncommitted changes, commits on no remote, or a stash: to discard those on purpose, retire the name instead. The check runs inside the guest as its user, never as host git on guest-owned clones | the container stopped, its home, profile and GC roots trashed as Retire does, the home recreated as for a new instance (fresh `~/.cache`, eval and fetcher caches, and for `rootInGuest` a new host key, so a client that trusted the old one drops its line from `~/.ssh/known_hosts_environments`), the container started again; the host store is not touched (`tests/dev-env-reset-vm.nix`, `nix build .#dev-env-reset-vm` on msi) |

Removing a declaration only stops the environment: a rollback or a deploy from
an older checkout lacks instances too, and must not delete their homes. Only a name in `retired` is
deleted, and only while its container is stopped; eval refuses a name in both.

The store is the host's, read-only, with builds going through the host's
daemon, so anything one environment or the host built is there for the next.
The host's weekly/monthly collection would not see an environment's devenv
roots (the daemon records them under the guest's path), so
`dev-environments-gcroots` roots them from each home right before `nix-gc`
(it searches the whole home, pruning `node_modules`, `target` and `.git`).
It also roots each session's work tree, parked (`.sessions/<id>/tree/work`) or docked in a slot
(`.sessions/dock/<slot>/cur/work`), under `/nix/var/nix/gcroots/dev-env-sessions/parked/<id>` or `dock/<slot>`; a key no
longer found keeps its roots for an hour, since a dock or park moves the tree between two keys.
A timer also runs it at boot and every 15 minutes, because the daemon collects
by itself once `min-free` is set; a path a guest built within the last interval
is the remaining exposure.

Across hosts, lenovo, acer, msi and asus each serve their store to the other fleet hosts as a
binary cache (`modules/core/store-cache.nix`, harmonia on port 5000, admitted by the `store-cache-<host>`
listeners in `modules/core/fleet.nix`) and
substitute from the always-on ones ahead of cache.nixos.org: what one machine
built the others download. msi and asus (both `sleeps` in
`modules/core/fleet.nix`) serve their store while up but nobody substitutes
from them: with msi powered off, every path lookup on acer waited
out the 3 s connect timeout one after another (180 lookups, 9 minutes of a
first `devenv` evaluation, measured 2026-11-12). Each cache signs with a key generated on its host
before it joins (`/var/lib/store-cache/`, never in git; docs/new-host.md step 5); the public halves are in the
module. A dead peer costs a fetch of 20 paths 118 s without `fallback`, about
20 s with `fallback = true`, which the module sets and an environment takes
from its host, and 3 s with `download-attempts = 1`, which nothing sets
(measured 2026-11-13, #332). An environment's nix is a client of its host's daemon, so its builds
and downloads go through the same caches; its own nix.conf carries the
host's substituter list, because the daemon takes a client's list when it
trusts every entry and a shorter one skipped the LAN caches. Checked
2026-11-12: a `devenv shell` needing a package no public cache has took 71 s
on msi (66 s of it the build) and 2.7 s in an acer environment afterwards,
the package signed `msi-ms7758-store-1`. Evaluation is not shared: a first
`devenv shell` still evaluates on each host (54 s for factum on msi).

A container that never gets ready is retried 3 times in 10 minutes and then stays `failed` (start limit). Each switch
calls `reset-failed` (clearing the limit) and restarts the active targets, `machines.target` among them, which starts
it again with a fresh allowance; by hand, `systemctl reset-failed container@<n>` first, because a 4th start inside the
10 minutes is refused ("repeated too quickly"). `dev-env-reset@<n>` clears it too, so a pool slot, reset every task
turn, never reaches it.

## Alerts

A runtime host (msi, acer, asus) posts to lenovo's ntfy topic `homelab-alerts` when
`container@<name>` or the egress proxy (`dev-env-egress`) fails, at once; when
the kernel kills a process in the pool (`oom_kill` of `environments.slice`
rose), within 2 minutes; and when the state directory or `/nix` has under 10G
free, within 2 minutes and then at most hourly per directory. A send that fails
is retried at the next 2 minute run. `sam.workers.ntfyUrl = null` turns all of
it off (`services.devEnvironments.alert` is the program they call).


## Pause and resume

`paused = true` on an instance stops its container at the next deploy and keeps it
stopped across boots: the host then declares no container and no unit for it, as
for a retired one, but nothing is removed, so its home, clone, agent transcript,
profiles and gcroots stay (the gcroots refresh and the activation script still
cover it). Its address and ssh alias stay too. Its
`memory.reserved` no longer counts toward the pool-fit assertion or the slice's
`MemoryLow`, so the pool's memory goes to the others. Flip it back and deploy:
the container starts and the agent is relaunched with `--continue` because the
transcript is still there. A stop kills what the agent was doing like a reboot
does: a tool call in flight is cut off (the transcript then ends in a tool use
without a result) and the resumed agent is told, once per start of the container, that whatever ran in the
environment was killed. There is no shutdown notice on a pause; send the agent
a "push your work" message first if it holds unpushed commits. A deploy that fails and is rolled back leaves the instance it stopped down until the next successful deploy.

## Permissions

A guest's Claude runs in bypassPermissions with `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1` (claude-code
2.1.311 or later, guests only), so a "Dangerous rm operation" never stops an unattended agent. Any Bash deny or ask
rule turns that variable off, so a guest drops the fleet's Bash deny rules; real hosts keep them. What still covers
each: force pushes (`--force`, `-f`, a `+ref`) meet the validate-bash hook and the pre-push guard; a push that skips the pre-push
gate (`--no-verify`, `-c core.hooksPath=`) meets the guests' own `no-verify-guard` PreToolUse hook, beside
validate-bash in the same Bash hook list, which denies with exit 2 and never asks (an asking hook would turn the
variable off for removals). The remote has no ruleset yet.

### Guest root and the host

nixpkgs' container module binds `/nix/var/nix/{profiles,gcroots}/per-container/<name>` read-write with an identity
idmap, so guest root there can create files owned by any host uid below 65536, root included. Both parents are
mounted `nosuid,nodev,noexec` (the state dir `nosuid,nodev`) on every host that declares instances or retired names,
whether or not one runs with `rootInGuest`, so such a file stays inert after its instance is paused; retiring an
instance deletes its per-container dirs; the host's root
readers there only follow links (the daemon's root scan, the gcroots unit's `ln -sfn` and `mv -T`), and what is left
is a disk-filling the guest already has through the daemon. Homes are never moved between id blocks: `<stateDir>/<name>/.id-base`, written with the home, must match the instance's block for its container to start. From another host, `ssh <name>.<prefix>` trusts each name's key on first use
(`~/.ssh/known_hosts_environments`), so a `rootInGuest` instance's own key is accepted there too. A `rootInGuest` name retired and
declared again gets a new key and is refused until `ssh-keygen -R <name>.<prefix> -f ~/.ssh/known_hosts_environments`;
plain instances share the host's one environment key, so theirs does not change.

## What fails at build

A wrong declaration fails evaluation with a message naming the option, never
at runtime (`nixos:workers-eval-test` holds one case per line):

- a name that is not `[a-z][a-z0-9-]`, longer than 11, the host's own name,
  already in `networking.hosts` or another `containers.<name>`, or hashing to
  another instance's address;
- an unknown `agent`; `model` or `prompt` with `agent = "none"`; an empty
  prompt; a model outside `[][A-Za-z0-9._:-]`; a `prompt` with no session
  surface to deliver it;
- sizes not in systemd syntax (`[1-9][0-9]*[KMGT]?`); reserves summing above
  the pool; instances on a host
  without `pool.memory`;
- a host interface address in `10.233.0.0/16`; a name both in `instances` and
  `retired`, or a `retired` name that is not a valid name; a `stateDir` outside
  `/var/lib/<name>`; `blockedNetworks` without the iptables firewall backend;
- the user missing, its declared uid differing, no linger (the surface runs in
  its user manager), a guest module turning sshd off, a relative key or
  credential path;
- a claude instance on a host without the `claude_oauth_token` sops secret,
  or no Herdr user service in the host's Home Manager;
- a `jumpHosts` target not pinned in `programs.ssh.knownHosts`, or a bad prefix.

The generated shell is `writeShellApplication` (shellcheck at build). The
agent's command line is a file in the store sourced by the guest's login shell,
so no user string is quoted through ssh; the prompt crosses one bash quoting
layer to Herdr.

## Reach it

- **Herdr, from lenovo**: `herdr --machine msi-ms7758 agent list` shows agent
  `<name>` in workspace `<name>`; drive it with
  `herdr --machine msi-ms7758 agent prompt <name> "<task>"`, or attach to the
  host's Herdr and use the pane directly. A pool session's turn is there the
  same way while it runs: agent `<task id>` in workspace `<slot> <task key>`.
- **ssh from lenovo**: `ssh <name>.msi` or `ssh <name>.acer` (a wildcard
  `Host *.<prefix>` with `ProxyJump` to the host, from `sam.workers.jumpHosts`;
  lenovo needs no per-instance config).
- **ssh on the host**: `ssh <name>` (or `<name>.<prefix>`), from
  `networking.hosts` and a per-instance `Host` block.

Every environment of a host presents one key, generated at activation as
`/var/lib/workers/ssh_host_ed25519_key` and bound read-only (never the host's
own sshd key, which root in a guest could otherwise use to pose as the host).
The host checks it against `/var/lib/workers/known_hosts` under the alias
`environments.<prefix>`; lenovo trusts it on first use, through the pinned
jump host, into `~/.ssh/known_hosts_environments`. Hostname inside:
`<prefix>-<name>`.

## What survives what

The root is ephemeral (rebuilt from the store at every start: the system part
stays reproducible and boots in seconds); the home is persistent, bound from
`/var/lib/workers/<name>/home` on the host. Repo clones, Claude transcripts
(`~/.claude`), `~/.claude.json`, shell history and caches live there. Home
Manager activates on it at every boot (collisions are kept as `*.backup`).

| Event | Effect |
|-------|--------|
| Deploy that changes nothing of it | nothing restarts |
| Fleet-wide guest change (a module, Home Manager, nixpkgs) | `reloadIfChanged`: the stock `ExecReload` switches the running guest live; the agent keeps running |
| Change of `memory` or `cpu` | the container unit's cgroup properties change at the daemon-reload, live |
| Change of `prompt` | nothing restarts; the prompt is only sent on a fresh start |
| Change of `agent`, `model`, credentials or bind mounts | `worker-<name>` restarts and, through `PartOf`, the container: a restart |
| Restart or host reboot | home kept; the workspace comes back and runs `claude --continue` when a transcript of `$HOME` exists, followed by a notice that its running work was killed, else a fresh `claude` with the prompt |
| Removed from the config, deployed | units stop, the workspace closes, the home is kept |
| Named in `retired`, deployed | activation moves `/var/lib/workers/<name>` to `/var/lib/workers/.trash/` (deleted a week later) and deletes its `/nix/var/nix/{profiles,gcroots}/per-container/<name>` |

`worker-<name>`'s unit file holds the instance's agent, model, address and bind
mounts and no store path, so a nixpkgs bump or a fleet-wide change never
restarts an environment. Work leaves an environment only by `git push` from
inside it.
The hook's log: `journalctl -u worker-herdr-<name>`.

## Made of

- `/nix/store`, the nix db and the daemon socket are the host's (stock
  containers), so `nix build` and devenv use the host's store; `lukas` is not a
  trusted user on acer, msi and asus.
- A nested sandbox cannot mount a full procfs in a guest (nspawn masks parts of
  `/proc`), so `modules/workers/nested-sandbox.nix` packages two wrappers that
  mount `subset=pid`: one for Claude's `sandbox.bwrapPath` (managed settings,
  which leave `sandbox.enabled` alone) and one as podman's `crun`. Verified
  in a deployed guest on acer (2026-11-12): a sandboxed `claude -p` Bash call
  sees only its own processes and cannot write to the home directory.
  `podman run` and `podman build` work with `--network=none` only (no
  `/dev/net/tun`); buildah is not on the guest's PATH. Inside, `free`, `uptime`
  and `sysctl` fail. The bwrap sandbox runs as mapped uid 0 holding only
  `CAP_SETFCAP` (more inside Claude's own nested namespace), not as the user and
  not capability-free: `id -u` prints 0, `tar --same-owner` and chown-like
  tools act as root, some tools refuse to run as root, and ssh picks root as its
  default user.
- lenovo hosts no environment, and eval refuses one: an environment holds its
  host user's SSH key, and lenovo's is the fleet's deploy key (`deploy` with
  passwordless sudo on every host, accepted from lenovo's address, which a
  guest's traffic leaves by). Its user is also a trusted Nix user.
- `~/.cache/nix` (Nix's fetcher and tarball caches) is one directory per host,
  bound writable into every environment: the first `devenv shell` in a new
  environment took 5.9 s on acer with it, 28 to 31 s without, for a repo the
  host had seen. A revision the host has not seen still builds once (238 s on
  acer). The price: environments of one host are not isolated from each other
  there, one can plant a fetcher-cache entry another reads (a locked input is
  checked against its hash, so that fails the fetch, it does not swap the
  source). The evaluation cache inside it is per environment: its rows are
  unsigned and name the derivation to build.
- `/run/work-locks` (`modules/core/work-locks.nix`) is the host's directory,
  bound read-only into every environment: `flock -o /run/work-locks/<lane>.lock`
  in a guest and on the host take the same lock, so one heavy job runs per
  physical host. The price: a guest that holds a lane, or leaves a stopped
  holder behind, stalls the host's heavy work and every other guest's until it
  ends. `host:locks` inside a guest sees only that guest's holders (`/proc/locks`
  is per PID namespace); run it on the host.
- The guest's nix sends the host's `max-jobs`, `cores`, substituters and keys:
  the daemon takes a client's values over its own, so a guest left on defaults
  lifts the host's build bounds and skips the fleet's store caches.
- The guest imports the fleet's `core/system.nix`, `core/users.nix`,
  `core/packages.nix`, the pinned known hosts and the Home Manager wiring
  every host gets (`fleetHome` in `flake-modules/nixos-configurations.nix`).
- `<nixpkgs>` in a guest is the nixpkgs its system is built from (`nix.nixPath`,
  no channels).
- The guest evaluates on the host's nixpkgs instance, so overlays and
  `nixpkgs.config` belong on the host; a guest overlay fails an assertion.
- Network: a veth pair, `10.233.<i>.1` host side and `10.233.<i>.2` inside,
  `i` hashed from the name (a collision fails eval); NAT for egress. DNS is
  the host's `resolv.conf` at start; the container waits up to 30 s for it to
  carry a nameserver. `services.devEnvironments.blockedNetworks` (the private
  and link-local ranges on acer, msi and asus) drops forwarding from `ve-*` to those
  networks and new connections from a guest to the host itself, DNS and the
  fleet's store caches (port 5000) excepted: an environment reaches the
  internet, not the LAN, another environment or its host.
- Headless guest: no Herdr server, repo-sweep or flake-update timers,
  gpg-agent, dconf or guest firewall; `flake-registry` is empty and `nixpkgs`
  resolves to the store's.
- Herdr's pane runs `worker-<name> attach [fresh|continue]` (the instance's
  entry point, also on the host's PATH): ssh, argv[0] named after the agent,
  into `fish -il -c 'source <store file>'`. A pool slot's pane exists only while
  a session turn runs: `worker-<slot> turn`, ssh named `claude` into
  `dtach -a` on the turn's agent terminal (`docs/records/execution-pool-contract.md`).
- The logins stay on the host. `dev-env-egress` (Caddy) listens per instance
  in `/run/dev-env-egress/<name>/`, bound read-only at `/run/egress`: the
  socket is the instance's identity. `anthropic.sock` adds the Claude login
  to `/v1/*`; the guest holds a placeholder and
  `ANTHROPIC_BASE_URL=http://127.0.0.1:4100` (`systemd-socket-proxyd`).
  With `egress.github.repos`, `github.sock` adds the host user's gh token
  (read from `hosts.yml` at each proxy start) to git smart-HTTP and
  `/repos/<owner>/<repo>` REST calls for those repos, everything else 403.
  It also refuses the repository's administration (rulesets, branch
  protection, collaborators, keys, hooks, transfer, Actions secrets,
  variables and runners, environments, invitations; PATCH, PUT and DELETE on
  the repository itself) and any URI with an encoded slash, backslash, dot or
  percent, `..` or `//`. Beyond that the list bounds which repository, not
  what is done to it, until App tokens (plan, phase 4). Git reaches it through `127.0.0.1:4102` (`insteadOf` for `https://github.com/`
  and `git@github.com:`), gh through `http_unix_socket` with a placeholder
  `GH_TOKEN`. Requests are in `journalctl -u dev-env-egress`, logger
  `<socket>-<name>`. A rotated token restarts the proxy: sops restarts it for
  the Claude login, a path unit on `hosts.yml` for gh's. Without a GitHub
  token in `hosts.yml` the proxy still starts and GitHub answers 401.
- Without `egress.github`, the host user's `~/.ssh/id_ed25519` and on acer
  `~/.config/gh/hosts.yml` are still bound read-only.
- The guest cannot reach Loki, so the host ships its platform records
  (`scripts/guest-records.py`): `dev-env-records` every 5 minutes for every
  declared instance, and `dev-env-records@<name>` before a retire or reset
  renames the home (`timeout 30 … || true`: Loki down never holds either).
  It reads `<stateDir>/<name>/home/.local/state/platform-records`
  (`pkgs/platform-record/platform_record.py`'s spool; the guest's `PLATFORM_RECORD_SHIPPER=host` makes the writer
  keep a record there alone, never trying Loki or keeping a retry queue the guest could not drain; a guest's
  `platform-record --status` says `"shipper": "host"`, and a `.retry` left from before that is inert, its lines
  in the spool), opening each path component
  without following a link, and the spool only as a regular file, its last
  2 MiB; a link or FIFO anywhere there skips that instance and fails the
  unit. The host sets every label: `job=platform`, `kind` from
  `services.devEnvironments.records.kinds` (the kinds `metrics/records.json`
  marks `guest`, `review` included; never `deploy`, `delivery` or
  `trash-sweep`, which a guest does not make),
  `host=<prefix>-<name>`. A line ships only if the whole of it parses as
  what `platform_record.py` writes: printable ASCII, no backslash or quote,
  `<date -Is> <kind>` then single-space `key=value` tokens, keys
  `[a-z_][a-z0-9_]*` not starting with `__` (Loki's own), values `[A-Za-z0-9_.,:/-]*` (paths, shas, drv names,
  comma lists), no key twice; what ships is rebuilt from the parsed fields,
  never the guest's bytes (Loki's logfmt splits at any byte up to 0x20,
  unquotes and decodes `\uXXXX`). Dropped and counted by reason in the unit's
  log: a line outside that grammar, one with a `host`, `job` or `kind` field
  (a guest cannot pose as the owner's host in a gate record), one whose
  `node` or `owner` names a fleet host (its hostname in any case, or its
  flake attribute: consumers attribute deploys and built or deferred checks
  by those fields), an unknown kind, a line over 4 KiB, a time ahead of
  now; lines older than Loki takes (167 h) are skipped. At most 500 lines
  per instance and run. Progress is the last handled line's hash and time
  in the unit's StateDirectory, out of every guest's reach. It runs as a
  dynamic user with `CAP_DAC_READ_SEARCH` alone (read any home, write
  nothing but its state and, for the timer's run, the textfile below), `IPAddressAllow` Loki's address only. The timer's run also writes
  `/run/dev-env-records-metrics/guest-records.prom` (through the group `dev-env-records-metrics`) for node-exporter:
  per `worker`, the lines still waiting and when it last got through; GuestRecordsNotShipping
  (`docs/alert-runbooks.md`) fires when lines wait and nothing shipped for 30 minutes.
  With `records.usage` set (acer: `1min`, the #494 spike) `dev-env-usage` pushes, in the same sandbox, one
  host-made `kind=usage` line per running instance: its container cgroup's `cpu_usec`, `user_usec`,
  `mem_current`, `mem_anon` (`memory.stat` anon, no page cache), `mem_peak` (lifetime, never reset) and
  `toplevel` (the conf's `SYSTEM_PATH`). It reads no guest file, and `usage` is not a guest kind.

## Working an issue in one

The declaration is the record of what runs where: commit the instance with the
issue it serves, deploy, and remove it when the work has landed.

1. Pick an issue; check it has no open PR already (`gh pr list --search "<n> in:body"`).
2. Declare the environment (name it after the issue) with the brief as its
   `prompt`, commit, deploy the host: the agent starts on it with no hand-over.
3. The brief says: read the issue, clone, run `devenv shell` once before the
   first commit (a fresh clone has no git hooks until then, so its push would
   skip the gate), read the repo's entry doc, work through the repo's
   `devenv tasks` (`sdlc:*` where the repo has `platform.sdlc`), heavy steps
   one at a time, log friction to `~/ENV-FEEDBACK.md`, stop with a written
   blocker when stuck, and when finished write `~/RESULT.md` (the PR's URL or
   the blocker). A follow-up goes in with
   `herdr --machine <host> agent prompt <name> '<text>'`.
4. A `blocked` agent is waiting on a question; answer it in its pane. `done`
   is not always finished: an agent that parked on a background gate reports
   `done` and resumes by itself, so read the pane (`shell still running`,
   `Waiting for N background`) and `ssh <name>.<prefix> cat RESULT.md` before
   merging or retiring.
   Keep every host's pool busy: when an environment is retired and an approved
   issue is ready, declare the next one in the same deploy.
5. Review is one independent subagent the agent spawns on its own diff. No
   second environment, no comment trail.
6. The agent pushes and opens the PR; the session driving it from lenovo merges.
7. Copy what `~/ENV-FEEDBACK.md` taught into `docs/environments-feedback.md`
   (one line each, with the fix or the open gap), then move the name to
   `retired` and deploy.

Tear down when done: an environment whose agent reports done and has no
approved follow-up issue is retired in the same sitting, after two checks in
its home: `git status` and `git log origin/main..` are empty in every clone
(nothing unpushed dies with the home), and `~/ENV-FEEDBACK.md` is copied out.
An idle environment still holds its 2G reserve and a slot in the pool. Hand it
the next approved issue only when one is ready now; otherwise retire and
declare a fresh one later (37 s).
