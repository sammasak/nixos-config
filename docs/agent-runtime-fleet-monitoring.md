# Fleet monitoring: Acer and MSI from Lenovo (#186)

After owner-approved activation, Lenovo is the monitoring point for Acer and MSI.
The existing Herdr inventory and Coordinator brief retain each runtime's **host,
runtime id, owning GitHub task, template digest and lifecycle state**, with its
non-secret blocked reason and observation time. No new inventory service,
scheduler, configuration format, host dependency or polling loop is introduced.

## Declarative configuration and observation

Lenovo's typed `sam.herdr.machines` lists `acer-swift` and `msi-ms7758`. Home
Manager activation uses Herdr's native saved-machine commands; an existing label
is left unchanged. Both SSH host keys are already pinned. Worker configuration
and MSI onboarding remain in #185; this PR performs no host activation.

From Lenovo:

```bash
herdr machine list --json
herdr --machine acer-swift agent list
herdr --machine acer-swift agent get rt-coder
herdr --machine msi-ms7758 agent list
herdr --machine msi-ms7758 agent get rt-coder
```

Herdr's native TUI addresses one machine at a time; it does **not** aggregate the
fleet. In a checkout containing the reviewed skills dependency, the existing
tasks provide the rollup:

```bash
cd ~/claude-code-skills
devenv tasks run herdr:inventory --show-output
devenv tasks run coord:brief --show-output
cat ~/.local/state/coordinator/brief/latest.md
```

The last path is the default `coordinator.stateDir`; use its configured value if
overridden. Runtime provenance comes from Herdr's reported `title`
(`OWNER/REPO#N rt=<id> tpl=<digest12>`), rather than the container's terminal
title. Runtime identity is `(host, runtime_id)`; host-local pane ids remain the
Herdr command targets. The inventory keeps `task_ref: #N` for existing evidence
correlation and `runtime_task_ref: OWNER/REPO#N` for display.
Blocked mirror reasons use Herdr's native `tokens.blocked_reason` metadata
(concise, at most 80 characters); `report-agent --message` alone is not exported
by the pinned Herdr list/get API. Tokens are cleared outside blocked states and
republished during reconciliation.

A failed remote read is an explicit unreachable host with an error and no
fabricated idle agents. This is expected when MSI is outside Mon–Fri 09:00–21:00.
The brief marks partial observations and preserves their timestamps. Herdr
`idle`/`done` reports lifecycle only: verified work still requires GitHub evidence.

Mirrors observe root-written lifecycle files from the authorized instance
launcher and refuse `deliver` (exit 75). After a Herdr restart, reconciliation
restores the inert pane placeholder and a surviving mirror's identity, state and
reason. It checks for a shell before replacing the placeholder; missing panes or
foreign foreground commands are marked `lost`. For a runtime that ran inside its
pane, a restored shell means the runtime is gone and is marked `lost`. No runtime
is relaunched. Destroyed runtimes are detached; completion evidence stays in
GitHub and immutable export bundles.

## Owner-approved rollout and rollback

Only after separate owner approval for Lenovo, from a clean checkout containing
the merged PR:

```bash
cd ~/nixos-config
just build lenovo
just diff lenovo
just switch lenovo
```

Initial registration should occur while both workers are reachable. A failed
`machine add` is a nonfatal activation warning, not proof of a saved machine.
If MSI was offline, retry in its next permitted power window:

```bash
herdr machine add msi-ms7758 --label msi-ms7758 --remote-session default
herdr machine list --json
```

Activation adds missing labels; it neither changes an existing target nor prunes
removed declarations. To roll back MSI registration, revert its Nix declaration
and apply that configuration with owner approval, **then** remove its saved entry:

```bash
msi_profile=$(herdr machine list --json | jq -er '.[] | select(.label == "msi-ms7758") | .id')
herdr machine remove "$msi_profile"
```

Removing the saved entry alone is temporary: activation re-adds a still-declared
machine. `machine remove` takes the profile id, while remote observation accepts
the label. None of these commands changes a worker's power policy or SSH keys.

## Offline proof and remaining live acceptance

On Acer, the three-node test is a separate package:

```bash
flock /tmp/acer-swift-heavy-work.lock nix build -L .#packages.x86_64-linux.agent-runtime-herdr-fleet-test
```

It executes Lenovo's generated registration action and the pinned production
inventory task. It proves idempotent registration, strict host keys, simultaneous
same-id runtimes on two hosts, real credential-free authorized-launch mirrors,
unknown/working/blocked/success transitions, restart reconciliation, explicit
offline errors and reconnect, saved-machine rollback, and teardown with retained
verified bundles. The dependency's fixture suites prove the full Coordinator
brief and GitHub unknown/verified distinction. Full `nixos:qa` checks the host
configurations and existing coordinator wiring.

These are offline proofs. Keep #186 open until owner-approved #185 onboarding
records all of the following:

- Exact activated Lenovo/MSI generations and the skills task checkout revision;
  MSI's Herdr server, user linger and existing strict SSH identity work.
- A real credential-free bounded MSI runtime and the existing Acer runtime/mirror
  are simultaneously distinguishable from Lenovo's inventory and brief by host,
  runtime id, task, template and state; record observation times and blocked
  reasons where applicable.
- MSI is explicitly unreachable outside its normal power window and visible
  again after the next permitted wake, without false idle or false completion.
- The fixture exports, verifies and tears down cleanly; stale Herdr entries are
  removed and historical bundle/GitHub evidence remains distinguishable.
- Lenovo's deployed event-driven wake and the owner's 40-minute fallback are
  verified. The Nix wake configuration is unchanged; the skills pin also includes
  previously merged upstream task corrections, recorded in the PR.

No Lenovo/MSI deployment, live Herdr restart, SSH-key or secret change, credentialed
runtime, or out-of-window wake is performed by this PR.
