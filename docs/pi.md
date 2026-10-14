# Pi coding agent

Module: `modules/programs/cli/pi/` (Home Manager, opt-in per host). Enabled on
`lenovo` only.

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
| Gemini (`google`, `GEMINI_API_KEY`) | built in, not yet keyed |
| Cerebras (`cerebras`, `CEREBRAS_API_KEY`; catalog: `gpt-oss-120b`, `qwen-3.8-27b`) | built in, not yet keyed |

## What the module does

- Installs `pkgs.pi-coding-agent`. The binary is also installed on every
  `devTools` host by `modules/home/pi-harness`; this module adds the config and
  credentials only where it is imported.
- Sets `PI_SKIP_VERSION_CHECK=1` (Nix owns upgrades) and `PI_TELEMETRY=0`.
- Exports provider keys in fish/bash init from `/run/secrets/<name>` when the
  file exists: `GROQ_API_KEY`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`,
  `GEMINI_API_KEY`, `CEREBRAS_API_KEY`. Only names and paths are in Nix.
- Seeds missing top-level keys into the writable `~/.pi/agent/settings.json`
  (`enabledModels` = free-tier models, longer `retry` backoff). Top-level keys you
  already have win as whole objects, not deep-merged. `auth.json`,
  `models.json` and `sessions/` are never touched.

## Credentials

Keys live in `secrets/claude/llm-cloud.yaml` (sops, age). Lenovo declares the
sops secrets in `hosts/lenovo-21CB001PMX/configuration.nix`, owner `lukas`, mode
0400, decrypted to `/run/secrets/` at activation. They never enter the Nix store
or Git in plaintext. Declaring them per host, not in `sam.hostSecrets`, keeps
them out of `/run/secrets` on acer/black-pi. Those host keys are still sops
recipients of `claude/*.yaml`, so root there could decrypt the file. To close that,
add a `claude/llm-cloud\.yaml$` rule (personal + lenovo) above the `claude/`
rule, run `sops updatekeys`, and rotate the keys, because old revisions stay
decryptable in Git history.

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
| Groq | console.groq.com → API Keys | `groq_api_key` | `GROQ_API_KEY` |
| Cloudflare Workers AI | dash → AI → Workers AI → "Use REST API" (token with *Workers AI Read+Edit*), plus account ID | `cloudflare_workers_ai_token`, `cloudflare_account_id` | `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID` |
| Gemini | aistudio.google.com → Get API key | `gemini_api_key` | `GEMINI_API_KEY` |
| Cerebras | cloud.cerebras.ai → API Keys | `cerebras_api_key` | `CEREBRAS_API_KEY` |

Interactive alternative (no sops): `/login <provider>` stores the key in
`~/.pi/agent/auth.json` (0600, outside Nix). Or reference sops without
exporting it: `{"groq": {"type": "api_key", "key": "!cat /run/secrets/groq_api_key"}}`.

### Revoke

1. Revoke the key in the provider console (this is the only step that stops it working).
2. Remove it from `llm-cloud.yaml` (`sops ...`) and the host's `sops.secrets` line, then `just switch`.
3. `/logout <provider>` in Pi if it was ever stored in `auth.json`.

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
- Remove: drop the `imports` and `sops.secrets` lines from the host config.
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

Inputs for the devenv-platform#5 catalog: Pi's built-in catalog drifts from what
providers serve, free plans gate some models per account, and Groq's free TPM
cannot sustain a multi-turn agent loop.
