# Pi coding agent

Module: `modules/programs/cli/pi/` (Home Manager, opt-in per host via `sam.profile.pi`). Enabled on
`lenovo` and `acer-swift`. The default model is `homelab/auto`, the in-cluster llm-gateway.
`router/free` is an explicit fallback.

## Distribution decision (2026-10-14)

**Use `earendil-works/pi`, as packaged by nixpkgs `pi-coding-agent` (currently 1.1.0).**

- `badlogic/pi-mono` is not a separate implementation: the GitHub API resolves it
  to `earendil-works/pi` (a transfer/rename, `parent: null`, not a fork).
- The old npm name `@mariozechner/pi-coding-agent` is frozen at 0.73.1. Current
  releases ship as `@earendil-works/pi-coding-agent` (1.2.0 latest on npm).
- nixpkgs `pi-coding-agent` builds from
  `github.com/earendil-works/pi/archive/refs/tags/v1.1.0.tar.gz`, pinned by our
  `flake.lock` nixpkgs. No overlay and no mutable `npm i -g` are needed.
- Extensions, types and docs must all come from this distribution:
  `import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"`. The
  bundled docs are at `$(dirname $(readlink -f $(which pi)))/../lib/node_modules/pi-monorepo/docs/`.

Verified on the pinned 1.1.0 build:

| Capability | Status |
|---|---|
| `pi.registerVirtualModel()` / `route(request, ctx)` with `reason`, `previous`, `failed`, `state` (docs/virtual-models.md) | present: this is the API for the devenv-platform#5 `router/free` extension |
| `pi.registerProvider()`, `ctx.modelRegistry` | present |
| Groq (`groq`, `GROQ_API_KEY`) | built in, authenticated, tool calls hit free-tier TPM limits (below) |
| Cloudflare Workers AI (`cloudflare-workers-ai`, `CLOUDFLARE_API_KEY` + `CLOUDFLARE_ACCOUNT_ID`) | built in, end-to-end tool use verified |
| Gemini (`google`, `GEMINI_API_KEY`) | keyed (no-billing project); `gemini-3.5-flash-lite` passes multi-turn tool use, `3.8-flash` returned 503 "high demand" |
| Cerebras (`cerebras`, `CEREBRAS_API_KEY`; catalog: `gpt-oss-120b`, `qwen-3.8-27b`) | keyed (prepaid trial credits); both models pass multi-turn Rust tasks |

## What the module does

- Installs `pkgs.pi-coding-agent`. The binary is also installed on every
  `devTools` host by `modules/home/pi-harness`; this module adds the config and
  credentials only where it is imported.
- Sets `PI_SKIP_VERSION_CHECK=1` (Nix owns upgrades) and `PI_TELEMETRY=0`.
- Exports provider keys in fish/bash init from `/run/secrets/<name>` when the
  file exists: `GROQ_API_KEY`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`,
  `GEMINI_API_KEY`, `CEREBRAS_API_KEY`. Only names and paths are in Nix.
- Seeds missing top-level keys into the writable `~/.pi/agent/settings.json`
  (a longer `retry` backoff). Top-level keys you already have win as whole
  objects, not deep-merged. Three keys are re-pinned on every activation:
  `defaultProvider`/`defaultModel` = `homelab`/`auto`, and `enabledModels` =
  `homelab/{auto,best,local}` plus `router/free`. A `/model` choice lasts until
  the next switch. `auth.json` and `sessions/` are never touched.
- Merges two providers into `~/.pi/agent/models.json` on every activation (jq;
  replaces only those keys, so hand-written providers such as `ollama` for
  pi-harness stay): `msi-ollama` and `homelab`. A models.json that is not a
  JSON object is left alone.
  - `msi-ollama` points at msi's Ollama, the router/free local tier. Override
    the URL with `sam.pi.msiOllamaBaseUrl` in the host's Home Manager config.
  - `homelab` (the default: `homelab/auto`, also `best`, `local`) is the
    in-cluster llm-gateway (homelab-gitops `apps/llm-gateway`, pinned ClusterIP
    `10.43.0.80`, override `sam.pi.llmGatewayBaseUrl`). It holds the provider
    keys and fails over across free tiers itself. Pi authenticates with the
    project key `llm_gateway_pi_key` (`secrets/claude/llm-gateway.yaml`, every
    pi host, declared in `modules/core/sops.nix`), read per request via
    `apiKey: "!cat /run/secrets/llm_gateway_pi_key"`.

## Credentials

Keys live in `secrets/claude/llm-cloud.yaml` (sops, age). Its own rule in
`secrets/.sops.yaml` limits recipients to the personal key (used by factum's
`dev/cloud-env.sh`) and lenovo's host key (sops-nix). Lenovo declares the sops
secrets in `hosts/lenovo-21CB001PMX/configuration.nix`, owner `lukas`, mode
0400, decrypted to `/run/secrets/` at activation. They never enter the Nix store
or Git in plaintext. Revisions before the recipient narrowing were also
encrypted to acer/black-pi, so treat the keys in them as exposed and rotate them
at the provider.

Exporting keys in shell init puts them in every process started from a shell
(the same trade-off codex makes for `OPENAI_API_KEY`). For a narrower scope, use
the `auth.json` command reference below instead.

Account policy: use dedicated free-tier accounts with **no billing method
attached** wherever the provider allows it. Then exhausting quota yields a 429/403,
never a charge. Create one key per consumer (Pi vs factum) so limits and
revocation are independent.

### Add or rotate a provider key

```bash
sops secrets/claude/llm-cloud.yaml           # add e.g. cerebras_api_key: ...
# Gemini/Cerebras: add a matching line in hosts/lenovo-21CB001PMX/configuration.nix
#   sops.secrets.cerebras_api_key = llmCloudSecret;
just switch                                   # then open a new shell
pi --list-models cerebras
```

| Provider | Get a key | sops key | Env var |
|---|---|---|---|
| Groq | console.groq.com → API Keys | `groq_pi_agent_api_key` (factum keeps `groq_api_key`) | `GROQ_API_KEY` |
| Cloudflare Workers AI | dash → AI → Workers AI → "Use REST API" (token with *Workers AI Read+Edit*), plus account ID | `cloudflare_pi_agent_workers_ai_token` (factum keeps `cloudflare_workers_ai_token`), `cloudflare_account_id` | `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID` |
| Gemini | aistudio.google.com → Get API key | `gemini_api_key` | `GEMINI_API_KEY` |
| Cerebras | cloud.cerebras.ai → API Keys | `cerebras_api_key` | `CEREBRAS_API_KEY` |

Interactive alternative (no sops): `/login <provider>` stores the key in
`~/.pi/agent/auth.json` (0600, outside Nix). Or reference sops without
exporting it: `{"groq": {"type": "api_key", "key": "!cat /run/secrets/groq_pi_agent_api_key"}}`.

### Revoke

1. Revoke the key in the provider console (this is the only step that stops it working).
2. Remove it from `llm-cloud.yaml` (`sops ...`) and the host's `sops.secrets` line, then `just switch`.
3. `/logout <provider>` in Pi if it was ever stored in `auth.json`.

## router/free

Hosts with `sam.profile.pi = true` get the `router/free` virtual model from
devenv-platform `agents/pi/router-free` (input `devenv-platform`, locked in
`flake.lock`). It is linked read-only into `~/.pi/agent/extensions/router-free`.
It only routes to catalog entries marked free, verified and credentialed, and
fails closed otherwise. Behaviour, limits and tests are documented in its
README.

The catalog is in tiers. Each user turn takes the first ready model of the best
tier, so turns drop a tier while a model cools down or is spent, and climb back
when it recovers. Tool continuations stay on the model that answered. Cooldowns
and daily blocks are kept in `~/.local/state/pi-router-free/ledger.json`, which
every Pi process shares. Each routing decision is logged with its reason in
`routes.log` next to it.

| Tier | Models (2026-10-15) | Free limits observed |
|---|---|---|
| 1 best-free | `google/gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, in that order | 5 RPM and 20 RPD per model; 3.8 and 3.7 often take minutes per turn ("high demand"). Slow models sit out 10-60 min |
| 2 free-floor | `cloudflare-workers-ai/@cf/qwen/qwen3.8-27b`, `google/gemini-3.5-flash-lite` | 10k neurons/day; Flash-Lite RPM 15 |
| 3 local | none enabled. Provider `msi-ollama` (msi's Ollama, below) is wired in, but no msi model passed verification | no quota; msi is off outside its power window |

The local provider is `msi-ollama` in `~/.pi/agent/models.json`, merged in by
this module (default `http://10.43.160.41:11434/v1`, the `ollama-msi-backend`
ClusterIP; set `sam.pi.msiOllamaBaseUrl` to change it). The router probes it
before each dispatch, so a powered-off msi fails over within seconds and is used
again once it answers.

```bash
pi --model router/free        # or pick it in /model
/free-status                  # tiers, per-model state, recent routing decisions
just bump devenv-platform     # take a newer router; then just switch
```

To turn it off for one host, set `pi = false` in its `variables.nix`. That
removes the module, the key exports and the extension link. `~/.pi/agent` state
stays.

## Use

```bash
pi                                   # any repo; no devenv/factum needed
/model                               # pick provider/model; Ctrl+P cycles enabledModels
pi --list-models                     # only providers with credentials are listed
pi --model cloudflare-workers-ai/@cf/qwen/qwen3.8-27b -p "..." </dev/null   # one-shot
```

`-p` waits for stdin when it is a non-TTY pipe (scripts, agents), so close it
with `</dev/null`.

`/model` persists the choice as `defaultProvider`/`defaultModel` in
`settings.json`. Lenovo's existing default (`ollama/llama3.2:3b`) is kept until
you pick another.

## Upgrade and rollback

- Upgrade: `just bump nixpkgs && just diff && just switch`. To jump ahead of
  nixpkgs, override `pi-coding-agent`'s `src`/`version` in `pkgs/` (one tag
  bump). That overlay also changes every devTools host, because
  `modules/home/pi-harness` installs the same package. Re-run the verification
  below, since provider catalogs change between releases.
- Rollback: `sudo nixos-rebuild switch --rollback` (or pick the previous
  systemd-boot entry). Pi state in `~/.pi/agent` is version-tolerant and untouched.
- Remove: set `pi = false` in the host's `variables.nix` and drop its `sops.secrets` lines.
  Seeded keys stay in `~/.pi/agent/settings.json` until you delete them.

## Verification (2026-10-14, Pi 1.1.0)

Bounded task in a throwaway git repo (`calc.py` with `a - b` bug, "fix with
edit, run with bash"), `-p --no-session`:

| Model | Result |
|---|---|
| `cloudflare-workers-ai/@cf/qwen/qwen3.8-27b` | pass: read→edit→bash, printed `5`, ~40s |
| `cloudflare-workers-ai/@cf/openai/gpt-oss-120b` | 400 on the turn after a tool call (Workers AI rejects the tool-call message shape) |
| `cloudflare-workers-ai/@cf/moonshotai/kimi-k2.7-code`, `@cf/zai-org/glm-5.3-flash` | 403 "not available on the Workers Free plan" (fails closed, no charge) |
| `groq/openai/gpt-oss-120b`, `gpt-oss-20b` | first turn works, then 429: free tier is 8k tokens/min and one Pi turn is ~3-6k |
| `groq/qwen/qwen3.8-27b` | 400 chat-template error on tool-result role |
| `groq/llama-3.3-70b-versatile` | 404: in Pi's catalog, no longer served by Groq |
| `google/gemini-2.5-flash`, `gemini-3-flash-preview`, `gemini-3.1-flash-lite` | 402 "prepayment credits are depleted": the key in `~/.env` belongs to a billing-enabled AI Studio project |

Inputs for the devenv-platform#5 catalog: Pi's built-in catalog drifts from what
providers serve, free plans gate some models per account, and Groq's free TPM
cannot sustain a multi-turn agent loop.

## Free-router eligibility (2026-10-14, tiers 2026-10-15)

Only models listed **eligible** may be offered to a free-only router. Primary
sources: [Cloudflare pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/),
[Groq rate limits](https://console.groq.com/docs/rate-limits),
[Cerebras rate limits](https://inference-docs.cerebras.ai/support/rate-limits).

| Provider / model | Tier and cost class | Limits | Cap behaviour | Verdict |
|---|---|---|---|---|
| `cloudflare-workers-ai/@cf/qwen/qwen3.8-27b` | Workers Free, no card | 10,000 neurons/day, resets 00:00 UTC | hard stop with an error, no overage on Free | **eligible** (multi-turn tool use verified) |
| `groq/openai/gpt-oss-120b`, `gpt-oss-20b` | free org, no card | 30 RPM, 1K RPD, 8K TPM, 200K TPD (observed `x-ratelimit-limit-tokens: 8000`); per **organization**, so a second key in the same org adds no quota | 429 | eligible only with long cooldowns; the multi-turn loop is not verified |
| `groq/qwen/qwen3.8-27b` | free org | same | 429 | **excluded**: 400 on tool-result turn |
| other CF models listed above | Workers Free | | | **excluded**: 400 or 403 (paid-gated) |
| `google/gemini-3.5-flash-lite` (new no-billing project) | free tier, no billing account | free-tier RPM/RPD per project | 429; cannot bill | **eligible**, tier 2 (owner approved free-tier use 2026-10-14; free-tier prompts may be used by Google) |
| `google/gemini-3.8-flash`, `3.7-flash`, `3.6-flash`, `3.5-flash` (same project) | free tier, no billing account | 5 RPM, 20 RPD per model (429 `quotaValue`); the day ends at midnight UTC (429 `retryDelay`) | 429 with "billing" wording, which Pi does not retry; router/free rewords it and fails over | **eligible**, tier 1. Verified 2026-10-15 with read+edit+bash: 3.8 in 37s (its first run timed out at 15 min), 3.7 in 775s (minutes per turn; a second run timed out after a correct edit+bash), 3.6 in 67s, 3.5 in 15s |
| `google/gemini-3.1-pro-preview`, `gemini-pro-latest` | free tier | none: 429 quota on the first request | 429 | **excluded**: no free-tier allocation |
| `msi-ollama/*` (msi's Ollama, CPU-only i7-3770K) | local, no cost | none; 7 tok/s prefill, 4 tok/s output (7B), so the first Pi turn takes 5-7 min, over Pi's default 300s idle timeout | connection refused or timeout when msi is off | **excluded** for now (2026-10-15, idle timeout raised for the test): `qwen2.5-coder:7b` and `llama3.2:3b` return tool calls as plain text; `llama3.1:8b` calls tools but failed the task twice (wrong edits, wrong answer) |
| `google/*` with the old `~/.env` key | prepaid billing project | | 402; would bill if topped up | **excluded**; delete that key |
| `cerebras/qwen-3.8-27b`, `gpt-oss-120b` | prepaid trial credits ($5, 30 days); auto-recharge off by default | 5 RPM, 1M TPD on the trial | requests fail when credits run out; the card is only charged when credits are bought or auto-recharge is enabled | verified (logic 3/3 each); off in router/free as a separate cost class, owner decision |

Manual onboarding steps (account access is not automatable here):

1. Groq: create a key named `pi` in the console, then `sops secrets/claude/llm-cloud.yaml` and replace `groq_api_key`. Revoke the old key once factum has its own. More quota needs a separate Groq account; a new key does not add any.
2. Gemini: create a new AI Studio project with **no** billing account and a key in it. Store it as `gemini_api_key` and add `sops.secrets.gemini_api_key = llmCloudSecret;` to the lenovo config. Move or delete the plaintext `GEMINI_API_KEY` in `~/.env` (mode 0644).
3. Cerebras: only if trial credits are acceptable. Add `cerebras_api_key` the same way.
4. Rotate the Cloudflare token and Groq key that predate the recipient narrowing.
