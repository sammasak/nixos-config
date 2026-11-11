# Agent runtime operator runbook (#141)

The ephemeral nspawn agent runtime: how to inspect, spawn, hand off, stop,
recover and tear down an instance, what the approval boundaries are, and the
no-go conditions. The design and VM proofs are in `docs/agent-runtime.md`
(module), `docs/agent-runtime-nspawn.md` (sandbox, enforcement, lifecycle) and
`docs/agent-runtime-herdr.md` (Herdr visibility). This file is the operator's
quick reference; it does not repeat those.

Two commands do everything on a host:
- `agent-runtime-instance` — the lifecycle (`.#packages.x86_64-linux.agent-runtime-instance`).
- `agent-runtime-herdr` — the Herdr adapter (`.#packages.x86_64-linux.agent-runtime-herdr`).

Both are plain root tools over `systemd-nspawn`, `systemd-run` and the stock
`herdr` CLI. State lives under `/var/lib/agent-runtime/<id>` and
`/var/lib/agent-runtime-herdr/<id>.json`; nothing is a NixOS generation.

## Status and inspection (read-only, safe any time)

```
agent-runtime-instance status            # every instance on this host, as JSON
agent-runtime-instance status <id>       # one instance: state, started, result, export
agent-runtime-instance logs <id>         # the payload's journal for its one invocation (<= 1 MiB)
agent-runtime-herdr status --json        # the runtime -> Herdr registry (works with Herdr down)
jq . /run/agent-runtime/status.json      # no root: ids, states, reservations, the boot's settle report and preflight verdicts
```

`state` is one of `created`, `starting`, `running`, `cancelling`, `succeeded`,
`failed`, `timed-out`, `oom-killed`, `cancelled`, `interrupted`, `ambiguous`,
`incomplete`, `absent`. `starting` is the brief start window and is **not**
final. `interrupted` is a run the host itself took down (a shutdown, or a reboot
or crash found at the next boot); it is exported and destroyed by the boot
unit, never started again. `ambiguous` (started, outcome never recorded while
the host stayed up: a supervisor crash) is a terminal unknown that is
**reported, never replayed**.

## Spawn and hand off

```
# 1. create: admit against the host policy, assign the locked sources, allocate volumes, materialize
agent-runtime-instance create <id> \
  --template /nix/var/nix/profiles/agent-runtime/templates/templates/<name>.json \
  --host     /etc/agent-runtime/host.json \
  --task     OWNER/REPO#N
# 2. start: a detached transient unit, user-namespaced, dropped caps, bounded cgroup + ext4 volumes
agent-runtime-instance start <id> [--credential FILE | --credential-issuer PROGRAM [--credential-ttl SEC]] -- <program> [args…]   # --wait blocks for the outcome
# 3. make it a Herdr agent of this host (one workspace per runtime, PTY only; no socket in the container)
agent-runtime-herdr attach <id> <template.json> OWNER/REPO#N <status-file> -- <pane argv…>
# 4. hand one authorized task to the idle runtime (idle in the registry and in Herdr; refuses blocked/finished/lost)
agent-runtime-herdr deliver <id> '<one-line prompt>'
# 5. follow and collect
agent-runtime-instance wait <id>
agent-runtime-instance export <id>        # bundle at exports/<id>.runs/<runId> (latest -> newest): sources/*.patch, output/, run.log, bundle.json; integrity-checked
```

`<id>` must be a DNS label of **at most 29** characters (a Herdr agent name is
`rt-<id>`, capped at 32). `create` and the Herdr adapter both refuse a longer
one with a clear message rather than truncating.

The handoff authorization gate is unchanged: `deliver` only sends to a runtime
the operator/Coordinator has an owner-labelled task for, and only while it is
idle. Filesystem writability never implies GitHub push; a credential is a
separate per-run grant (see caveats).

## Stop, cancel, recover, tear down

```
agent-runtime-instance cancel <id>        # idempotent; a running instance stops as `cancelled`
agent-runtime-herdr detach <id>           # release the Herdr agent, close the workspace, mark torn_down
agent-runtime-instance export <id>        # a failed/cancelled/oom/timed-out run exports a bounded recovery bundle
agent-runtime-instance destroy <id>       # tear down in order; releases the reservation LAST
agent-runtime-instance destroy <id> --discard   # skip the export (only when the artifacts are not wanted)
agent-runtime-instance reconcile          # after a crash: roll back an incomplete create; report, never replay, an ambiguous run
agent-runtime-instance settle             # what the boot unit runs: export + destroy runs the host interrupted; starts nothing
agent-runtime-herdr reconcile             # after a Herdr restart: re-report live runtimes, mark vanished ones lost
```

**Recovery rules.** `destroy` is bounded and idempotent, respects an in-use
mount (it fails and keeps the reservation, so the instance stays counted; run it
again once the holder is gone), and only removes the reservation after
everything else is gone. `destroy` refuses to tear down an unexported terminal
run unless `--discard` is given. An `ambiguous` run is never restarted automatically:
inspect it (`status`, `logs`, the recovery bundle) and decide by hand.

**Bundles are kept (#184).** `destroy` never touches `exports/`. Each run's bundle is its
own `exports/<id>.runs/<runId>`, so recreating an id and exporting again adds a bundle beside
the earlier one (a failed run's recovery bundle included), and `latest` moves to the newest.
Removing old bundles is the operator's decision; nothing does it automatically. A pre-#184
bundle at `exports/<id>` stays where it is.

## Approval boundaries

- **No self-authorization.** A runtime runs only an owner-approved template on a
  host with `sam.agentRuntime.host.enable` and the template in
  `eligibleTemplates`. `deliver` needs the owner's label on the task (the
  Coordinator's gate, skills #28).
- **Host activation is owner-gated and deploy-rs only.** Enabling the runtime on
  a physical host is a `just deploy-<host>` from lenovo after review and merge,
  never a direct switch on the host. No agent deploys or switches a host.
  Every host imports the substrate (`nixosModules.agent-runtime-host`, #155).
  Acer and MSI declare the runtime enabled in Nix; until an owner runs
  `just deploy-<host>`, that declaration does not activate it on the physical
  host. Enabling is a host-config change (import the template module, set
  `sam.agentRuntime.host.enable` and an `eligibleTemplates`/`reserve` policy)
  followed by `just deploy-<host>`, which deploys the `system` and
  `agent-runtime` profiles in order
  (`docs/agent-runtime-deploy.md`, Rollout). The host policy is then
  `/etc/agent-runtime/host.json` and the templates are under
  `/nix/var/nix/profiles/agent-runtime/templates/templates/`.
- **Capacity is the host policy**, not per-call: `maxConcurrentInstances`,
  `reserve.cpus`/`memoryMiB`/`diskMiB`. Admission refuses (exit 10) before any mount or
  unit when CPU, memory, instance count or disk would breach it, and after a failed
  start or teardown the reservation stays until `destroy`.

## Host drain and rollback

```
agent-runtime-instance status | jq -r '.[] | select(.state=="running" or .state=="starting") | .id'
# drain: cancel + export + destroy each, oldest first, before a runtime-closure change (a reboot settles itself, below)
# a deploy-rs rollback of the host plumbing does NOT roll back a run's output or a live instance;
# drain first. In-flight work is never silently re-run.
```

Admission is the drain lever (remove the template from `eligibleTemplates`,
deploy `system`, let running instances end). Automatic and manual rollback of
either profile, and what a template deploy does to a running instance, are in
`docs/agent-runtime-deploy.md` (Drain, Rollback, Failure outcomes; proven by
`agent-runtime-deploy-test`).

## Reboot and shutdown

Nothing has to be drained by hand before a shutdown, a scheduled poweroff or a
reboot, and no other module needs to know about the runtime.

- **Shutdown.** systemd stops every instance unit (`TimeoutStopSec=30`). Its
  `record-exit` sees the host going down and records `interrupted`
  (`interruptedBy: host-shutdown`) instead of `failed`. A cancel requested
  before the shutdown still reads `cancelled`.
- **Boot.** `agent-runtime.service` runs `agent-runtime-boot` once: `settle`,
  then a preflight (`--no-herdr`) per eligible template, then the status file.
  `settle` rolls back an incomplete create, turns a run that was started before
  this boot and has no outcome (a crash or power loss) into `interrupted`
  (`interruptedBy: host-restart`), and for every `interrupted` run exports the
  recovery bundle and destroys the instance, which releases its reservation.
  It starts nothing and replays nothing; a `created` instance stays startable
  (volumes survive; the `/run` root and loop mounts are rebuilt by `start`).
- **Held, not discarded.** A run is left `interrupted` with its reservation when
  its export cannot be made safely: it had a credential whose host file is gone
  or changed since the start (or the token was minted), or the credential shows
  up in an output file or patch. The settle report names it and the command to
  run. `settle` never uses `--discard`.
- **Credentials.** `start --credential FILE` records the file's path and the
  sha256 of the token (never the token) in the 0700 state directory. After a
  reboot the tmpfs copy is gone; `settle` re-reads that path for the export's
  leak check only while the digest still matches.

Post-reboot check, as the operator, no root:

```
systemctl is-active agent-runtime.service        # active (a oneshot that stays active)
jq '{admitReady, unresolved, reservations, settle: .settle.instances, preflight: .preflight.templates}' /run/agent-runtime/status.json
```

`admitReady: true` means the host admits, no instance is unresolved and a slot
is free. `preflight.templates[].verdict` is the boot's `go`/`no-go` per eligible
template with the failed checks; `settle.instances[]` lists what was `settled`
(with its bundle), `held`, `rolled-back` or left `untouched`. The file is a
snapshot (`at`); lifecycle commands refresh the instance part. Root reruns the
whole thing with `systemctl restart agent-runtime.service`, or just
`agent-runtime-instance settle`. On a host that stayed up it changes nothing
that is still running, and an `ambiguous` run of the current boot is left for a
decision by hand.

## Store and credentials caveats

- **Read-only `/nix/store` is visible, not confidential.** Every closure on the
  host is readable from inside an instance. Do not run a template whose closure
  embeds material an instance must not see; a closure-only bind is the mitigation
  (#137, not yet enforced by default).
- **Credentials are per-run and never in the store/manifest.** The token goes
  to a per-instance **tmpfs** under `/run/agent-runtime/<id>/cred` (nothing about
  it at rest), bound read-only at `/run/agent-runtime/credentials`; a
  concurrent instance cannot read it. The secret is masked (`<redacted>`) in the
  `logs` view and the exported log, and `export` refuses an `/output` artifact
  that carries it; the raw secret still lives in the payload's own files and the
  private tmp volume until teardown (#153).
  - `--credential FILE`: an operator-provided token; its scope is the
    operator's word (record `{"kind": "file"}`).
  - `--credential-issuer PROGRAM`: a token minted for the run, refused before
    anything starts unless its scopes are within the template's `capabilities`
    and it expires within the run's limit; revoked at teardown (#159). The
    production issuer (a GitHub App, its key in sops) is an **owner decision**
    and does not exist yet (`docs/agent-runtime.md`, Per-run credentials).
- **Egress is deny-by-default.** The default template has no network at all. A
  template with `network.allow` resolves those names once, pins them into the
  instance's `/etc/hosts` (IPv4 only; port 53 is never opened, so a made-up
  name cannot resolve and a raw DNS query gets no answer), and filters the
  instance's own veth on both the `input` and `forward` hooks — `tcp 443` to the
  resolved addresses, everything else dropped (#153; DNS-closed and concurrent
  starts proven in #159).

## No-go conditions for untrusted code

**nspawn is a shared-kernel boundary, not a VM.** Run only approved
repositories. Do **not** run a runtime when any of these holds:

- the host cannot establish the user/mount/pid/ipc/uts/net namespaces or the
  UID mapping — that is a hard release blocker, never a warning (start fails
  closed; a concurrent waiter is told, not silently passed);
- `vm.panic_on_oom` is `2` (a cgroup OOM would panic the host; the runtime needs
  `0` or `1`);
- the workload is hostile or untrusted, or needs a credential the host cannot
  scope and expire;
- the host is under memory or disk pressure that admission cannot see (admission
  reserves logical CPU capacity, `MemTotal`/`MemAvailable`, and free-disk
  headroom; the reserve protects capacity from admitted instances while the
  live memory and disk checks account for other host workloads.

When in doubt, keep the instance disposable: `--discard` on destroy, and never
treat a Herdr `idle`/`done` or a green CI as proof a task actually succeeded —
that is `work_verdict`, decided from GitHub evidence, not runtime state.
