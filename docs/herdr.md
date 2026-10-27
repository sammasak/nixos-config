# Herdr session persistence

Every `devTools` host installs Herdr and starts its user server at boot. The
Home Manager module keeps the Herdr config declarative, enables native agent
session restoration and pane screen history, and uses a start condition to
leave an already running server and its panes alone. NixOS enables systemd user
lingering for `devTools` accounts so the user manager starts without an
interactive login.

Home Manager also installs version-matched Herdr hooks for Claude Code and
Codex. The Pi extension is installed on hosts with `sam.profile.pi = true`.
These hooks report the agent session reference Herdr needs to resume a native
conversation after a server restart.

On `devTools` hosts, an ordinary interactive Fish shell stays in the terminal
where it was opened. Running `pi`, `claude`, or `codex` from a local interactive
Fish shell creates a Herdr workspace in the current directory, starts that
agent with the original arguments, and attaches directly to its pane. Inside
Herdr, the wrappers call the native CLI directly. Print/noninteractive modes,
CI, SSH, noninteractive shells, and `HERDR_AUTOATTACH_DISABLED=1` calls use the
native CLI in the current terminal. Use `command pi`, `command claude`, or
`command codex` to explicitly bypass the wrappers. A plain explicit resume of
an agent session that is already registered attaches to that pane instead of
opening the same conversation a second time.

Herdr stores its session snapshot and pane history in `~/.config/herdr/`.
Home Manager sets that directory to mode `0700`; the systemd unit also uses a
private umask. Pane history may contain prompts, command output, or secrets.

Claude Code, Codex, and Pi keep conversation/session data under
`~/.claude/projects/`, `~/.codex/sessions/`, and `~/.pi/agent/sessions/`.
These directories live in the persistent home filesystem and are not managed
or replaced by Home Manager, so reboot recovery can resume the native
conversations referenced by Herdr.

## Saved machines (the coordinator host)

Herdr itself is the fleet view: a host sees its own agents, and any Herdr
**saved machine** it has (`herdr machine list --json`) through command
forwarding (`herdr --machine <label> agent list` and friends). Workers save
nothing and so see themselves only. The coordinator host (lenovo) declares its
workers as `sam.herdr.machines = [ { label = "acer-swift"; target =
"acer-swift"; } ]`; at activation Home Manager runs `herdr machine add
<target> --label <label> --remote-session default` for each label Herdr does
not know yet, with the user's own SSH key and `known_hosts` (a failed add is
reported, not fatal; a passphrase-protected key has no agent inside the
activation service, so add such a machine by hand once). Herdr owns the result
in `~/.local/state/herdr/client/endpoints.json`: a saved label is never
rewritten, so to change a target run `herdr machine remove <label>` and switch
again. The coordinator subagent (skills repo, `agents/coordinator.md`, linked
by `skills.nix`; no hook guards it, Claude Code's permission prompt does)
reads the same list, so on a worker it reports
that host only and on lenovo every machine.

## Verify reboot recovery

Before reboot, attach to the Herdr server and note the workspaces, panes, and
active agent conversations. Confirm all three integrations are current and
check that Herdr sees the expected agent panes:

```sh
herdr integration status
herdr agent list
```

To verify a server restart first, restart the service during a quiet window,
then check the agents and attach to Herdr:

```sh
systemctl --user restart herdr.service
herdr status --json
herdr agent list
herdr
```

During the first activation, if Herdr was already running outside systemd, the
service start condition leaves that process alone and systemd reports the unit
as skipped. A `systemctl --user restart` at that point does not restart the old
server. After the first host reboot, the lingering user manager starts Herdr
under systemd and the restart command above applies. To hand off before reboot,
use a quiet window: `herdr server stop` stops the server and its pane processes;
then run `systemctl --user start herdr.service` and verify the restored panes.
Only do this after confirming agent session references are available, or agent
panes may return as shells.

Before a host reboot, confirm that the host's home directory is on its
persistent filesystem. After reboot, without logging in first, check from an
administrative session:

```sh
loginctl show-user lukas -p Linger
systemctl --machine=lukas@.host --user status herdr.service
```

Then log in and run:

```sh
herdr status --json
herdr
```

The user property should report `Linger=yes`, the service should be active, and
Herdr should show the previous session layout and recent pane contents. Supported
Claude Code, Codex, and Pi panes resume their native conversation when Herdr's
integration reports a valid session reference. Restored panes do not preserve
arbitrary running shell processes; they reopen in the saved directory.

The integrations report session references when an agent starts or resumes.
An agent already running before the Home Manager activation is left running,
but it may not yet have reported a reference; that pane can return as a shell
after a server restart. Before treating a restart or reboot as a conversation
recovery test, confirm each pane was started or resumed after the integration
was installed, then check that the same agent conversations appear afterward.

Claude and Codex integration scripts use Python's standard library to report
session references; Home Manager installs `python3Minimal` for those hooks.
Starting an agent with its native resume command can contact the provider even
before a prompt is sent. A quota or authentication screen means that agent's
conversation recovery was not demonstrated; do not send a prompt just to clear
the screen during a persistence test.
