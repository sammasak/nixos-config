# Shipping: review depth and gate scope per risk tier (proposal)

A proposal for the next slice of `docs/shipping.md`, not an implementation. Drafted 2026-11-17 at nixos-config
`83baa4c`, read against the collector's textfile on lenovo that evening. Nothing here changes a gate, a review or
an alert until a later PR implements it and the owner merges it.

## What tonight's readings say

| Reading (`/var/lib/shipping-metrics/shipping.prom`, 17 Nov evening) | Value | What it implies for tiers |
|---|---|---|
| `shipping_review_first_pass_ratio` over the last 20 reviewed PRs | 0.5 | Half the first reviews find something. No code tier can start without a review. |
| `shipping_review_rounds` p50 / p90 | 2 / 4 | The rounds are spent; whether they are spent on the risky PRs is unknown without a tier label. |
| `shipping_review_unreviewed_prs` in that sample | 4 | Some merged PRs carry no verdict comment today; a tier rule makes that an explicit choice. |
| `shipping_gate_fail_ratio` over the last 20 push gates | 0.2 | One push in five fails. The failed steps (7 d) are spread: `nixos-flake-check` 2, `platform-records-test` 2, four other tests and `nixos-lint-shell` 1 each. No single step can be skipped on that evidence. |
| `shipping_gate_seconds` p50 / p90 | 595 s / 904 s | The full gate costs about 10 to 15 minutes; the docs-only path (lints, plus the tests that read a changed doc) already exists. |
| `shipping_issues_open{class="actionable"}`, all owner repos | 36 (the coordinator's reading earlier: 37) | The queue is not shrinking fast enough to spend gate time on PRs that cannot break a host. |
| `shipping_issues_opened{window="24h"}` | 5 | |
| `shipping_pr_lead_time_hours` p50 | 0.01 h | Still the open-to-merge figure: lenovo had not deployed #522 yet. Read it again after the deploy before tuning anything on it. |
| `shipping_escapes` (24 h and 7 d) | 0 | No revert and no `escape` label yet: there is no evidence that today's depth is too low anywhere. |

So the first values below keep today's depth for everything that builds a host, and buy time only where nothing
a host runs can change: documentation and the gate's own tests.

## Tiers

A PR's tier is the highest tier any changed path falls in (changes since the merge base with `origin/main`).
First match from the top wins; a path no pattern names is `config`, never lower. Patterns are anchored at the repo
root and `*` never crosses a `/` (git's `:(glob)` pathspec); only `**` does. So `*.md` is top-level only: a nested
`SKILL.md` that a module reads into a closure stays `config`. The classifier and the tiers it reads both come from
`origin/main` (`git show origin/main:scripts/risk-tier.py`, and the policy file the same way), never from the pushed
tree, and a range that touches either is `critical` before any classifier runs. So a PR cannot lower its own tier by
widening a pattern or by editing the classifier; the implementing PR seeds both cases. The collector classifies a
merged PR against its base commit's policy, not today's main, which already holds that PR's own edits.

| Tier | Paths | Why this tier |
|---|---|---|
| `critical` | `flake.lock`, `flake.nix`, `secrets/**`, `.githooks/**`, `devenv.nix`, `Justfile`, `scripts/post-deploy-check.sh`, `scripts/gate-probe.nix`, `scripts/gate_probe.py`, `scripts/risk-tier.py`,
`modules/homelab/monitoring/shipping-policy.json`, `devenv.yaml`, `devenv.lock`, `modules/core/{boot,network,users,ssh-known-hosts,sops,fleet}.nix`, `modules/homelab/{adguardhome,tailscale,edge}.nix`, `flake-modules/hosts.nix` | Boot, reaching a host, DNS, secrets, the deploy path and the gate itself: a mistake here can strand a host or let later mistakes through. |
| `config` | everything else under `modules/`, `hosts/`, `flake-modules/`, `lib/`, `pkgs/`, and every `scripts/*` a module reads | Builds into a host. |
| `tests` | `scripts/test-*` | Only the gate reads them. A test that only a flake check runs (e.g. `scripts/test-grafana-dashboard-removal.sh`) has no `changedTests` gate, and neither has a fixture a test loads by another name (`scripts/test-native-otel-fish.nix`): any `scripts/test-*` file no gate names makes the PR `config`. |
| `docs` | `docs/**`, top-level `*.md` | No host and no gate reads them, except the tests that read a named doc (those still run). |

`scripts/*` outside `test-*` is `config`: several are store paths in a unit (`shipping-metrics.py`,
`guest-records.py`), so treating `scripts/` as tooling would ship untested code.

## Proposed policy file section

The same file, `modules/homelab/monitoring/shipping-policy.json`, as a new top-level `tiers` object. Every leaf keeps
the `{ value, tunedBy }` shape, so `rules/shipping.nix` records it for the dashboard's policy row unchanged. Values
are numbers or lists only: `setting` in `rules/shipping.nix` renders a list as its length and anything else with
`toString`, so a boolean `false` or a string would render an invalid `vector()`. Flags are therefore `0`/`1`.

```json
"tiers": {
  "critical": {
    "paths": {
      "value": ["flake.lock", "flake.nix", "secrets/**", ".githooks/**", "devenv.nix", "Justfile",
                "scripts/post-deploy-check.sh", "scripts/gate-probe.nix", "scripts/gate_probe.py",
                "scripts/risk-tier.py", "modules/homelab/monitoring/shipping-policy.json", "devenv.yaml", "devenv.lock", "modules/core/boot.nix",
                "modules/core/network.nix", "modules/core/users.nix", "modules/core/ssh-known-hosts.nix",
                "modules/core/sops.nix", "modules/core/fleet.nix", "modules/homelab/adguardhome.nix",
                "modules/homelab/tailscale.nix", "modules/homelab/edge.nix",
                "flake-modules/hosts.nix"],
      "tunedBy": "sum(shipping_escapes{window=\"7d\",tier=\"critical\"})"
    },
    "reviewers": { "value": 2, "tunedBy": "shipping_review_first_pass_ratio{tier=\"critical\"}" },
    "minGrade": { "value": 9, "tunedBy": "shipping_review_first_pass_ratio{tier=\"critical\"}" },
    "seededFailureRequired": { "value": 1, "tunedBy": "sum(shipping_escapes{window=\"7d\",tier=\"critical\"})" },
    "gateSteps": { "value": ["lints", "secretsVerify", "probe", "tests", "sideBySide", "parity"], "tunedBy": "shipping_gate_fail_ratio{tier=\"critical\"}" },
    "dryActivateRequired": { "value": 1, "tunedBy": "sum(shipping_deploy_rollbacks{window=\"7d\"})" }
  },
  "config": {
    "reviewers": { "value": 1, "tunedBy": "shipping_review_first_pass_ratio{tier=\"config\"}" },
    "minGrade": { "value": 9, "tunedBy": "shipping_review_first_pass_ratio{tier=\"config\"}" },
    "seededFailureRequired": { "value": 1, "tunedBy": "sum(shipping_escapes{window=\"7d\",tier=\"config\"})" },
    "gateSteps": { "value": ["lints", "secretsVerify", "probe", "tests", "sideBySide"], "tunedBy": "shipping_gate_fail_ratio{tier=\"config\"}" },
    "dryActivateRequired": { "value": 0, "tunedBy": "sum(shipping_deploy_rollbacks{window=\"7d\"})" }
  },
  "tests": {
    "paths": { "value": ["scripts/test-*"], "tunedBy": "shipping_gate_seconds{quantile=\"0.5\",tier=\"tests\"}" },
    "reviewers": { "value": 1, "tunedBy": "shipping_review_first_pass_ratio{tier=\"tests\"}" },
    "minGrade": { "value": 9, "tunedBy": "shipping_review_first_pass_ratio{tier=\"tests\"}" },
    "seededFailureRequired": { "value": 1, "tunedBy": "shipping_review_first_pass_ratio{tier=\"tests\"}" },
    "gateSteps": { "value": ["lints", "secretsVerify", "probe", "changedTests"], "tunedBy": "shipping_gate_fail_ratio{tier=\"tests\"}" }
  },
  "docs": {
    "paths": { "value": ["docs/**", "*.md"], "tunedBy": "shipping_gate_seconds{quantile=\"0.5\",tier=\"docs\"}" },
    "reviewers": { "value": 1, "tunedBy": "sum(shipping_escapes{window=\"7d\",tier=\"docs\"})" },
    "gateSteps": { "value": ["lints", "docTests"], "tunedBy": "shipping_gate_fail_ratio{tier=\"docs\"}" }
  }
}
```

`config` has no `paths`: it is the default. The step names are the groups `devenv.nix` already has (`lints`,
`secretsVerify`, `probe`, `tests`, `sideBySide` with the flake check, `docTests`); `changedTests` is the `docTests` mechanism keyed on
changed `scripts/test-*` names instead of doc names, and `parity` is `just parity` with the moved hosts named in the PR.
Only `docs` and `tests` change today's behaviour: `docs` writes down what the pre-push hook already does, and `tests`
skips the flake check and the other tests for a PR that touches nothing a host or another test reads.

## What has to exist before any value is live

1. **A tier per merged PR.** One classifier, `scripts/risk-tier.py`, reading `tiers.*.paths` from the policy file:
   the pre-push hook calls it on the pushed range, the collector on each merged nixos-config PR's file list
   (`/repos/.../pulls/{n}/files`, one call per PR, the same fallback rules as the commits call). Other repos keep
   their own SDLC gates and get no tier.
2. **Tier-labelled metrics**, so every `tunedBy` above names a series that exists. Today's `shipping-rules` check
   would NOT catch a missing one: `scripts/shipping-names.py` strips `{...}` before comparing names, so a
   `tier="critical"` selector over an existing metric passes and its reading is just empty. Pasting the JSON in early
   stays green; the implementing PR extends the check to the label values the collector emits. Labels: `tier` on `shipping_review_first_pass_ratio`, `shipping_review_rounds`,
   `shipping_gate_fail_ratio`, `shipping_gate_seconds` and `shipping_escapes` (a revert takes the tier of the PR it
   reverts). The gate record (`pkgs/platform-record`, its fields in `metrics/records.json`) gains a `tier=` field.
3. **The pre-push hook reads `gateSteps`** for the pushed range's tier and prints which steps it skipped and why, as
   the docs-only path does now. A tier the classifier cannot decide is `config`.
4. **Review requirements stay a checklist the coordinator applies**, read from the file; nothing enforces them
   mechanically yet. The `shipping_review_*` metrics show whether they are met. The coordinator takes a PR's tier
   from its own run of main's classifier and policy on the PR's file list (the pulls API, against `base.sha` on
   GitHub, not a local `origin/main` the pusher can move), never from the gate record: the pre-push hook runs the
   pusher's own `devenv.nix` gate code, so a PR could make it record `tier=docs`. The record's `tier=` is a
   cross-check only, and a mismatch makes the PR `critical`. A PR touching `devenv.nix` or `.githooks/**` runs its
   own gate code, so its safety rests on its two `critical` reviewers, not on the hook. The `tests` fallback for a
   `scripts/test-*` file no gate names lives in the classifier's code, since `tests.paths` cannot express it.

Then run a week with the values above before changing any of them.

## How a value moves

The existing rule holds: a PR that quotes the dashboard's **Policy signals** row. Proposed starting criteria, all
over at least 7 days and at least 10 PRs of that tier:

- **Relax** a tier one step (fewer reviewers, or a gate step dropped) only if its `shipping_escapes` stayed 0, its
  first-pass ratio is at or above 0.8 and its gate fail ratio is under 0.1.
- **Tighten** a tier at once after any escape attributed to it: one more reviewer, or the step that would have caught
  it added to its `gateSteps`, in the PR that fixes the escape.
- `critical` never drops below one reviewer at `minGrade` 9, and never loses `lints`, `secretsVerify`, `probe`,
  `tests`, `sideBySide` or `parity`. No tier ever loses `lints` or `secretsVerify` where it has them today.

## Left outside the file

These are the owner's alone (`~/.claude/CLAUDE.md`, "Keep Moving Without Impersonating the Owner") and no metric may
relax them, so they get no entry in a file whose purpose is tuning by metrics:

- merging a PR or pushing to a default branch, and never a force push;
- switching or deploying a host, and any rollback;
- cutting a release tag;
- changing secrets or permissions, and granting a new privileged remote action;
- any destructive operation;
- `--no-verify` or any other way past the pre-push hook.

A tier changes how much evidence reaches the owner, not who decides.

## Open questions for the implementing PR

- Lowering `docs` to `reviewers: 0` would depart from the standing rule that every PR gets an independent review,
  and `CLAUDE.md` falls in that tier. That is the owner's decision, not a tuning value, so the file starts at 1.
- `dryActivateRequired` needs the target up (ssh, and its sudo for the dry activation). A `critical` PR touching a
  sleeping host (msi outside its window, asus off) waits for it, or the owner waives it for that PR.

- Whether `tests`-tier PRs may batch: a red `changedTests` run points at one file, so batching costs little.
- Whether a `critical` second reviewer must be a different model, or only a fresh session.
- If the owner allows `reviewers: 0` for `docs`, whether to still sample one in five for review, to keep its escape
  count meaningful.
