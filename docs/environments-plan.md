# Developer environments: evaluation and plan

Where the nspawn environments (`docs/nspawn-workers.md`) stand after the first
dogfooding round, and what to change next, ranked. Evidence lives in
`docs/environments-feedback.md`; this file is the order of work. Marked
**owner** where the step needs a decision no agent makes (a secret, a
permission, what a host deploys, repo settings, money).

## What works (measured)

- Reboot: host back with no failed units, container up 7 s into userspace,
  agent resumed in Herdr at 15 s, home intact.
- Store: host `/nix/store` and daemon shared; a declared environment starts in
  1.9 s; first `devenv shell` 6 to 7 s with the shared fetcher cache.
- LAN store cache (harmonia, per-host keys): a path one host built is a
  download for the others.
- Burst: a gate past its reserve is throttled and swaps, 0 OOM kills so far.
- Lifecycle: declare, deploy, brief, hand over, retire; teardown removes home,
  profile and gc roots.

## What the round showed is wrong

| # | Finding | Evidence |
|---|---------|----------|
| 1 | Guests sent `max-jobs 8, cores 0` to a daemon bounded at 2 x 2; the daemon takes the client's | guest and host `nix config show` on acer; Nix `daemon.cc` |
| 2 | `MemoryLow` protects nothing: cgroup2 is mounted without `memory_recursiveprot` on acer and msi (a second cgroup2 mount at `/run/cilium/cgroupv2`) | `/proc/self/mountinfo` on both; `memory.events low 0` |
| 3 | Per-environment `MemoryHigh` stalls a lone gate while the pool sits idle | `memory.events high` 2913 (acer), 7401 (msi); the 11 to 35 min gate |
| 4 | Swap is not in the pool: zram is charged to no cgroup, 3 x 3G can exceed the device | kernel docs; zram 7.7G |
| 5 | On acer a full pool lands on kubelet's eviction line | 15.6G minus pods, system and a 7G pool |
| 6 | Every environment holds the owner's SSH key and a classic `gh` token (`repo`, `admin:public_key`); `nixos-config` main is public, unprotected, and acer applies it as root weekly | `gh api`, `modules/core/automation.nix` |
| 7 | The shared `~/.cache/nix` held the unsigned evaluation cache | Nix `eval-cache.cc` |
| 8 | `blockedNetworks` is off, and its rule covers forwarded traffic only, not guest to host | iptables semantics; not yet tested at runtime |
| 9 | lenovo's user is a trusted Nix user and lenovo serves a cache the others prefer | `core/users.nix`, `store-cache.nix` |
| 10 | Each instance is its own NixOS evaluation and build: deploy time grows with the count | `containers.<n>.config` |
| 11 | Whatever ran in an environment dies at a reboot and nothing knows what was in flight | reboot test |
| 12 | No disk bound per environment; Rust `target/` dirs are the cost (152 GB on acer) | `du` |
| 13 | The gate evaluates about 25 times | gate timing table |

## Plan, ranked by gain per line

### Now (no owner decision, small)

1. **Guests inherit the host's `max-jobs`/`cores`; per-environment evaluation
   cache; negative narinfo TTL 300 s.** Done in this branch (findings 1, 7).
   Verify after deploy: four independent 20 s derivations from a guest take
   about 40 s, not 20.
2. **Burst at the pool, not the instance** (3, 4): drop per-instance
   `MemoryHigh`; `environments.slice` gets `MemoryHigh = pool - 0.5G` and a
   `MemorySwapMax`. One line each in `core.nix`.
3. **Restore `memory_recursiveprot`** (2) so the 2G reserve is real: remount
   after Cilium, or stop Cilium mounting its own cgroup2
   (`cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup`).
   Measure first on msi: idle environment A, B fills the pool, compare A's
   major faults with and without. On acer real protection means pods are
   reclaimed before environments: **owner** for acer.
4. **`blockedNetworks` on, with an INPUT rule** for guest to host (8): RFC1918,
   link-local, pod and service CIDRs, except DNS. Runtime check next to Cilium
   on the next acer deploy.
5. **In-flight marker and shutdown drain** (11): the restart and shutdown
   notices (merged with the port branch) tell the agent; next, a
   PreToolUse/PostToolUse hook writes what is running to `~/.in-flight`, so the
   resumed agent reads facts, not memory.
6. **Nested sandboxes**: `mount -t proc -o subset=pid` works in a guest on
   kernel 7.2.10 (probed on acer); a full proc is still refused. Next: get
   bwrap and podman to ask for `subset=pid`. No nspawn weakening needed, the
   host `/proc` bind proposal is dropped.

### Next (design work, each a day)

7. **Per-environment nix-daemon in the environment's slice** on the shared
   store: builds are charged to the environment that asked, a runaway build
   is OOM-killed there, two gates share CPU by weight. About 30 lines.
   Prototype on msi; success is build memory in the environment's
   `memory.peak` and a 10G derivation failing with the agent alive.
8. **One guest system for all instances** (10): build the guest toplevel once,
   pass name, address and agent as runtime data. Then a fixed slot pool makes
   "declare" a data change with no rebuild. Measure the deploy-time split on
   acer first. Replace name-hash addresses with allocated ones (collision odds
   16% at 10 instances, 53% at 20).
9. **Parked state**: declared but stopped, started on attach; parked
   environments cost nothing, so only active ones count against the pool.
   Starting a container as the user needs a polkit rule: **owner**.
10. **Evaluation**: clone to `~/src/<repo>` so a seeded `.devenv` evaluation
    cache can apply (experiment: does it survive a copy); consolidate the
    gate's evaluations into one facts evaluation (13).
11. **Disk** (12): `min-free`/`max-free` on the host daemon; a project quota
    or a size-capped `target/` per environment.
12. **OOM victim**: `CLAUDE_CODE_SHELL_PREFIX` wrapper raising
    `oom_score_adj` on tool commands so the kernel kills the gate, not the
    agent; the same wrapper gives a per-command scope for accounting.

### Owner decisions

| Decision | Proposal | Why |
|----------|----------|-----|
| GitHub identity in guests (6, nixos-config#166) | A private GitHub App, installed on named repos with contents/PR/issues write; the host mints 1 h tokens per instance; remove the SSH key and `hosts.yml` binds | Removes account takeover and key persistence; about 40 lines |
| Root path through autoUpgrade (6) | acer upgrades from an owner-only ref, or a ruleset on public `main` once guests hold no owner token | One line; an agent push to `main` no longer runs as root |
| lenovo serving a cache (9) | Keep, knowingly, or stop lenovo serving | Any process as the owner on lenovo can sign a path acer and msi prefer |
| Claude login at 10+ environments | Workspace API keys with spend limits per host | One shared one-year token; plan terms assume individual use |
| acer pool size (5) | Pool 6G, or count the pool in kubelet's `system-reserved` | A full pool evicts pods on the single worker |
| nixos-config#200 | Adopt the signed LAN cache (already deployed), reject the SSH builder (needs a trusted client); run the three-cold, three-warm measurement on msi | |
| nixos-config#201 | Keep the whole-store read-only mount | A closure-only view breaks the shared daemon |
| Stale items | Close or rescope devenv-platform#93, #91, skills PR #92 (written against the removed agent-runtime) | |

## Secrets stay on the host

Today each environment holds three secrets: the Claude login token, the
owner's SSH key and a `gh` token (finding 6). All three can leave the guest:
the guest talks to a proxy on the host, and the proxy adds the credential.
The guest holds a placeholder.

| Secret | Verdict | How |
|--------|---------|-----|
| Claude login | Works, probed | `ANTHROPIC_BASE_URL` at the proxy, `CLAUDE_CODE_OAUTH_TOKEN=proxy-injected`; the proxy overwrites `Authorization` |
| git over HTTPS | Feasible | `url."http://127.0.0.1:4102/".insteadOf` for GitHub URLs; the proxy adds `Authorization: Basic x-access-token:<token>` |
| `gh` | Feasible | `http_unix_socket` in gh's config, `GH_TOKEN=proxy-injected`; REST filtered by `/repos/<owner>/<repo>` |
| SSH remotes, commit signing, sops age keys | Does not fit | The client holds the key by protocol. Use HTTPS remotes; guests do not sign or decrypt |

Probe (lenovo, 2026-11-12): Caddy on `127.0.0.1:4100` injecting the token
from a file, Claude Code started with the placeholder and an empty home;
`POST /v1/messages?beta=true` returned 200, the reply came back, no token in
the access log, the proxy log or the output.

### Design

- **One Caddy on the host**, a listener per instance on a unix socket in
  `/run/dev-env-egress/<name>/` (`anthropic.sock`, `github.sock`). The
  directory is bound read-only into the guest at `/run/egress`. A socket per
  instance is the identity: the proxy knows which environment asks without
  trusting anything the guest sends.
- **Guest shim**: `systemd-socket-proxyd` units, `127.0.0.1:4100` to
  `anthropic.sock` and `127.0.0.1:4102` to `github.sock`, for clients that
  want a TCP address. `gh` talks to the socket directly.
- **Secrets reach Caddy by `LoadCredential`**, never the Caddyfile: the store
  is shared with every guest.
- **Per-instance option** `egress.github = { repos = [ "owner/repo" ];
  graphql = false; }`. The proxy allows only those repository paths and the
  git smart-HTTP and REST methods they need.
- Streaming: `flush_interval -1`, pass `anthropic-beta` through. Guests set
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
- Replaces the credentials binds and tmpfiles links in
  `modules/workers/default.nix` and the token assertion. About 110 to 140
  lines in, about 25 out.
- `blockedNetworks` stays as is: a unix socket needs no network path to the
  host.

### What is left exposed

The proxy is a confused deputy: a guest can do whatever the proxy lets its
socket do. Bounds: the repository allowlist, a method allowlist, a ruleset on
`nixos-config` main, a rate limit, and an access log per instance (which is
also the audit trail that is missing today). A guest can still spend Claude
quota; it can no longer take the token elsewhere.

### Phases, each with a leak check

Leak check, from the host, per instance: `nsenter -t <leader> -m -S 1000`
finds no secret in the environment of any process, `/var/lib/host-credentials`
is gone, a grep of the guest's home and `/run` for the token prefix finds
nothing, and the Caddyfile's store path holds no token.

1. **Claude token.** Smallest and already probed. Done when an agent works a
   normal task through the proxy and the leak check passes.
2. **git.** HTTPS remotes through the proxy with a fine-grained token for the
   named repos; remove the SSH key bind. Done when clone, fetch and a gated
   push work and a push to a repo off the list is refused.
3. **`gh`.** Socket config, REST allowlist, GraphQL off. Done when `gh pr
   create`, `gh pr view` and `gh issue comment` work (find which commands
   need GraphQL; `gh pr create` does) and `gh api /user/keys` is refused.
4. **GitHub App tokens.** A host oneshot and 45 min timer mint installation
   tokens; the token in step 2 goes away. Same as nixos-config#166.

Owner decisions: subscription token behind a proxy or a Console API key
(proxying a subscription token is not a documented use; an API key at a
gateway is); create or reuse a GitHub App; the ruleset on `nixos-config`
main; GraphQL on or off; Codex auth, if Codex agents run in guests.

## Capacity

- Pool `P` = RAM - host working set (p95) - eviction margin - swap budget /
  zram ratio.
- Heavy gates at once `k` = min(slots, spare cores / a gate's effective
  parallelism).
- Active environments `N` = floor((P - k x (burst - reserve)) / reserve).
- With burst about 4.5G and reserve 1.5G (burst is to be measured): acer
  `P` 6G, `k` 1, `N` 2; msi `P` 11G, `k` 1, `N` 5.
- 10 to 30 environments is parking plus three to four hosts of this size, not
  a bigger number on these two.

## When to leave nspawn

MicroVMs lose the shared daemon, the shared page cache and cgroup burst, and
roughly halve density. Move only if environments start running code from
anyone but the owner, or a daemon escalation cannot be patched quickly. Until
then the daemon's patch level is the root boundary: keep Nix current.
