# Declared nspawn workers

A worker is a developer environment declared in a host's configuration: a stock
NixOS container (`containers.<name>`, systemd-nspawn) on acer-swift or
msi-ms7758 with the fleet's tooling (Claude Code, Codex, git, devenv), shown as
a workspace in the host's own Herdr with its agent running. A deploy that
declares it starts it; a deploy that no longer declares it removes it, with
everything it wrote. There is no operator command. Module:
`modules/workers/default.nix`. The hosts themselves are not workers
(`sam.herdr.worker` is set only inside the containers).

## Use

Edit the host's `sam.workers.instances` in `hosts/<host>/configuration.nix`:

```nix
sam.workers.instances = {
  fix-ci = { model = "sonnet"; prompt = "Fix the failing test in ~/nixos-config and push a branch."; };
  shell = { agent = "none"; };
};
```

Deploy the host (from lenovo; `just deploy-acer` for acer):

```sh
just deploy-msi
```

A few seconds after activation `herdr --machine msi-ms7758 agent list` shows
an agent named `fix-ci` in workspace `fix-ci`, idle on the given model, and the
prompt submitted. Drive it as any agent on that host
(`herdr --machine msi-ms7758 agent prompt fix-ci "<task>"`). To end it, remove
the entry and deploy again: the workspace closes and the environment is gone.
Work leaves a worker only by `git push` from inside it.

| Option | Default | Effect |
|--------|---------|--------|
| `agent` | `"claude"` | `claude` (`--dangerously-skip-permissions`), `codex` (`--dangerously-bypass-approvals-and-sandbox`), or `none` (a fish shell) |
| `model` | `null` | the agent's `--model` |
| `prompt` | `null` | sent once the agent is idle, at every start |
| `memoryMax`, `cpuQuota` | the host's `sam.workers.memoryMax` / `cpuQuota` | unit limits |

Names are at most 11 characters of `[a-z0-9-]` (the host's veth is
`ve-<name>`); eval fails otherwise. Each host has a `memoryBudget`, and
instances whose `memoryMax` adds up to more fail eval:

| Host | Budget | Default per instance (so at most) | Hostname inside (SSH alias on lenovo) |
|------|--------|-----------------------------------|----------------------------------------|
| acer-swift | 6G | 6G, 400% CPU (1) | `acer-<name>` |
| msi-ms7758 | 7G | 3584M, 300% CPU (2) | `msi-<name>` |

The committed config declares none.

## What a deploy does

- **Added instance**: `container@<name>` is new and wanted by `machines.target`
  (`autoStart`), so activation starts it. It wants `worker-herdr-<name>`
  (`BindsTo=` it, `Type=simple`, so the deploy does not wait for the agent),
  which as `lukas` waits for the host user's Herdr server and the worker's sshd,
  creates workspace `<name>`, runs the agent in its pane over ssh with the ssh
  process named after the agent (argv[0]) so Herdr detects it, names it
  `<name>`, and sends the prompt once idle.
- **Unrelated change**: neither unit changes, nothing restarts. The container
  restarts only if its own definition changes: its guest system, its
  `/etc/nixos-containers/<name>.conf`, or its `agent`/`model`/`prompt`. A
  restart is a fresh environment. `worker-herdr-<name>` has
  `restartIfChanged = false`: a change to this module or `pkgs.herdr` alone
  never kills a running agent.
- **Removed instance**: activation stops both units (the hook first, which
  closes the workspace), the ephemeral root goes with the container, and the
  container's `ExecStopPost` removes the stock module's
  `/nix/var/nix/{profiles,gcroots}/per-container/<name>`.
- **Host reboot**: declared instances start again, fresh.

The hook's log: `journalctl -u worker-herdr-<name>`.

## What it is made of

- Root is ephemeral (`ephemeral = true`, under `/run`): nothing survives a stop
  or a reboot.
- `/nix/store` and the nix db are the host's, read-only, and `NIX_REMOTE=daemon`
  with the host's daemon socket bound in (all stock `containers.*`): `nix build`
  and devenv in a worker use the host daemon, its store and its substituters.
  The builds run in the host daemon's cgroup, not under the worker's limits.
  `lukas` is not a trusted user on these hosts (roles/homelab-agent.nix), so a
  flake's extra substituters are ignored, as on the host.
- The guest is the fleet's own modules: `core/system.nix`, `core/users.nix`
  (lukas, uid 1000, the same authorized keys), `core/packages.nix`, the pinned
  known hosts, and the same Home Manager wiring every host gets
  (`fleetHome` in `flake-modules/40-outputs-nixos.nix`: Claude Code, Codex,
  skills, settings, Herdr and the fish launchers, git). Home Manager activates
  at every boot, since the home starts empty.
- Network: a veth pair, `10.233.<i>.1` on the host and `10.233.<i>.2` in the
  worker, where `i` (1..254) comes from a hash of the name, so adding or
  removing another instance never renumbers (and so restarts) this one; a
  collision fails eval (rename one). NAT for egress, and an unreachable route
  for the rest of `10.233.0.0/16` so an address with no worker fails at once.

## Credentials

Bound read-only from the host user, nothing new and no secret changed:

| Host file | In the worker | For |
|-----------|---------------|-----|
| `/run/secrets/claude_oauth_token` (sops, `sam.hostSecrets`) | `/run/secrets/claude_oauth_token` | Claude Code, via the fish init that reads it on the hosts |
| `~/.ssh/id_ed25519` (`sam.workers.sshKey`) | `~/.ssh/id_ed25519` | `git push` (GitHub over SSH, `url.insteadOf`) |
| `~/.config/gh/hosts.yml` (`sam.workers.ghHostsFile`, acer only) | `~/.config/gh/hosts.yml` | `gh` |

Codex has no credential on acer or msi (no `openai_api_key` secret for them, no
`~/.codex/auth.json`), so `agent = "codex"` starts Codex at its sign-in screen;
it needs a secret for those hosts first (owner decision). msi's `lukas` has no
gh login, so msi workers have no `gh`. A rotated token reaches a worker at its
next start.

## Reach it

The host's Herdr pane reaches the worker over ssh with the host user's key
(`~/.ssh/id_ed25519.pub`, bound read-only and listed in the worker's
`AuthorizedKeysFile`) and checks the worker's key, which is its host's own
(bound read-only), under the host's pinned name (`HostKeyAlias`). For
debugging, lenovo has an SSH alias per declared instance
(`sam.workers.remotes`, from each host's `sam.workers.aliases`):
`ssh msi-fix-ci` goes through `msi-ms7758` (`ProxyJump`) to the worker's
address; deploy lenovo too for a new alias.
