# ADR: App delivery boundary: lane 3, built as lane 1 first

Status: accepted as the working decision 2026-11-19 by the coordinator on the owner's delegation; the owner may
overrule it. Evidence read at main `4e991323` on 2026-11-18; this record written at main `9b33d6b8`. Sources: the
draft posted on #558 (https://github.com/sammasak/nixos-config/issues/558#issuecomment-6986629024, independent
review 8/10 then 9/10 on the revised text) and the epic #557. No PR carried the decision; this file is its first
copy on main.

## Decision

Lanes use #557's words (#558 calls them A/B/C): **1** bot-PR GitOps composition, host rebuilds remain; **2** immutable
app releases through a constrained executor, no OS rebuild; **3** hybrid, OS in NixOS, promotion moves to lane 2 once
its benefit is shown.

Lane 3, built as lane 1 first. An app is registered and released by a bot PR that pins its repo and rev in nixos-config
(the registry); the owner merges and `just deploy` ships it through the existing deploy-rs path. Nothing enumerates
GitHub at evaluation time: Nix reads only literal pins committed here (flake inputs, `apps/registry.json`), and the
allowlist is a file in this repo, checked by a flake check.

Lane 2 is added only through #562's measured go/no-go: when (d) holds AND at least one of (a), (b), (c) holds.

- (a) per-app releases exceed about 3 a day, so gate time dominates. *Judgement threshold, not measured*: at a gate
  p50 of about 11 min that is about half an hour of gate time a day.
- (b) a release causes an acer-swift rollback, or in-deploy app builds push acer-swift's switch p90 well past 60 s
  (*"well past" is a judgement*).
- (c) the owner prefers one standing release grant to approving every merge and deploy.
- (d) #562's VM proof passes #565's negative cases with seconds-level rollback. Necessary on its own: lane 2 adds a
  standing privileged action, and a need without the proof does not justify it.

Non-goals: no scheduler, K8s, OCI, daemon on hosts, GitHub-runner builds, runtime Caddy config, executor-handled
secrets or arbitrary repo discovery.

## Evidence (7 days to 2026-11-18)

| Query | Reading |
|---|---|
| Q1 Loki `{job="platform",kind="deploy"}`, 76 records | acer-swift switch n=14, median 51.5 s, p90 60 s, 1 deploy-failed, 0 rolled back; all hosts median 40.5 s, p90 52 s; 72 of 76 restarted no unit, so Q1 bounds the fixed switch cost, not an app build |
| Q2 Loki `{job="platform",kind="gate"}`, `gate=nixos-qa mode=push` | asus n=62 median 601 s, p90 716 s; msi n=19 median 915 s, p90 1472 s |
| Q3 Prometheus `shipping_gate_seconds` | p50 645 s, p90 1378 s |
| Q4 Prometheus `shipping_pr_phase_hours{phase="merge_to_deploy"}` | p50 0.11 h, p90 6.17 h |
| `gh api repos/sammasak/herman/compare/7f41955...de29343` | herman's pin is 305 commits behind its main |

Q1 and Q2 medians are the middle value (mean of the two for even n), p90 the ceil(0.9 n)-th value; Q3 and Q4 are the
shipping collector's interpolated quantiles, read on 18 Nov (a later read differs slightly).

So the host switch is not the release bottleneck; the gate is. *Judgement, not measured:* most release lag is the
missing bump step (the 305-commit gap is measured; that nobody bumping is its main cause is inferred).

Unknown, not guessed: herman-web build time inside an acer-swift deploy (no herman bump in the window); lane 2 switch,
rollback and restart seconds (no VM run; that is #562); stateful restore time (no drill exists).

## Security constraint on any executor

An executor must derive the store path itself from an allowlisted (repo, rev, attr), and never accept a caller-supplied
store path. Guests build through the host daemon (`docs/records/closure-staging-g0.md`), so a runtime host's store,
and its harmonia signature that every peer trusts, can hold agent-built paths. Three qualifiers keep this a design
constraint:

1. It is not a live exposure today: a peer substitutes only paths its own evaluation asks for, and those are
   derivation-determined.
2. A guest is not a trusted daemon user (`modules/roles/homelab-agent.nix` keeps `trusted-users` to root; a
   rootInGuest guest is only in `allowed-users`, `modules/workers/core.nix`), so it can build derivations in the
   sandbox but not import content under a legitimate path.
3. The risk exists only for a component that accepts a caller-supplied store path, such as lane 2's executor. Secrets
   never pass through it.

## Owner-gated

| Decision | Lane 1 / 3 now | Lane 2 later |
|---|---|---|
| Bot PR-write token on nixos-config (new credential) | yes | yes |
| Each merge to main and each `just deploy` | yes, per release | onboarding only |
| Executor as a privileged action on a host, its principal and key | n/a | yes |
| Secrets and recipients for a stateful app (#564) | yes | yes |
| DNS or a new public hostname | per app | per app |
| Third-party service | none proposed | none proposed |

## Acceptance of #558

Item 2, "an app repo release registered, pinned and deployed with zero human edits to nixos-config", is **UNMET**. It
is met only when #560's first slice (branch `platform/app-registry-slice1`, being authored) is live on main and one
release has gone through it: a bot bump PR through the gate and a deploy, with no human edit. Until then #558 stays
open.

## Consequences for the children

| # | Under this decision |
|---|---|
| #559 | Done via #570: v1alpha1 manifest and lib-only admission ([../app-manifest.md](../app-manifest.md)). The artifact is derived from (repo, rev, attr), never supplied. |
| #563 | First step done via #571: edge sites and app scrapes rendered from admission. Routes stay NixOS-rendered; no admin API; a deploy-gating per-app probe is still owed. |
| #560 | Next, the core deliverable: typed app registry plus bump command (the bump runs on acer or another gate host, never lenovo: it fetches and hashes trees; no daemon), deploy records gain the app rev. First slice in flight. |
| #561 | "Publish" means the app flake exports a package the fleet builds and signs via harmonia; GitHub runners do not publish. First step: move `pkgs/herman-web` into herman. |
| #564 | Lane-independent: reuse the llm-gateway and authentik-offhost patterns; restore drill in a VM. Real secrets are owner-gated. |
| #565 | Lane 1 part: per-host deploy lock in `just deploy`, app health probe in the post-deploy check. Per-app rollback waits for #562. |
| #562 | VM-only measurement in parallel; its result is (d) above and decides only whether lane 2 is added. No host grant. |
| #566 | Last: two repos end to end on lane 1, recording where human approvals remain; needs #559 to #565 and owner-approved deploys. |

## When to revisit

When the lane 2 trigger above holds, or the owner overrules this record.
