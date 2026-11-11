# Agent-runtime interactive sessions: the host's Claude Code in nspawn

An interactive session is an instance whose payload runs under a PTY the runtime owns, so a person
(or a Herdr coordinator) can watch it and type into it from the host. The `claude-session` template
uses it to run the **same Claude Code as the host**: the same `pkgs.claude-code` store path and the
same Home Manager-rendered `CLAUDE.md`, skills, agents, hooks and settings, in bypass mode, with the
instance as the sandbox. There is no wrapper program; the payload is `claude` itself.
`claude-coder` (`docs/agent-runtime-coder.md`) is unchanged and stays the non-interactive path.

## Use

On a host that admits the template (acer-swift, msi-ms7758), as the session user, in a Herdr pane:

```sh
agent-runtime-session run --task OWNER/REPO#N [ID]   # preflight, create, start, attach
agent-runtime-session list                           # running sessions, one JSON line each
agent-runtime-session attach ID                      # rejoin after a detach or a closed pane
agent-runtime-session end ID                         # cancel, export, destroy; prints outcome and bundle
```

- Detach with `Ctrl-\`. Detaching, or closing the pane, leaves the session running.
- When the program exits (`/exit` in Claude Code), or on `end`, the instance is exported and
  destroyed and the bundle is `/var/lib/agent-runtime/exports/<ID>.runs/latest`. `end` is
  idempotent: a second caller finds the instance gone and reports the same bundle.
- `--template` is needed only when the host admits more than one session template. `--task` falls
  back to `sam.agentRuntime.session.defaultTask`. `ID` defaults to `s-MMDD-HHMMSS`.
- The preflight still applies (`docs/agent-runtime-pilot.md`): a session is refused while another
  instance runs or is unresolved, and when memory, disk or the credential metadata are no-go. Its
  Herdr check is skipped (`--no-herdr`): a session needs no Herdr record of its own.
- The template's `timeoutMinutes` (240) bounds a session like any instance; it then ends `timed-out`.

From the coordinator host, through a saved Herdr machine:

```sh
herdr --machine <label> workspace create --label rt-<id> --no-focus
herdr --machine <label> pane run <pane> "exec agent-runtime-session run --task OWNER/REPO#N <id>"
herdr --machine <label> agent list            # the pane shows as a Claude agent, idle or working
herdr --machine <label> agent prompt <name> "..." --wait
```

## How it works

| piece | what it does |
|---|---|
| template `session.enable` | `start` runs the payload as `dtach -N /run/agent-runtime/session/pty.sock` inside the instance. With no payload after `--`, the argv is the manifest entrypoint plus `session.args` |
| `session.credentialEnv` | a shim inside the instance exports the delivered credential under this name. The value is read from the credential mount there, so it is in no argv, record, journal line or manifest |
| `session.workdir`, `environment` | `--chdir` and `--setenv`; `TERM=xterm-256color`, `LANG`/`LC_ALL=C.UTF-8` are set for every session. `PATH`, `HOME`, `TMPDIR` and `AGENT_RUNTIME_*` stay the runtime's |
| `homeFiles` | root places each file in the private HOME before the payload starts, owned by the instance user: `link` is a symlink to the store path, `copy` a writable 0600 copy |
| socket access | `/run/agent-runtime/<ID>/session` is root-owned 0700 with two ACL entries: the instance user (rwx) and `sam.agentRuntime.session.attachUser` (traverse only). The payload side makes the socket 0666; the directory is what keeps other users out, and the payload cannot change it |
| `attach` | a plain `dtach -a` client on the host, outside the instance, as the session user. No root, no nsenter |
| `session.paneProcessName` | the file name the attach client runs under. Herdr decides a pane's agent kind from the name of its foreground process; `claude-session` sets `claude`, so Herdr tracks the pane as a native Claude agent and no status file, follower or `report-agent` is involved |
| `agent-runtime-session-launch` | the one root helper (below) |
| watcher | `run` leaves a user unit `agent-runtime-session-watch-<ID>` that waits for the outcome, calls `end` through the helper and runs the hooks. Nothing depends on the pane staying open. Without a user manager it is a detached process |

## Lifecycle hooks

`sam.agentRuntime.session.hooks.{start,end}` are lists of commands the watcher runs as the session
user on the host: never as root, never inside the instance. `start` fires once the instance runs
and the socket exists; `end` fires after export and destroy, or with the error when they failed.
Each hook is bounded by `session.hookTimeoutSec` (20). A hook that fails, hangs or is missing is
logged (`journalctl -t agent-runtime-session`) and changes neither the outcome nor the cleanup.

| variable | value |
|---|---|
| `AGENT_RUNTIME_SESSION_EVENT` | `start` or `end` |
| `AGENT_RUNTIME_SESSION_ID`, `_HOST`, `_TEMPLATE`, `_TASK` | the session |
| `AGENT_RUNTIME_SESSION_OUTCOME` | at `end`: `succeeded`, `failed`, `timed-out`, `oom-killed`, `cancelled` |
| `AGENT_RUNTIME_SESSION_BUNDLE` | at `end`: the export bundle directory |
| `AGENT_RUNTIME_SESSION_ERROR` | at `end`: set when export or destroy failed |

Nothing secret is among them. The default for both events is `agent-runtime-session-notify`:
`herdr notification show "rt-<id> started on <host>" --body "<template> <task>" --sound none`, and
at the end `"rt-<id> <outcome> on <host>"` with the task and bundle, sound `done` for `succeeded`
and `request` otherwise. It calls the session user's own `herdr` with the `HERDR_*` variables of
the pane `run` was started in; outside Herdr the call fails and is logged. `attach` and `detach`
have no hooks.

## The root helper

`sam.agentRuntime.session.launch.enable` (default off) adds one NOPASSWD sudo rule: `attachUser`
may run `agent-runtime-session-launch`, by store path, as root. The helper accepts only

- `start ID TEMPLATE OWNER/REPO#N`: the id and task by pattern, the template by name, which must be
  in the host's `eligibleTemplates` and a session template in the host's template profile;
- `end ID`: only an instance of a session template.

It never takes a command, a path or a credential. The payload is the manifest's entrypoint, the
credential file is `sam.agentRuntime.session.credentialFile`, and every decision is one JSON line in
the journal (`journalctl -t agent-runtime-session-launch`). A rule on `agent-runtime-instance`
itself would be arbitrary root, since `start` runs any payload.

## `claude-session` (`modules/agent-runtime/templates/claude-session.nix`)

| field | value |
|---|---|
| program | the host's `programs.claude-code.package`, `claude --dangerously-skip-permissions` |
| home | the host's `.claude/CLAUDE.md`, every `.claude/skills/*` (the Home Manager MCP plugin directory included) and `.claude/agents/*`, linked at the host's store paths |
| settings | the host's `programs.claude-code.settings`, with four differences: hooks that name a path in the host home are dropped (the Herdr SessionStart hook), `skipDangerousModePermissionPrompt = true`, telemetry and error reporting off with no OTEL variables, and `Read(//run/agent-runtime/credentials/**)` denied |
| `.claude.json` | a writable copy with onboarding and the workdir's trust dialog answered |
| source | `sammasak/rf-proto` at the flake's pinned rev, writable, the working directory |
| tools | bash, coreutils, findutils, grep, sed, awk, git, jq, ripgrep, fd, hostname, less, which, diffutils, tar, gzip, curl, cargo, rustc, gcc. No nix: the skill hooks that want it skip quietly |
| network | none by default; the two hosts allow exactly `api.anthropic.com` |
| resources | 2 CPUs, 4096 MiB, 240 min; home 1024, tmp 1024, cache 2048, output 64, workspace 256 MiB |

The eval checks `agent-runtime-acer-pilot` and `agent-runtime-msi-pilot` hold these claims against
each host's Home Manager.

## Security notes

- Bypass mode is safe only because of the instance: private user namespace, no host mounts, a
  writable copy of one repository, egress to one host. The session can do anything inside it.
- The subscription token is in the Claude process's environment, readable by anything the session
  runs as the same user. It can reach only `api.anthropic.com`.
- The template grants no GitHub capability: the session cannot push or open a PR (#166). Its work
  leaves as the export bundle's patch (`agent-runtime-verify`, `agent-runtime-promote`).
- `attachUser` can type into every session on the host. That is one user, by a directory ACL.
- `enabledPlugins` is carried in the settings, but plugins are fetched from a marketplace at run
  time and the instance has no egress for it, so the marketplace plugins are absent in a session.
  Vendoring them into the store is a follow-up.

## Proof

`nix build -L .#packages.x86_64-linux.agent-runtime-session-test` runs the whole path in a QEMU VM
with a stub line-echo program: the PTY socket, attach by the session user and refusal of another
user, home files, the credential reaching the process and staying out of argv, journal and records,
detach, exit status, `run`, `end`, the helper's refusals, the watcher and the hooks (with a stub
`herdr`). Not covered by the VM test, so to be confirmed on a host after deploy: the real Claude
Code screen in an instance started this way, Herdr 0.9.5 naming the pane a Claude agent from the
`claude` process name (measured live with a `claude`-named client outside this code path), and a
real `herdr notification show`.
