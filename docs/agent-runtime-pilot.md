# Agent-runtime pilot on acer-swift (#165)

The supervised live pilot of the runtime (#133's MVP) on one real host: one credential-free Rust
coding agent, one instance at a time. This file is what the owner deploys and runs; the general
operator reference is `docs/agent-runtime-runbook.md`, the deploy mechanics
`docs/agent-runtime-deploy.md`.

**Nothing here is live until the owner deploys it.** The PR that adds it changes acer-swift's
configuration only; merging it arms the next `just deploy-acer`, so merge when the pilot is wanted.

## The template: `rust-pilot` (`modules/agent-runtime/templates/rust-pilot.nix`)

| field | value |
|---|---|
| source | `sammasak/factum` at the flake's pinned `inputs.factum` rev (`5bb7fa30…` today), a private writable copy at `/workspace/factum` |
| assignment | `rust-pilot-run`: `PROPTEST_RNG_SEED=165 cargo test --offline --locked --release -p factum --lib`, the lib half of the check nixos-config's factum package runs: a cold release build of the 175-crate graph and 243 unit tests (why not the integration tests: below) |
| network | none (`egress: none`): the crates are the Nix-vendored set (`importCargoLock` of factum's `Cargo.lock`, the derivation the package builds from) |
| credential | none (`capabilities: []`); the GitHub App issuer is #166, deferred |
| skills | `rust-engineering`, from the pinned skills input |
| toolchain | factum's pin, rust 1.99.0 with clippy and rustfmt (rust-overlay), plus cargo-nextest and gcc |
| resources | 2 CPUs, 3072 MiB hard memory (no swap), 512 tasks, 20 min |
| volumes | workspace 256 MiB / 20k inodes, home 64 MiB, tmp 2048 MiB / 50k, cache 1024 MiB / 10k, output 64 MiB (3.4 GiB together) |

The run writes `cargo-test.log`, `result.json` (exit, rev, the volumes it used) and `SHA256SUMS`
to the output volume; `export` bundles them with the source patch, which is empty: the run changes
no tracked file (the fixture lockfile it writes, as the package build does, is gitignored).

**Measured** in the VM runs of this template (`agent-runtime-pilot-test`, 2 cores, two runs): 293-298 s,
memory peak 1883-1900 MiB of the 3072 cap (no OOM kill), cache 365 MiB / 1534 inodes, workspace 16 MiB,
243 tests.
The budgets keep about 3x headroom on what was used; tmp is generous because only its end-of-run use
(1 MiB, the tests remove their scratch trees) was measured. On acer-swift itself, the whole package
check (lib and integration tests) took 778 s at 2 cores, at most 1623 MiB anonymous memory, 69 tasks.

**Why only the lib tests:** factum's integration tests build factum's own workspace a second time,
in debug, into `/workspace/factum/target` (`inventory_real_workspace_joins_every_syntax_test` lists it
with all features: about 11 GiB, measured; `m4_1_exit_add_param_recorded` and others build parts of
it). In the VM that filled the 256 MiB workspace volume (`No space left on device` inside the
instance, the host unaffected: the budget holding). That is factum's CI, not a 2-CPU pilot of the
runtime.

**Two factum findings the oracle works around, at `5bb7fa30`:**
- `testplan::statement::tests::prop_statement_canonical_round_trip` fails at random: its generator
  can draw duplicate givens (`DuplicateGiven`, minimal input `given_count = 4, args_count = 4`).
  A fixed `PROPTEST_RNG_SEED` makes the oracle deterministic; the bug is factum's to fix.
- `CARGO_TARGET_DIR` in the environment reaches the fixture workspaces factum's tests build, which
  then share one target directory and fail at random; the run passes `--target-dir` instead.

## The host policy (`hosts/acer-swift/configuration.nix`)

`enable = true`, `eligibleTemplates = [ "rust-pilot" ]`, `maxConcurrentInstances = 1`,
`reserve = { memoryMiB = 4096; diskMiB = 51200; }`. Admission then needs `MemAvailable` of at least
7168 MiB (the 3 GiB cap plus the reserve) and the reserve stays free for the host after it.
Measured 2026-11-06: MemTotal 15 672 MiB, MemAvailable ~9 000 MiB, k3s 3.0 GiB now and 7.4 GiB at
its peak, so the reserve absorbs most of a k3s surge during a run. Disk: 463 GB free; the volumes
take 3.4 GiB and 50 GiB stay free. `checks.x86_64-linux.agent-runtime-acer-pilot` pins all of it.

## Preflight (read-only)

`agent-runtime-preflight` (`modules/agent-runtime/runtime/preflight.sh`) checks the runbook's no-go
list and changes nothing: user namespaces and the instance UID ranges (no account or subuid inside
them), the other namespaces, `vm.panic_on_oom` 0 or 1, memory and disk against the reserve as
`create` admits, the template eligible, Herdr answering (as the user who ran sudo), and no instance
running or unresolved. With `--credential FILE` it also verifies the subscription token the run will
deliver -- present, a regular file, owner-only (0400/0600), non-empty, owned by the operator -- from
its metadata only, never reading or printing the token (#169). On a host that declares
`sam.agentRuntime.host.scheduledShutdown` (a systemd timer plus `stopExportMarginMinutes`, default
10) it refuses a run when the timer's next elapse is sooner than the template's `timeoutMinutes`
plus that margin, and refuses when the next elapse cannot be read (#185): a scheduled shutdown does
not drain instances, so such a run could be cut off before stop and export. Every check prints PASS
or FAIL; it exits 0 only when all pass.

## Deploy (owner, from lenovo)

```
cd ~/nixos-config && git pull --ff-only
devenv tasks run nixos:qa          # builds acer-swift and checks.agent-runtime-acer-pilot
just deploy-acer                   # deploy-rs: the system profile, then the agent-runtime templates profile
```

Then on acer-swift: `jq . /etc/agent-runtime/host.json`, and
`ls /nix/var/nix/profiles/agent-runtime/templates/templates/` shows `rust-pilot.json`.

## The pilot run (owner-supervised, on acer-swift)

The whole run happens in one bash shell that holds acer's heavy-work lock, so no agent gate (VM
tests, `nixos:qa`, nix builds) starts beside it: the 4 GiB reserve covers a k3s surge, not a second
heavy job. The first line waits until a running gate ends; `exit` at the end releases the lock. (The
commands are bash; your login shell is fish.)

```
flock --verbose /tmp/acer-swift-heavy-work.lock bash   # holds the lock until this shell exits
H=/etc/agent-runtime/host.json
T=/nix/var/nix/profiles/agent-runtime/templates/templates/rust-pilot.json
RUN=$(jq -r '.packages[] | select(.name == "rust-pilot-run") | .storePath' "$T")/bin/rust-pilot-run
TASK=sammasak/nixos-config#165
export AGENT_RUNTIME_HERDR_STATE=$HOME/.local/state/agent-runtime-herdr   # the adapter runs as you, Herdr's user
S=$XDG_RUNTIME_DIR/rt-pilot.status

sudo agent-runtime-preflight --template "$T"                    # must end "preflight: go"
sudo agent-runtime-instance create pilot --template "$T" --host "$H" --task "$TASK"
agent-runtime-herdr attach pilot "$T" "$TASK" "$S" -- agent-runtime-pane pilot "$S" -- "$RUN"
agent-runtime-herdr status --json                               # pilot: idle
agent-runtime-herdr deliver pilot 'run the assigned task'
# the pane runs `sudo agent-runtime-instance start pilot --wait …`: answer sudo's password in the rt-pilot pane
sudo agent-runtime-instance wait pilot                          # until it ends; status shows succeeded
sudo agent-runtime-instance status pilot                        # record runtimeUSec, memoryPeakBytes, uidBase
sudo agent-runtime-instance export pilot
sudo sh -c 'cd /var/lib/agent-runtime/exports/pilot.runs/latest/output && sha256sum -c SHA256SUMS && cat result.json'   # 0700 root
agent-runtime-herdr detach pilot
sudo agent-runtime-instance destroy pilot
sudo agent-runtime-preflight --template "$T"                    # go again: nothing left
exit                                                            # releases the heavy-work lock
```

After `detach`, the adapter's follower may log `agent-runtime-herdr: pane … not found`: it noticed
the closed pane and stops. That line is expected, not a failure.

Record for #165: the host generation (`readlink /run/current-system`), the flake rev, these
commands' output, `result.json` and the export's `bundle.json` digests.

## Rollback

1. **Drain:** `sudo agent-runtime-instance status` shows nothing running; cancel, export and destroy
   any instance (`docs/agent-runtime-runbook.md`, Stop and tear down).
2. **Disable:** set `eligibleTemplates = [ ]` (admission refuses, the substrate stays) or remove the
   `sam.agentRuntime.host` block and the template import, then `just deploy-acer`.
3. **Or roll back what deploy-rs activated:** templates
   `ssh deploy@acer-swift sudo nix-env -p /nix/var/nix/profiles/agent-runtime/templates --rollback`;
   the system `ssh deploy@acer-swift 'sudo nix-env -p /nix/var/nix/profiles/system --rollback && sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch'`
   (`docs/agent-runtime-deploy.md`, Rollback). A failed activation is rolled back by deploy-rs itself.

## Limits

- **The VM proves the root path.** The VM test (`packages.x86_64-linux.agent-runtime-pilot-test`)
  runs Herdr, the adapter and the pane as root. On acer-swift Herdr is your user's server, so the
  adapter runs as you (`systemctl --user`, `AGENT_RUNTIME_HERDR_STATE`) and the pane reaches root
  through sudo; that path is the live pilot's to prove.
- **sudo asks in the pane.** A `NOPASSWD` rule for `agent-runtime-instance` would make the run
  unattended; that is a permission change for the owner to decide, not part of this pilot.
- **Native Herdr prompting** of a `pane report-agent`-registered runtime does not work upstream
  (herdrdev/herdr#4732); the handoff goes through the adapter's gated `deliver`.
- **No credential, no push.** A production token issuer is #166 and stays deferred.
