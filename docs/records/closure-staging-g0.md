# Closure staging: G0 inventory (#201)

Read-only inventory for the D1 owner gate of #201. Taken at nixos-config `1138ab0` (2026-11-11) from inside
the `nc201` nspawn environment on lenovo, nix 2.34.9, systemd 261 (261.3). No build, VM run, deploy or
config change. D1 (`KEEP A`, `POC B`, `POC C`, `DEFER`) is the owner's choice in #201 and is not made here.

## The baseline #201 names no longer exists

The G0 comment on #201 (2026-11-10, HEAD `9e68ca5`) inventories `modules/agent-runtime/` (`instance.sh`,
`assign.sh`, `materialize.sh`, `native-shell.nix`) and `docs/agent-runtime-*.md`. #210 (`5a40362`, 2026-11-11)
removed all of it; `modules/workers` (#209) replaced it. Every code link in the issue body and every
`file:line` in that comment resolves only at `5a40362^`. The comment's numbers (reservation file, rollback
trap, NAR-hash check, `--bind-ro` options) describe a runtime that is not deployed. This inventory replaces
its section 2 for today's code. The comment's #194/#199 timings were measured on the removed runtime and say
nothing about the current one.

## Frozen inputs

| Item | Identity |
|---|---|
| nixos-config | `1138ab00bf3115af9270ebda33e9a90db253e614` |
| nixpkgs (`flake.lock`) | `fe13242281a67641c0102cdb1087f0ebe586c7df`, narHash `sha256-zp8ToDMnqZcu4o4IH9pdwXFXGp7yLm/M0dEnNWnyd7I=` |
| Fixture rf-proto | `sammasak/rf-proto` `89e08d25d3057f3b68ef5d8a3508238789f8b7de`, narHash `sha256-1QY8tdQFQz0jaxNJwKzMTB4CWWFxjmXXuDKr2KV5/Js=`, `devShells.x86_64-linux.default` = `40ladp3…-nix-shell`; 89 paths, 2.90 GB NAR per `docs/records/shared-nix-builds-baseline.md` (the old doc and the comment say 90) |
| Fixture llm-gateway | `sammasak/llm-gateway` `4a17b9241d8ad3702777ea85001597910e169e5b`, narHash `sha256-V1U3q8PlItSBdoqXbn7kmThDhhtqLO1lJyrFr0O9xUM=`: the last pin, from `git show 5a40362^:flake.lock`. #210 dropped the flake input, so today it is no longer in `flake.lock` |
| Fixture harnesses | the projection scripts and QEMU tests for both fixtures were deleted in #210 (`git show 5a40362^:scripts/test-agent-runtime-llm-gateway-devenv-projection.sh`); the old doc survives as `git show 5a40362^:docs/agent-runtime-native-shell.md` |
| Evaluation boundary | the host's nix daemon evaluates and builds; a guest only reads what the host store holds, or asks the same daemon (below) |

## Today's sequence (Option A as deployed)

`declare instance in hosts/<host>/configuration.nix` → eval-time assertions (names, pool sums) → deploy
(activation creates `stateDir/<name>/home`, the host key) → `container@<name>` starts: stock
`containers.<name>`, `ephemeral = true`, private network → bind mounts → guest boots, Herdr hook starts the
agent → agent runs `devenv shell`, `cargo` or `nix build` through the **host daemon** → `git push` is the only
export → name moved to `retired`, deploy → activation deletes home, profile and gcroots.

There is no prepare step, no per-run manifest, no closure selection and no readiness result: closures are
realized lazily by whichever command first needs them, on the host store, while the agent runs.

## Inventory (paths at `1138ab0`)

| Topic | Today | Evidence |
|---|---|---|
| Store visibility | whole host `/nix/store`, nix db and `daemon-socket` bound into every guest | `docs/nspawn-workers.md` "Made of"; observed below |
| Realization | host daemon, outside the pool; bounded 2 jobs of 2 cores, `MemoryHigh` 4G, `MemoryMax` 6G on acer, msi, lenovo | `docs/nspawn-workers.md` "What fails at build"/intro, `nixos:build-bounds-test` |
| GC-root creation | the daemon registers a guest's roots under `/nix/var/nix/gcroots/per-container/<name>`, which dangles on the host; `dev-environments-gcroots` re-roots every `*/.devenv/gc/*` symlink found in each home (pruning `node_modules`, `target`, `.git`) as `home-<sha1>` links | `modules/workers/core.nix:262-282` |
| GC-root timing | only `requiredBy`/`before` `nix-gc.service`; it runs only when `nix.gc.automatic` and instances exist. A manual `nix-collect-garbage` does not run it | `modules/workers/core.nix:263-267` |
| GC-root release | only for names in `retired` and only while `container@<name>` is stopped: `rm -rf` of home, `profiles/per-container/<n>`, `gcroots/per-container/<n>`. Removing a declaration stops the unit and keeps all of it | `modules/workers/core.nix:243-249` |
| Reservation | eval-time only: reserves sum to at most `pool.memory`, cores to at most `pool.cores`; runtime is `environments.slice` `MemoryMax`/`MemoryLow`/`MemorySwapMax`, per-unit `MemoryMin`/`MemoryLow`, `CPUWeight`. No runtime admission or disk quota; home is a plain bind of a host directory | `modules/workers/core.nix:309-334,353-373` |
| Failure and ambiguity | evaluation failures name the option (`nixos:workers-eval-test`). At runtime there is no create/start state machine to be ambiguous: a unit is active or not; no restart policy for `container@` is declared here (`Restart = "on-failure"` at `core.nix:418` is on the worker unit) | `modules/workers/core.nix:309-340` |
| Closure verification | none: a guest runs whatever the daemon has, and the daemon accepts what `require-sigs = true` and its substituters allow | `nix config show` below |

Writes the agent can make to the host store: any `nix build` it runs is performed by the daemon, so it can add
to the store and to its own per-container roots, within the daemon's bounds.

## Measured from here

`nc201` is a live case of the host-realized store: `/proc/self/mountinfo` shows these binds from the host's
`/dev/nvme0n1p2` into the guest.

| Mount | Options | Note |
|---|---|---|
| `/nix/store` | `ro,nosuid,nodev` | whole store |
| `/nix/var/nix/db` | `ro` | `db.sqlite` mode `0644`, readable |
| `/nix/var/nix/daemon-socket` | `ro` directory | `socket` is `srw-rw-rw-` root; `NIX_REMOTE=daemon`, `nix store info` connects: `Store URL: daemon`, **`Trusted: 1`** |
| `/nix/var/nix/gcroots`, `/nix/var/nix/profiles` | `rw` | host dirs `per-container/nc201`; empty here (no `auto` roots yet) |
| `/home/lukas` | `rw` | host `/var/lib/workers/nc201/home` |
| `/var/lib/host-credentials/{id_ed25519,id_ed25519.pub,gh-hosts.yml}` and the credentials dir's `claude_oauth_token`, `ssh_host_ed25519_key`, client `.pub` | `ro` | host user's GitHub ssh key, gh token, Claude OAuth token, the environments' ssh host key (`core.nix:90-92`) |

Also observed: the guest's own `nix config show` has `trusted-users = root root lukas`, `require-sigs`, `sandbox` (its `max-jobs = 16` is the guest's client setting; the host daemon's bound is 2 jobs of 2 cores, `hosts/lenovo-21CB001PMX/configuration.nix:75`);
the store has 134,354 top-level entries and 1,371,462 hardlink entries in `.links`; the host store filesystem
has 266G free of 468G.

These bear on #201's own safety invariant ("no host Nix daemon socket, trusted-user access, … host SSH
agent"): today's A does not meet it. Docs say workers are not trusted users (`docs/nspawn-workers.md`
"Made of"; `CLAUDE.md` already notes lenovo keeps `lukas`), but on lenovo this guest is `Trusted: 1`, because lenovo keeps `lukas` trusted
(`core/users.nix`) and the guest's uid is the host user's. I did not test what a trusted guest can do with
it. The ssh key and gh token are the open `docs/environments-feedback.md` owner decision; the OAuth token is bound the same way.

Not measurable from here, and not attempted: cold/warm realization, transfer bytes and store growth (the
shared store cannot be purged; `docs/records/shared-nix-builds-baseline.md` has n=1 cold and three warm for rf-proto,
which stays the prior evidence), the old runtime's behaviour, a closure-limited store view.

## Experiment protocol for G1 (proposal, not run)

The old protocol's `agent-runtime-native-shell-test` target no longer exists, so G1 has no VM test to
reuse; building one is more than "reproduce", and is the owner's scope call.

- Machine: disposable QEMU VM (not Acer/Lenovo/MSI), 4 vCPU, 8 GiB RAM, 40 GiB virtio disk (rf-proto's
  closure is 2.9 GB; the old comment proposed 80 GiB), substituters `cache.nixos.org` only, no daemon
  socket exported to the host.
- Cold: fresh boot from one image whose store holds only the VM's base closure, so every fixture path is
  absent; repeat 3 times with a new boot each. Warm: the same VM after one realization, 3 repeats. The host's
  store is never purged.
- Per run record, separately: `nix eval --raw .#devShells.x86_64-linux.default.drvPath` (rf-proto) and the
  llm-gateway devenv eval; `nix build` wall time with `nix path-info -rS` for paths and NAR bytes and
  download bytes from the substituter log; container start to first successful `devenv shell -- true`
  or `cargo test --offline --locked`; peak RSS (`/usr/bin/time -v`), cgroup `memory.peak`; `df -B1` and
  `df -i` of the store before and after.
- Gate: if the 2.9 GB cold fixture exceeds the VM budget, record "unmeasured" and stop.
- llm-gateway needs its private repo and a deleted harness; whether it stays a fixture is an owner call.

## For the owner at D1

- The current baseline is stock nspawn with the host daemon exposed, replaced by the owner in #210. Options A
  to D and the safety invariant were written for the removed runtime. A (no change) now means today's
  daemon-socket design, which the invariant forbids; whether #201 keeps its invariant, or is restated or
  closed against `modules/workers`, is the owner's call.
- Fixture 2's cold cost is download-bound (see `docs/records/shared-nix-builds-baseline.md`), so no slow-closure
  problem is observed yet. Choosing the one problem is G1; the inventory's only observation against #201's
  three candidates is (iii): store, db, daemon socket and, on lenovo, a trusted daemon are visible.
- Default on no decision stays `KEEP A`; nothing here authorizes B or C.
