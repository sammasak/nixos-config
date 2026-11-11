# Developer environments (nspawn)

An environment is a long-running developer machine declared in a worker host's
configuration: a stock NixOS container (`containers.<name>`, systemd-nspawn) on
acer-swift or msi-ms7758 with the fleet's tooling (Claude Code, Codex, git, gh,
devenv), its own persistent home, and a workspace in the host's Herdr with the
agent running in it. It runs while declared and is deleted, files included,
once a deploy no longer declares it. There is no operator command. Module:
`modules/workers/default.nix`.

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
| `memoryMax`, `cpuQuota` | the host's `sam.workers.memoryMax` / `cpuQuota` | unit limits |

Names: at most 11 of `[a-z0-9-]`. Instances whose `memoryMax` adds up to more
than the host's `memoryBudget` fail eval:

| Host | Budget | Default per instance (so at most) | Prefix |
|------|--------|-----------------------------------|--------|
| acer-swift | 6G | 6G, 400% CPU (1) | `acer` |
| msi-ms7758 | 7G | 3584M, 300% CPU (2) | `msi` |

nix builds run in the host's daemon, outside these limits. msi powers off at
21:00 (Mon-Fri window); its environments come back at its next boot.

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

Both present the worker host's own key (bound read-only), pinned under the
host's name (`HostKeyAlias`), so there is no host-key prompt. Hostname inside:
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
| Change to its own declaration (`agent`, `model`, `prompt`, limits) | `worker-<name>` restarts and, through `PartOf`, the container: a restart |
| Restart or host reboot | home kept; the workspace comes back and runs `claude --continue` when a transcript of `$HOME` exists, else a fresh `claude` with the prompt |
| Removed from the config, deployed | units stop, the workspace closes, and activation deletes `/var/lib/workers/<name>` and its `/nix/var/nix/{profiles,gcroots}/per-container/<name>` |

The activation script deletes only directories under `/var/lib/workers` (only
this module writes there) whose name is no longer declared and whose container
is not running. Work leaves an environment only by `git push` from inside it.
The hook's log: `journalctl -u worker-herdr-<name>`.

## Made of

- `/nix/store`, the nix db and the daemon socket are the host's (stock
  containers), so `nix build` and devenv use the host's store; `lukas` is not a
  trusted user there.
- The guest imports the fleet's `core/system.nix`, `core/users.nix`,
  `core/packages.nix`, the pinned known hosts and the Home Manager wiring
  every host gets (`fleetHome` in `flake-modules/40-outputs-nixos.nix`).
- Network: a veth pair, `10.233.<i>.1` host side and `10.233.<i>.2` inside,
  `i` hashed from the name (a collision fails eval); NAT for egress. DNS is
  the host's `resolv.conf` at start; the container waits up to 30 s for it to
  carry a nameserver.
- Credentials, bound read-only, nothing new: the host's
  `/run/secrets/claude_oauth_token`, the host user's `~/.ssh/id_ed25519`
  (`git push`), and on acer `~/.config/gh/hosts.yml` (msi's `lukas` has no gh
  login). A rotated token reaches an environment at its next start.

The committed config declares none.
