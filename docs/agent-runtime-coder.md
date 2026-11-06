# Agent-runtime coding agent: the real Claude Code in nspawn (#169)

The step after the #165 cargo pilot: one real Claude Code coding task inside the runtime, ending in
a nonempty patch the trusted host verifies before anyone reviews or promotes it. This file is the
template, what non-interactive Claude Code needs, the authentication options for the owner, and
the promotion path. Nothing here is enabled on a host, and no real credential is used.

## The template: `claude-coder` (`modules/agent-runtime/templates/claude-coder.nix`)

| field | value |
|---|---|
| source | `sammasak/rf-proto` at the flake's pinned `inputs.rf-proto` rev, a private writable copy at `/workspace/rf-proto`. Zero dependencies, so `cargo test --offline --locked` builds with no network |
| agent | `pkgs.claude-code` (2.1.300 at this nixpkgs), the real binary, run by `claude-coder-run` |
| skills | `rust-engineering` from the pinned skills input |
| network | none (`egress: none`) |
| credentials | no GitHub capability at all. The harness key is a per-run `--credential` file (below) |
| resources | 2 CPUs, 2048 MiB (no swap), 512 tasks, 30 min; volumes 1920 MiB together |

`claude-coder-run [--turn-seconds N] TASK`:
1. It refuses (exit 77, `result.json` `auth: "missing"`) when `/run/agent-runtime/credentials/token` is absent, so the model is never called without a delivered key.
2. Otherwise it runs `claude -p TASK --output-format json --permission-mode acceptEdits --allowedTools <list>` under `timeout` (default 600 s).
3. It then runs the project's `cargo test --offline --locked`.
4. It writes `claude.json`, `claude.err`, `cargo-test.log`, `result.json` and `SHA256SUMS` to `/output`.

The allowlist is Read, Edit, Write, Glob, Grep, `cargo test`/`cargo build`, and `git diff`/`git status`; anything else is refused in `-p` mode.

## Non-interactive Claude Code: what it needs (measured with 2.1.300)

- **`-p` with `--output-format json`.** One turn, a machine-readable result: `is_error`, `terminal_reason`, `result`, `num_turns`, `total_cost_usd`.
- **`--permission-mode acceptEdits` plus `--allowedTools`, not `--dangerously-skip-permissions`.** The bypass flag refuses to run as root, even mapped root in a user namespace (`--dangerously-skip-permissions cannot be used with root/sudo privileges`). It is also more than an edit task needs. The runtime runs the agent as the unprivileged `agent` uid either way.
- **Without a credential it fails at once:** exit 1 in under a second, with `{"is_error": true, "terminal_reason": "api_error", "result": "Not logged in · Please run /login", "total_cost_usd": 0}`, and no edit (the VM test asserts exactly this).
- **With a key but no egress it does not fail fast.** It retries the API until killed: 120 s with no answer in a probe. So the runner bounds every call with `timeout`, and the instance's `RuntimeMaxSec` bounds the whole run.
- **Environment:** `DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, so a live run needs only the API host. HOME is the instance's private home volume; Claude writes its state there and it is never exported.

## Authentication (owner decision; nothing here is provisioned)

Harness authentication is separate from GitHub credentials. The template declares no capability, so
no GitHub token can be delivered to it.

| option | scope | verdict |
|---|---|---|
| **A per-run Anthropic API key** from a dedicated Console workspace with a spend limit, delivered by `agent-runtime-instance start --credential FILE` | only API calls, billed to that workspace, revocable in the Console | **recommended**. The existing delivery holds it on tmpfs, read-only to the agent, redacted from logs; export refuses an artifact that contains it (#137) |
| `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` | the owner's subscription, long-lived | not recommended: broader and longer-lived than one run |
| mounting the host's `~/.claude`, OAuth files, SSH agent or general API keys | everything the owner's session can do | **refused by design**: no host mount exists in the template |

A live run also needs egress to the API host only: `network.allow = [ "api.anthropic.com" ]`, which
the #137 egress allowlist pins to the resolved IPs (DNS and TLS 443, nothing else). That is a
template change and is owner-gated, like the key.

## Export, verification and promotion

1. `agent-runtime-instance export ID` writes the bundle:
   - `sources/rf-proto.patch` and its record (base rev, narHash, changedPaths, patchSha256, the resulting tree id);
   - the output files, `run.log`, and `bundle.json` with every file's sha256.
2. **`agent-runtime-verify --bundle DIR --require-change`** (on the host's PATH with the substrate) is the trusted host's check. It never runs the patch. It refuses:
   - a missing or edited file (sha256 against `bundle.json`);
   - an interrupted export (no `bundle.json` or `sources/export.json`);
   - a patch omitted at export as oversized, or over `--max-patch-bytes` (default 1 MiB);
   - a malformed patch;
   - a path outside the repository or under `.git`;
   - paths that differ from the record;
   - a base whose narHash differs;
   - a patch that does not apply, or does not reproduce the recorded tree;
   - with `--require-change`, an empty patch.

   It prints `{kind: "agent-runtime-verified", bundleSha256, sources: {name: {base, patchSha256, tree, changedPaths}}}`.
3. **An independent reviewer** reads the verified patch against the pinned revision, re-runs the project's tests on it in a fresh instance, and grades it.
4. **Promotion is the trusted host's:** apply the verified patch to a clean clone at the base rev, commit, and push a branch with the host's own `gh`, then open the PR. The runtime never holds a GitHub token, and nothing is pushed or merged from inside it.

## Status of #169's acceptance

- **Disposable VM evidence:** `packages.x86_64-linux.agent-runtime-coder-test`, model-free.
  - nspawn launch and cleanup, with the real binary, the skill and the source inside;
  - bounded resources;
  - fail-closed auth, from both the real binary and the runner;
  - a bounded run without egress that never leaks the key;
  - a nonempty patch verified against the pinned rev;
  - the verifier's refusals;
  - cancellation, and the host unaffected.
- **A real model turn producing a patch:** **not done**. It needs the owner's key (option above) and the egress allowlist, and it is a live run on a host. The VM's nonempty patch comes from a labelled model-free fixture edit, not from Claude.
- **Independent review and promotion of a real artifact, with SHA, digest and cost:** after that live run.
