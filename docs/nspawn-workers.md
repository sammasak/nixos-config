# Developer environments (nspawn)

An environment is a long-running developer machine declared in a worker host's
configuration: a stock NixOS container (`containers.<name>`, systemd-nspawn) on
acer-swift or msi-ms7758 with the fleet's tooling (Claude Code, Codex, git, gh,
devenv), its own persistent home, and a workspace in the host's Herdr with the
agent running in it. It runs while declared; its home is deleted only once its
name is in `retired`. There is no operator command. Modules:
`modules/workers/core.nix` (`services.devEnvironments`, nothing of this
fleet: the part meant for publishing) and `modules/workers/default.nix`, the
fleet adapter (`sam.workers.*`, the fleet's guest modules, credentials and the
Herdr workspace as the session surface).

## Declare one

In `hosts/<host>/configuration.nix`, then deploy that host (`just deploy-msi`,
`just deploy-acer`):

```nix
sam.workers.instances = {
  fix-ci = { model = "sonnet"; prompt = "Fix issue #123 in sammasak/nixos-config, end to end."; };
  shell = { agent = "none"; };
};
```

| Option | Default | Effect |
|--------|---------|--------|
| `agent` | `"claude"` | `claude` (`--dangerously-skip-permissions`), `codex` (not signed in on these hosts), or `none` (a fish shell) |
| `model` | `null` | the agent's `--model` |
| `prompt` | `null` | sent once the agent is idle, only on a start with no earlier Claude session |
| `credentials` | `null` | which of the host's credentials it gets (`id_ed25519`, `gh-hosts.yml`); `null` is all. `[ ]` is an agent that cannot push |
| `egress.github.repos` | `[ ]` | `owner/repo` the instance reaches through the host's proxy (git and REST); non-empty, it gets neither credential; a repo whose devenv imports a private input needs that input listed too (factum and herman need `sammasak/devenv-platform`), else no `devenv shell` works; git and nix fetch it through the proxy rewrite without an SSH key |
| `egress.github.graphql` | `false` | also pass GraphQL, which no repository list bounds; nearly every `gh pr`/`gh issue` command needs it |
| `telemetry` | `false` | the guest's Claude exports OTLP metrics and events (no content) as `host.name=<host>,worker.name=<name>` to its `127.0.0.1:4319`, which `otlp.sock` passes (`POST /v1/metrics` and `/v1/logs` only) to the host's `native-otel-relay`; the relay adds the token, which never enters the guest. Needs `sam.profile.nativeOtel` on the host, else evaluation fails; setting `sam.claude.telemetry` in a guest module instead fails too. On nowhere yet ([native-otel-canary.md](native-otel-canary.md)) |
| `memory.reserved` | `"2G"` | `MemoryMin`: never reclaimed for a neighbour; above it, whatever the pool has idle |
| `cpu.reserved` | `2` | cores: `CPUWeight` 100 per core, its share under contention; idle cores are all usable |
| `rootInGuest` | `false` | its own 65536 uids (`--private-users`): guest root is an unprivileged host uid, and the user gets passwordless sudo. Its home and caches are owned on disk by its mapped ids (not id-mapped), so the option needs a fresh instance: an existing environment toggled either way refuses to start until it is retired or declared under a new name, it has its own sshd key and HostKeyAlias `<name>.environments.<prefix>`, and the state dir and per-container profiles and roots are mounted nosuid. Ran on msi (root1, root2) |

Host-wide: `sam.workers.pool.memory` (below) and `sam.workers.ntfyUrl` (null, or the ntfy topic that hears of failures, see Alerts).

Every environment of a host runs in `environments.slice`, whose `MemoryMax` is
the host's `sam.workers.pool.memory` (protecting k3s and the host) and whose
`MemoryLow` is the sum of the reserves. An environment has no ceiling of its
own and the pool no `MemoryHigh`: the only limit is the pool's `MemoryMax`,
with the pool's swap (zram) capped at a quarter of it, so one gate alone uses what
its neighbours leave idle, down to their reserves (`MemoryMin`). nix builds
run in the host's daemon, outside the pool; acer and msi bound that daemon
(2 jobs of 2 cores, `MemoryHigh` 4G, `MemoryMax` 6G), so a build
fails before k3s or the host does. msi powers off at 21:00
(Mon-Fri window); its environments come back at its next boot.
Inside, the cgroup files read `max`: `/etc/dev-environment` holds these limits as shell `key=value` (bytes: `memory_reserved`, `pool_memory`, `pool_swap`; `cpu_weight`, `nix_max_jobs`, `nix_cores`).

## Sizing

Reserved per environment, spiking allowed. Measured on both hosts (8 cores,
16G RAM, 7.8G zram) under the earlier hard caps: acer `demo` (6G cap,
CPUQuota 390%) peaked at 5.2G of which 1.1G anon, the rest page cache, and was
CPU-throttled 947 s of 1275 s used while cores sat idle; msi `skills91`
(3584M cap, 300%) hit `memory.max` 20138 times, swapped 218M and was throttled
591 s of 869 s. Hard caps cost real time and bought nothing on an idle host.

| Host | Pool | Prefix | Host's own use | At most (by reserve) | Recommended |
|------|------|--------|----------------|----------------------|-------------|
| acer-swift | 7G, 8 cores | `acer` | k3s pods 4.6G, system 2.9G | 3 | 2 |
| msi-ms7758 | 10G, 8 cores | `msi` | about 2.8G | 5 | 3 |

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
| Host reboot or redeploy | nothing | container autostarts 6 to 7 s into userspace, the agent is back in Herdr at 14 to 15 s and resumes its conversation; home and the shared `~/.cache/nix` are intact (`devenv shell` 7 to 10 s). Whatever ran in the environment is killed and not restarted: the resumed agent is told so, once per start of the container, and re-checks its work. msi tells its agents at 20:40 (`sam.workers.shutdownNotice`) to push before the 21:00 poweroff |
| Resize (`memory`, `cpu`) or edit `prompt` | edit the declaration, deploy | live, no restart (checked on msi: 6G to 5G and back, same container start time) |
| Change `agent`, `model`, credentials | edit the declaration, deploy | restarts that one environment, home kept |
| Stop | remove the declaration, deploy | units stop, home kept |
| Retire | move the name from `instances` to `retired`, deploy; drop it from `retired` any time later | 23 s; profile and GC roots deleted, the home moved to `<stateDir>/.trash/<name>-<date>` and deleted at the first activation a week later (recover it with `mv` meanwhile) |

Removing a declaration only stops the environment: a rollback, a deploy from
an older checkout or acer's weekly auto-upgrade from GitHub `main` lacks
instances too, and must not delete their homes. Only a name in `retired` is
deleted, and only while its container is stopped; eval refuses a name in both.

The store is the host's, read-only, with builds going through the host's
daemon, so anything one environment or the host built is there for the next.
The host's weekly/monthly collection would not see an environment's devenv
roots (the daemon records them under the guest's path), so
`dev-environments-gcroots` roots them from each home right before `nix-gc`
(it searches the whole home, pruning `node_modules`, `target` and `.git`).
A timer also runs it at boot and every 15 minutes, because the daemon collects
by itself once `min-free` is set; a path a guest built within the last interval
is the remaining exposure.

Across hosts, lenovo, acer and msi each serve their store to the LAN as a
binary cache (`modules/core/store-cache.nix`, harmonia on port 5000) and
substitute from the always-on ones ahead of cache.nixos.org: what one machine
built the others download. msi serves its store while it is up but nobody
substitutes from it: with msi powered off, every path lookup on acer waited
out the 3 s connect timeout one after another (180 lookups, 9 minutes of a
first `devenv` evaluation, measured 2026-11-12). Each cache signs with a key its host generated on first
start (`/var/lib/store-cache/`, never in git); the public halves are in the
module. A peer that is rebooting costs a 3 s connect timeout per lookup, then
Nix builds. An environment's nix is a client of its host's daemon, so its builds
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
10 minutes is refused ("repeated too quickly").

## Alerts

A runtime host (msi, acer) posts to lenovo's ntfy topic `homelab-alerts` when
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
each: force pushes (`--force`, `-f`, a `+ref`) meet the validate-bash hook and the pre-push guard; `kubectl delete`
of a PV or namespace meets validate-bash and Kyverno, and a guest has no kubeconfig; a push that skips the pre-push
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
- sizes not in systemd syntax (`[1-9][0-9]*[KMGT]?`); `reserved` above `max`,
  `max` above the pool, reserves summing above the pool; instances on a host
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
  host's Herdr and use the pane directly.
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
  trusted user on acer and msi.
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
- The guest's nix sends the host's `max-jobs`, `cores`, substituters and keys:
  the daemon takes a client's values over its own, so a guest left on defaults
  lifts the host's build bounds and skips the fleet's store caches.
- The guest imports the fleet's `core/system.nix`, `core/users.nix`,
  `core/packages.nix`, the pinned known hosts and the Home Manager wiring
  every host gets (`fleetHome` in `flake-modules/40-outputs-nixos.nix`).
- `<nixpkgs>` in a guest is the nixpkgs its system is built from (`nix.nixPath`,
  no channels).
- Network: a veth pair, `10.233.<i>.1` host side and `10.233.<i>.2` inside,
  `i` hashed from the name (a collision fails eval); NAT for egress. DNS is
  the host's `resolv.conf` at start; the container waits up to 30 s for it to
  carry a nameserver. `services.devEnvironments.blockedNetworks` (the private
  and link-local ranges on acer and msi) drops forwarding from `ve-*` to those
  networks and new connections from a guest to the host itself, DNS and the
  fleet's store caches (port 5000) excepted: an environment reaches the
  internet, not the LAN, the cluster, another environment or its host.
- Headless guest: no Herdr server, repo-sweep or flake-update timers,
  gpg-agent, dconf or guest firewall; `flake-registry` is empty and `nixpkgs`
  resolves to the store's.
- Herdr's pane runs `worker-<name> attach [fresh|continue]` (the instance's
  entry point, also on the host's PATH): ssh, argv[0] named after the agent,
  into `fish -il -c 'source <store file>'`.
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

The committed config declares none.

## Store options tried

1. **Shared host daemon (what runs).** A guest sees the host `/nix/store` read-only and builds and fetches through
   the host's nix daemon. It is the only option that makes a fresh clone's `devenv shell` work, and a path any
   guest builds is there for all of them. The price is that the daemon is a write path from guest to host store.
2. **Read-only store, no daemon socket** (branch `feat/no-daemon-socket`). Running binaries, `nix eval`, locked
   github flakes and a `devenv shell` in an already-entered project work. A fresh clone's `devenv shell` fails: it
   must add a new `devenv-files.drv` to the store, which nothing can do without a writable store.
3. **Per-environment `local-overlay` tier** (branch `feat/store-overlay`). Fails on a live host store: the lower
   store opens the host db immutable and so misses everything in its WAL, so paths the host registered since the
   last checkpoint, the guest's own system among them, are "not valid" and Home Manager fails. It would need a
   frozen lower store (a snapshot), not the live one. Both branches stay unmerged as the record.
4. **Root-built fetcher-cache seed for a new `rootInGuest` environment** (branch `feat/fetch-cache-seed`, dropped).
   It warmed a new environment's empty `~/.cache/nix`, but each repo pins its own nixpkgs (six distinct revisions
   across nixos-config, factum and herman), so a seed made from one lock misses the others. Measured: a shared nixpkgs
   pin alone shares 13 of 262 store paths (the toolchain closure is keyed by nixpkgs and rust-overlay together), and
   copying an older pin set breaks a repo that needs a newer Rust. The lever is one pin set (nixpkgs, rust-overlay,
   devenv, git-hooks) owned by devenv-platform at the newest revision any repo needs.

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
