# Ephemeral nspawn workers

A worker is a stock NixOS container (`containers.worker-<n>`, systemd-nspawn) on
acer-swift or msi-ms7758 that boots on demand, shows up as a workspace running
its Claude Code in the host's own Herdr, and is wiped when it stops. The hosts themselves are not workers
(`sam.herdr.worker` is set only inside the containers). Module:
`modules/workers/default.nix`.

| Host | Workers | Hostname inside (SSH alias on lenovo) | Limits each |
|------|---------|----------------------------------------|-------------|
| acer-swift | `worker-1` | `acer-w1` | 6G, 400% CPU |
| msi-ms7758 | `worker-1`, `worker-2` | `msi-w1`, `msi-w2` | 3584M, 300% CPU |

## Operate

The whole flow is two stock commands, as `lukas` (a polkit rule allows exactly
the `container@worker-<n>.service` units, no sudo), on the host or from lenovo:

```sh
ssh msi-ms7758 systemctl start container@worker-1   # boots it; a few seconds later it is a Herdr workspace
ssh msi-ms7758 systemctl stop container@worker-1    # the workspace closes, everything the worker wrote is gone
```

Everything else is automatic. Starting the container starts
`worker-herdr@<n>.service` (wanted by it, `BindsTo=` it), which, as `lukas`:

1. waits for the host user's Herdr server (the lingering user unit
   `herdr.service`, session `default`, the one lenovo has saved as machine
   `acer-swift` / `msi-ms7758`) and for the worker's sshd;
2. creates the workspace `worker-<n>` there; its pane runs
   `ssh -tt lukas@10.233.<n>.2 'fish -il -c "claude --dangerously-skip-permissions"'`
   with the ssh process named `claude` (argv[0]), so Herdr detects a Claude agent
   in the pane and reads its status (idle, working, done, blocked) from the
   screen and title as for a local claude;
3. names the agent `worker-<n>` once claude is idle.

Any stop of the container (`systemctl stop`, `sam.workers.runtimeMaxSec`, host
shutdown) stops `worker-herdr@<n>` first, which closes the workspace.

From lenovo the coordinator drives it as any agent on that host:

```sh
herdr --machine msi-ms7758 agent list                      # agent "claude", name worker-1
herdr --machine msi-ms7758 agent prompt worker-1 "<task>"  # the task; /model the same way to switch model
```

To start a worker with a model and a first task, put them in
`~/.config/workers/worker-<n>.env` on the host before the start (read at every
start until removed):

```sh
WORKER_MODEL=sonnet
WORKER_PROMPT=Fix the failing test in ~/nixos-config and push a branch.
```

Work leaves a worker only by `git push` from inside it. If one will not stop:
`machinectl terminate worker-1`. The hook's log:
`journalctl -u worker-herdr@1`.

## What it is made of

- Root is ephemeral (`ephemeral = true`, under `/run`, tmpfs): nothing survives a
  stop or a host reboot, and `autoStart = false`, so a reboot starts none. The
  only host-side residue is the empty
  `/nix/var/nix/{profiles,gcroots}/per-container/worker-<n>` directories the
  stock module creates.
- `/nix/store` and the nix db are the host's, read-only, and `NIX_REMOTE=daemon`
  with the host's daemon socket bound in (all stock `containers.*`): `nix build`
  and devenv in a worker use the host daemon, its store and its substituters.
  The builds run in the host daemon's cgroup, not under the worker's limits.
  `lukas` is not a trusted user on these hosts (roles/homelab-agent.nix), so a
  flake's extra substituters are ignored, as on the host.
- The guest is the fleet's own modules: `core/system.nix`, `core/users.nix`
  (lukas, uid 1000, the same authorized keys), `core/packages.nix`, the pinned
  known hosts, and the same Home Manager wiring every host gets
  (`fleetHome` in `flake-modules/40-outputs-nixos.nix`: Claude Code, skills,
  settings, Herdr and the fish `claude` launcher, git). Home Manager activates at
  every boot (`home-manager-lukas.service`), since the home starts empty.
- Network: a veth pair, `10.233.<n>.1` on the host, `10.233.<n>.2` in worker n,
  NAT for egress (`networking.nat`), and an unreachable route for the rest of
  `10.233.0.0/16` so a stopped worker fails at once instead of timing out.

## Credentials

Bound read-only from the host user, nothing new and no secret changed:

| Host file | In the worker | For |
|-----------|---------------|-----|
| `/run/secrets/claude_oauth_token` (sops, `sam.hostSecrets`) | `/run/secrets/claude_oauth_token` | Claude Code, via the fish init that reads it on the hosts |
| `~/.ssh/id_ed25519` (`sam.workers.sshKey`) | `~/.ssh/id_ed25519` | `git push` (GitHub over SSH, `url.insteadOf`) |
| `~/.config/gh/hosts.yml` (`sam.workers.ghHostsFile`, acer only) | `~/.config/gh/hosts.yml` | `gh` |

msi's `lukas` has no gh login, so msi workers have no `gh` until one exists:
`gh auth login` as lukas on msi once, then set `ghHostsFile` there. A rotated
token reaches a worker at its next start.

## Reach it

The host's Herdr pane reaches the worker over ssh with the host user's key
(`~/.ssh/id_ed25519.pub`, bound read-only and listed in the worker's
`AuthorizedKeysFile`) and checks the worker's key, which is its host's own
(bound read-only), under the host's pinned name (`HostKeyAlias`). For
debugging, lenovo has an SSH alias per worker (`sam.workers.remotes`):
`ssh msi-w1` goes through `msi-ms7758` (`ProxyJump`) to the worker's private
address.

## Add one, deploy

Raise `sam.workers.count` in the host's `configuration.nix` (limits beside it),
then deploy the host (and lenovo, for the new SSH alias):

```sh
just deploy-acer     # or just deploy-msi; both build on the host (remoteBuild)
just deploy-lenovo
```
