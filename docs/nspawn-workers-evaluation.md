# nspawn developer environments on acer-swift and msi: evaluation

As of 2026-11-12, nixos-config main 93418e3. Reference manual: `docs/nspawn-workers.md` (declaring, sizing,
lifecycle, permissions, store options tried). This file is the verdict against the goal, not a second manual.

## Verdict per goal item

| Goal item | State | Evidence |
|---|---|---|
| msi and acer reboot and work as nspawn hosts | Met | Both use the same runtime-host role: headless, maintenance off the boot path. msi, measured: container autostarts 6 to 7 s into userspace, agent back in Herdr at 14 to 15 s and resumes its conversation. acer, two reboots on 2026-11-12 with one environment declared, from the host journal: container start at 6.8 s, container and its session surface up at 15.0 and 15.2 s, k3s started alongside at 13.6 s, host startup finished at 51 s; the environment then worked for 29 minutes until it was retired. A guest that never gets ready is retried 3 times in 10 min, then stays failed instead of wedging the next deploy (#263, seen live on msi). |
| Guests use the host nix store, instant access | Met, with a known floor | Store is the host's, read-only bind, builds through the host daemon. Clone 3 to 6 s. Fresh clone of a seen commit: 6 s (factum), 17.6 s (herman), per-checkout evaluation plus 1 to 4 s of small builds. Warm shell under 1 s. A package no public cache has: 71 s on msi, 2.7 s in an acer environment afterwards over the LAN cache. |
| Lifecycle | Met, one step unobserved | Declare, deploy (37 s), work, resize live, stop, retire (home to trash for a week). Removing a declaration never deletes a home; only `retired` does. Declaring the first and retiring the last environment no longer restarts NetworkManager (#267, checked both directions on acer). The deletion from trash after a week has not been observed, see "Not yet verified". |
| Resources, burstable | Met | Per environment `MemoryLow` reserve, pool-level limit and swap. One environment alone reached 10.06G of a 10G pool with 4.6G in swap, no kill. A 17G runaway lost only that process; neighbour kept its 1.5G. cargo build of factum on msi: 65 s, 4.7G peak, zero throttle or OOM events. |
| Agents never blocked on a permission prompt, own their environment | Met | `rootInGuest`: guest root is an unprivileged host uid range, passwordless sudo inside (#258). Agents start in bypassPermissions. A full dogfood run (clone, devenv shell, cargo build) hit no prompt. |
| Dogfood | Met | The module changes from #258 on were written, gated and pushed from environments on acer or msi, briefed from lenovo through Herdr. Each environment was retired after its work landed. |
| Lean | Met for now | #265 dropped three unused options and duplicate test cases. Two store designs and one cache seed were built, measured and left unmerged rather than carried. Module total: core 736, adapter 367, nested sandbox 91, role 61, store cache 62 lines. |
| Performance improvements found | See "Performance" | |

## Store: what was tried, what stays

1. Shared host daemon, read-only store bind. Stays. Fast, one store, one GC, LAN cache for free.
2. No daemon socket, read-only store only (`feat/no-daemon-socket`). Dropped: a fresh clone's `devenv shell` must build its shell derivations.
3. Local overlay store over the live host store (`feat/store-overlay`). Dropped: the lower store opens the host db immutable and ignores its WAL, so recently registered paths, the guest's own system among them, are "not valid". It works only over a frozen snapshot of the store (as Replit's lower store is), which is a different product from the host's live store.
4. Fetcher-cache seed for new environments (`feat/fetch-cache-seed`). Dropped after three reviews (4, 6, 7 of 10): each repo pins its own nixpkgs, so a seed from one lock misses the others.

## Performance

`devenv shell -- true` wall time in a fresh environment.

| Case | Host | Wall | Where it goes |
|---|---|---|---|
| Same checkout, second shell | both | 0.2 to 0.95 s | devenv's per-checkout eval cache |
| Fresh clone of a lock this environment has seen | acer, msi | 6.5 s (factum), 17.6 s (herman) | evaluation plus 1 to 4 s of small builds |
| First shell in a new environment, closure already in the host store | acer | 20 s (herman), 26 s (factum) | 12 to 15 s fetching input tarballs (nixpkgs 8 to 9 s, rust-overlay 3 s, devenv 1.5 s), 5 s evaluation, 2 s small builds; 0 substitutions |
| First shell, closure not in the host store | acer | 88 s (factum moved to another nixpkgs) | about 63 downloads (3.9 GB, 17 of them from the LAN caches) and local assembly of the Rust toolchain (rustc 37 s, twice in parallel) |
| First shell, closure not in the host store | msi | 92 s (herman, first run on the host) | not broken down; most likely the same cause |
| cargo build factum, cold target | msi | 65 s | all 8 cores, 4.7 GB peak, 2.6 GB target dir, no throttle |

So the store sharing does what was asked: once any environment or the host has realised a repo's closure, every
other environment gets it for free and pays only fetch and evaluation. The 88 to 92 s cases are a closure the host
has never had.

Tested and rejected: pinning only nixpkgs. Moving factum to herman's nixpkgs alone shared 13 of 262 store paths
and cost 88 s, because the toolchain closure is keyed by nixpkgs and rust-overlay together. Copying all of herman's
pins into factum fails outright (herman's rust-overlay does not know Rust 1.99).

Plan, in order of value per line of code:
1. One pin set for the fleet (nixpkgs, rust-overlay, devenv, git-hooks) owned by devenv-platform, at the newest
   revision any repo needs, bumped in one place. Then a host that has seen any repo has the toolchain closure for
   all of them: a new repo's first shell drops from the 88 to 92 s case to the 20 s case or better, and each host
   stores one toolchain closure instead of one per repo (factum's alone is 3.9 GB). Unverified: whether herman
   builds on the newest pin. This is work in devenv-platform and the consumer repos, not in the nspawn module;
   it needs an approved issue there.
2. Nothing in the module for the 12 to 15 s of tarball fetches. The seed built for it was dropped; with one pin set
   the tarballs are the same four for every repo and a per-host shared fetcher cache becomes worth one more look.
3. Judged not worth doing: sharing the eval cache (devenv's is per checkout, so it would not help a fresh clone),
   pre-built cargo targets (2.6 GB of state per repo to save about 60 s).

Also found while measuring: an environment confined with `egress.github.repos` needs `sammasak/devenv-platform` in
that list or no `devenv shell` works in factum or herman (the input is private). The git and nix fetchers both go
through the proxy rewrite without an SSH key once it is listed.

## Decisions

- `rootInGuest` is the recommended setting for every new environment, but stays opt-in in code. It is what removes
  permission prompts and gives the guest its own sshd key. Toggling it on an existing environment is refused by
  design (ownership on disk differs), so flipping the default would break any declared environment on a rollback
  or older checkout.
- No standing environments. Each one is retired when its work has landed.
- msi stays a weekday host (power window); acer is the always-on one, with 2 environments recommended as the cap
  because k3s pods take 4.6G there.

## Checked on a live host, not covered by a test

- Restart notice: an agent with a background `sleep 3600` running; a deploy changing its `model` restarted its
  agent unit. The job was gone, the agent resumed the same conversation on the new model, received the notice,
  checked, and reported the job killed (acer).
- Per-name host key: `ssh <name>.acer` from lenovo to a `rootInGuest` environment connected without a prompt and
  recorded the guest's own key.
- First and last environment: declaring one on a host with none, and retiring the last, left NetworkManager's
  start time unchanged (acer).

## Not yet verified

That a retired home is really gone from `<stateDir>/.trash` a week later. The directory is root 0700. The move into
trash is covered by the eval test; the deletion is one `find -cmin +10080` line and has not been observed on a
host. First possible check: after 2026-11-19 on acer, `sudo ls /var/lib/workers/.trash` should list no entry dated
20261112.

Also not exercised: msi with a fresh `rootInGuest` environment after #267.

## Open items outside this module

- Credentials: rotate the Claude token, the gh token and SSH key used by environments, and the shared sshd host
  key on msi from before per-environment keys.
- GitHub App identity for agents (nixos-config #166) and a ruleset on nixos-config main.
- Codex authentication in environments.
- Readers of the harmonia signing key on the cache hosts.
- Leftover `per-container/worker-1` profile and gcroot directories on acer from the first prototype (root only).
- Workflow questions not decided: who starts a task, whether a GitHub issue is always the unit of work, and
  whether environments are for interactive use too or for agents only.
