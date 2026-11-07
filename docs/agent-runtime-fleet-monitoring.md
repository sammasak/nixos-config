# Fleet monitoring: Acer and MSI runtimes from the Lenovo coordinator (#186)

Lenovo is the single control/monitoring point; Acer and MSI are execution hosts.
Every active isolated agent runtime on a worker is visible from Lenovo through
Herdr, read-only, with five fields: **host, runtime id, GitHub task ref,
template, and state** (`working`/`idle`/`blocked`/`unknown`/`offline`, with the
non-secret blocked reason). No credential crosses hosts; no new service,
scheduler, dashboard or poller is added. This reuses the shipped
`agent-runtime-herdr` adapter and status mirror (#156/#176) and the saved-Herdr-
machine path (`agent-runtime-herdr-machines-test`).

## What changed here (declarative, Lenovo only)

- `hosts/lenovo-21CB001PMX/configuration.nix`: `sam.herdr.machines` now lists
  both `acer-swift` and `msi-ms7758`. A worker declares nothing; only the
  coordinator declares its workers. Host keys for both are already pinned in
  `modules/core/ssh-known-hosts.nix` (strict host-key checking stays on).
- A three-node VM proof, `agent-runtime-herdr-fleet-test`.
- No MSI host config is touched here — that is #185 (companion). No live change.

## How the coordinator sees the fleet

Herdr addresses one machine at a time; its TUI does **not** aggregate across
machines. The coordinator's `herdr:inventory` (a devenv task in the skills repo,
not in this repo) rolls up per machine:

```
herdr machine list --json                       # the saved workers
herdr --machine acer-swift agent list           # Acer's runtimes (read-only)
herdr --machine acer-swift agent get rt-<id>     # one runtime's state + message
herdr --machine msi-ms7758 agent list           # MSI's runtimes
```

Each runtime's five fields come from its Herdr **`title`**
(`OWNER/REPO#N rt=<id> tpl=<digest12>`), not `terminal_title_stripped` (which is
the container's own name on the worker and does not correlate across hosts). The
inventory that still reads `terminal_title_stripped` for the task correlation
must read `title` — tracked as skills #28; this repo provides the `title` field
and proves the rollup against it. A machine that does not answer
`agent list` (non-zero exit) is an **offline** row, never an empty fleet or a
false `idle` — this is the normal case for MSI outside its Mon–Fri 09:00–21:00
power window.

Finished/destroyed runs are not kept as permanent panes: a torn-down runtime
drops off `agent list`; its evidence lives in GitHub/bundles, not Herdr.

## Owner deploy steps (no deploy performed by this PR)

Run from Lenovo, after the PR merges:

```
cd ~/nixos-config && git pull --ff-only
devenv tasks run nixos:qa                       # eval + host builds (no heavy VM package)
home-manager switch --flake .#<lenovo-user>     # or the repo's usual HM switch for lenovo
# idempotent machine registration happens at HM activation; confirm:
herdr machine list --json | jq '.[].label'      # -> "acer-swift", "msi-ms7758"
herdr --machine acer-swift agent list           # reachable
herdr --machine msi-ms7758 agent list           # reachable in the power window; a non-zero
                                                 # exit outside it is expected (offline)
```

The heavy VM proof is a package, run explicitly (acer, heavy-work lock), not in
`nixos:qa`:

```
nix build .#packages.x86_64-linux.agent-runtime-herdr-fleet-test
```

## Rollback

The change is one declarative list plus a test. To roll back the fleet view,
revert `sam.herdr.machines` to `[ { label = "acer-swift"; target = "acer-swift"; } ]`
and re-run the HM switch; or drop the saved machine at runtime without a rebuild:

```
herdr machine remove msi-ms7758
```

Removing the entry only stops Lenovo from querying MSI; it changes nothing on any
worker and touches no secret. The VM test package can be removed by reverting
`flake-modules/65-agent-runtime-herdr-fleet-test.nix`.

## Boundaries honored

Read-only (`agent list`/`get` only; no cross-host `agent prompt` — upstream Herdr
refuses the `agent-runtime` kind, and dispatch is not an acceptance prerequisite).
No credential crosses hosts (the mirror follower reads only a root-written,
world-readable `mirror.status`; a mirror refuses `deliver`, exit 75). No new
privilege, service, scheduler, queue, database or poll loop; the coordinator's
event-driven wake and 40-minute fallback are untouched.
