# Ephemeral nspawn workers

A worker is a stock NixOS container (`containers.worker-<n>`, systemd-nspawn) on
acer-swift or msi-ms7758 that boots on demand, runs Claude Code under Herdr, and
is wiped when it stops. The hosts themselves are not workers
(`sam.herdr.worker` is set only inside the containers). Module:
`modules/workers/default.nix`.

| Host | Workers | Herdr label / SSH alias | Limits each |
|------|---------|-------------------------|-------------|
| acer-swift | `worker-1` | `acer-w1` | 6G, 400% CPU |
| msi-ms7758 | `worker-1`, `worker-2` | `msi-w1`, `msi-w2` | 3584M, 300% CPU |

## Operate

Three stock commands, as `lukas` (a polkit rule allows exactly the
`container@worker-<n>.service` units, no sudo), on the host or over ssh from
lenovo:

```sh
ssh acer-swift systemctl start container@worker-1            # only an nspawn boot: the system is already in the host store
herdr machine add acer-w1 --label acer-w1 --remote-session default   # it now shows in Herdr; spawn agents with herdr --machine acer-w1
herdr machine remove "$(herdr machine list | awk '$2=="acer-w1"{print $1}')"   # take it out of Herdr
ssh acer-swift systemctl stop container@worker-1             # everything the worker wrote is gone
```

Work leaves a worker only by `git push` from inside it. A worker still running
after `sam.workers.runtimeMaxSec` (default 8h) is stopped, and so wiped. If one
will not stop: `machinectl terminate worker-1`.

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
  every boot (`home-manager-lukas.service`), since the home starts empty;
  lingering starts the Herdr server.
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

lenovo has an SSH alias per worker (from each host's `sam.workers`,
`sam.workers.remotes`): `ssh acer-w1` goes through `acer-swift` (`ProxyJump`) to
the worker's private address. A worker presents its host's SSH key, bound
read-only, and the alias checks it under the host's pinned name
(`HostKeyAlias`), so Herdr's strict checking passes. Workers are not declared
Herdr machines: save one when it starts and remove it when it stops, so a
stopped worker never sits in the sidebar.

## Add one, deploy

Raise `sam.workers.count` in the host's `configuration.nix` (limits beside it),
then deploy the host and lenovo (lenovo learns the new alias and label):

```sh
just deploy-acer     # or just deploy-msi; both build on the host (remoteBuild)
just deploy-lenovo
```
