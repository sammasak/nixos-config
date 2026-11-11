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
| `memory.reserved` | `"2G"` | `MemoryLow`: guaranteed, kept from reclaim |
| `memory.max` | `"6G"` | `MemoryMax`, the spike ceiling; `MemoryHigh` (reclaim and throttle first) is 90% of it |
| `cpu.reserved` | `2` | cores: `CPUWeight` 100 per core, its share under contention; idle cores are all usable |

Every environment of a host runs in `environments.slice`, whose `MemoryMax` is
the host's `sam.workers.pool.memory` (protecting k3s and the host) and whose
`MemoryLow` is the sum of the reserves. Swap (zram) stays allowed. nix builds
run in the host's daemon, outside the pool; acer and msi bound that daemon
like lenovo (2 jobs of 2 cores, `MemoryHigh` 4G, `MemoryMax` 6G), so a build
fails before k3s or the host does. msi powers off at 21:00
(Mon-Fri window); its environments come back at its next boot.

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

Burst, measured on msi 2026-11-11 with the 2G reserve / 6G max defaults: a
process allocating 5G ran untouched (peak 5.4G, no events); one allocating 7G
also finished (8.5 s against 2.4 s: reclaim began at `MemoryHigh`, 1.9G went to
zram swap, 0 OOM kills, container and agent stayed up). Swap per environment is
capped at half its max, so a true runaway (past max plus swap, 9G by default)
loses that one process to the kernel, never the container, and cannot fill the
host's swap.

## Lifecycle

| Step | How | Measured (msi) |
|------|-----|----------------|
| Create | add `instances.<name>` on the host, deploy | 37 s deploy, guest boots in 6.8 s |
| First use of a repo | clone, `devenv shell` | 25 s (skills), 32 s (herman): evaluation only, every store path comes from the host's store; 0.1 to 0.3 s after that |
| Work | brief the agent through Herdr, or `ssh <name>.<prefix>` | hours to days; the home persists |
| Host reboot or redeploy | nothing | container autostarts, agent resumes its conversation |
| Resize (`memory`, `cpu`) or edit `prompt` | edit the declaration, deploy | live, no restart (resize needs a runtime check) |
| Change `agent`, `model`, credentials | edit the declaration, deploy | restarts that one environment, home kept |
| Stop | remove the declaration, deploy | units stop, home kept |
| Retire | move the name from `instances` to `retired`, deploy; drop it from `retired` any time later | 23 s; home, profile and GC roots deleted |

Removing a declaration only stops the environment: a rollback, a deploy from
an older checkout or acer's weekly auto-upgrade from GitHub `main` lacks
instances too, and must not delete their homes. Only a name in `retired` is
deleted, and only while its container is stopped; eval refuses a name in both.

The store is the host's, read-only, with builds going through the host's
daemon, so anything one environment or the host built is there for the next.
The host's weekly/monthly collection would not see an environment's devenv
roots (the daemon records them under the guest's path), so
`dev-environments-gcroots` roots them from each home right before `nix-gc`
(only `nix-gc.service` runs it; it searches the whole home, pruning
`node_modules`, `target` and `.git`).

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
  `max` above the pool, reserves summing above the pool, reserved cores
  summing above `pool.cores`; instances on a host without `pool.memory` or
  `pool.cores`;
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
| Change of `memory` or `cpu` | the container unit's cgroup properties change at the daemon-reload, live (needs a runtime check) |
| Change of `prompt` | nothing restarts; the prompt is only sent on a fresh start |
| Change of `agent`, `model`, credentials or bind mounts | `worker-<name>` restarts and, through `PartOf`, the container: a restart |
| Restart or host reboot | home kept; the workspace comes back and runs `claude --continue` when a transcript of `$HOME` exists, else a fresh `claude` with the prompt |
| Removed from the config, deployed | units stop, the workspace closes, the home is kept |
| Named in `retired`, deployed | activation deletes `/var/lib/workers/<name>` and its `/nix/var/nix/{profiles,gcroots}/per-container/<name>` |

`worker-<name>`'s unit file holds the instance's agent, model, address and bind
mounts and no store path, so a nixpkgs bump or a fleet-wide change never
restarts an environment. Work leaves an environment only by `git push` from
inside it.
The hook's log: `journalctl -u worker-herdr-<name>`.

## Made of

- `/nix/store`, the nix db and the daemon socket are the host's (stock
  containers), so `nix build` and devenv use the host's store; `lukas` is not a
  trusted user there.
- The guest imports the fleet's `core/system.nix`, `core/users.nix`,
  `core/packages.nix`, the pinned known hosts and the Home Manager wiring
  every host gets (`fleetHome` in `flake-modules/40-outputs-nixos.nix`).
- `<nixpkgs>` in a guest is the nixpkgs its system is built from (`nix.nixPath`,
  no channels).
- Network: a veth pair, `10.233.<i>.1` host side and `10.233.<i>.2` inside,
  `i` hashed from the name (a collision fails eval); NAT for egress. DNS is
  the host's `resolv.conf` at start; the container waits up to 30 s for it to
  carry a nameserver. `services.devEnvironments.blockedNetworks` (off; set it
  to `[ "192.168.10.0/24" ]` to cut the LAN and the k3s API, DNS excepted)
  drops forwarding from `ve-*` to those networks.
- Headless guest: no Herdr server, repo-sweep or flake-update timers,
  gpg-agent, dconf or guest firewall; `flake-registry` is empty and `nixpkgs`
  resolves to the store's.
- Herdr's pane runs `worker-<name> attach [fresh|continue]` (the instance's
  entry point, also on the host's PATH): ssh, argv[0] named after the agent,
  into `fish -il -c 'source <store file>'`.
- Credentials, bound read-only, nothing new: the host's
  `/run/secrets/claude_oauth_token`, the host user's `~/.ssh/id_ed25519`
  (`git push`), and on acer `~/.config/gh/hosts.yml` (msi's `lukas` has no gh
  login). A rotated token reaches an environment at its next start.

The committed config declares none.

## Working an issue in one

The declaration is the record of what runs where: commit the instance with the
issue it serves, deploy, and remove it when the work has landed.

1. Pick an issue; check it has no open PR already (`gh pr list --search "<n> in:body"`).
2. Declare the environment (name it after the issue), commit, deploy the host.
3. Hand over the brief from lenovo: `herdr --machine <host> agent prompt <name> '<brief>'`.
   The brief says: read the issue, clone, work through the repo's `devenv tasks`
   (`sdlc:*` where the repo has `platform.sdlc`), heavy steps one at a time,
   log friction to `~/ENV-FEEDBACK.md`, stop with a written blocker when stuck.
4. A `blocked` agent is waiting on a question; answer it in its pane.
5. Review is one independent subagent the agent spawns on its own diff. No
   second environment, no comment trail.
6. The agent pushes and opens the PR; the session driving it from lenovo merges.
7. Copy what `~/ENV-FEEDBACK.md` taught into `docs/environments-feedback.md`
   (one line each, with the fix or the open gap), then move the name to
   `retired` and deploy.
