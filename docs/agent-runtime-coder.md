# Agent-runtime coding agent: the real Claude Code in nspawn (#169)

The step after the #165 cargo pilot: one real Claude Code coding task inside the runtime, ending in
a nonempty patch the trusted host verifies before anyone reviews or promotes it. This file is the
template, what non-interactive Claude Code needs, the authentication options for the owner, and
the promotion path. The template's own defaults are inert — no egress, no credential. **acer-swift
and msi-ms7758 are the two hosts that admit it**: each renders `eligibleTemplates = [ "rust-pilot"
"claude-coder" ]` with `templates.claude-coder.network.allow = [ "api.anthropic.com" ]`
(`hosts/<host>/configuration.nix`) and holds the SOPS subscription token (`sam.hostSecrets`; msi is
a recipient of `claude/oauth.yaml` only). The supervised live run below is written for acer; on msi
the steps are the same without the acer heavy-work lock.

## The template: `claude-coder` (`modules/agent-runtime/templates/claude-coder.nix`)

| field | value |
|---|---|
| source | `sammasak/rf-proto` at the flake's pinned `inputs.rf-proto` rev, a private writable copy at `/workspace/rf-proto`. Zero dependencies, so `cargo test --offline --locked` builds with no network |
| agent | `pkgs.claude-code` (2.1.300 at this nixpkgs), the real binary, run by `claude-coder-run` |
| skills | `rust-engineering` from the pinned skills input |
| network | the template's **default** is none (`egress: none`); acer-swift overrides it to `egress: allowlist`, `allow = [ "api.anthropic.com" ]` (the #137 allowlist pins the resolved IPs, TLS 443 only). acer and msi are the only hosts that admit this template (msi sets the same override) |
| credentials | the template grants no GitHub capability. The harness token is a per-run `--credential` file, the SOPS subscription token (below) |
| resources | 2 CPUs, 2048 MiB (no swap), 512 tasks, 30 min; volumes 1920 MiB together |

`claude-coder-run [--turn-seconds N] TASK`:
1. It refuses (exit 77, `result.json` `auth: "missing"`) when `/run/agent-runtime/credentials/token` is absent, so the model is never called without a delivered token.
2. Otherwise it runs `claude -p TASK --output-format json --permission-mode acceptEdits --allowedTools <list>` under `timeout` (default 600 s).
3. It then runs the project's `cargo test --offline --locked`.
4. It writes `claude.json`, `claude.err`, `cargo-test.log`, `result.json` and `SHA256SUMS` to `/output`.

The allowlist is Read, Edit, Write, Glob, Grep, `cargo test`/`cargo build`, and `git diff`/`git status`; anything else is refused in `-p` mode.

**Recommended hardening (not yet wired in):** add `--strict-mcp-config` to the runner's `claude -p`
line so Claude Code ignores any MCP server config it would otherwise discover on disk (the runner
passes no `--mcp-config`, so this means no MCP servers at all — one fewer uncontrolled subprocess and
egress path). It is left out of the runner here because its acceptance by this exact binary (2.1.300)
is a live-binary behaviour not exercised by the offline `agent-runtime-coder-test` (the VM test drives
its own `claude -p` probes, not `claude-coder-run`); add it to `claude-coder-run` once confirmed
against the deployed binary. The offline eval check (`agent-runtime-acer-pilot`) would still pass with
the flag present, since it adds no `ANTHROPIC_*`/`apiKeyHelper`/`ANTHROPIC_BASE_URL` string.

## Non-interactive Claude Code: what it needs (measured with 2.1.300)

- **`-p` with `--output-format json`.** One turn, a machine-readable result: `is_error`, `terminal_reason`, `result`, `num_turns`, `total_cost_usd`.
- **`--permission-mode acceptEdits` plus `--allowedTools`, not `--dangerously-skip-permissions`.** The bypass flag refuses to run as root, even mapped root in a user namespace (`--dangerously-skip-permissions cannot be used with root/sudo privileges`). It is also more than an edit task needs. The runtime runs the agent as the unprivileged `agent` uid either way.
- **Without a credential it fails at once:** exit 1 in under a second, with `{"is_error": true, "terminal_reason": "api_error", "result": "Not logged in · Please run /login", "total_cost_usd": 0}`, and no edit (the VM test asserts exactly this).
- **With a credential but no egress it does not fail fast.** It retries the API until killed: 120 s with no answer in a probe. So the runner bounds every call with `timeout`, and the instance's `RuntimeMaxSec` bounds the whole run.
- **Environment:** `DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, so a live run needs only the API host. HOME is the instance's private home volume; Claude writes its state there and it is never exported.

## Authentication: the Claude Code subscription token (owner decision 2026-11-06)

The harness authenticates with the owner's existing **Claude Code Max subscription token**, nothing
else: no `ANTHROPIC_API_KEY`, no Console key, no pay-as-you-go billing, no new auth service. Harness
auth is separate from GitHub: the template grants no GitHub capability.

**How the token is deployed on worker hosts today** (checked read-only; no value printed):
- `modules/core/sops.nix` declares `sops.secrets.claude_oauth_token` from `secrets/claude/oauth.yaml`, `owner = <user>`, `mode = "0400"`.
- sops-nix decrypts it to `/run/secrets/claude_oauth_token`. On acer-swift, `stat` shows a regular file, mode `400`, owner `lukas:users`, 108 bytes (a symlink into `/run/secrets.d/<generation>/`).
- Interactive sessions get it from `modules/programs/cli/claude-code/mcp.nix`: fish `interactiveShellInit` runs `set -gx CLAUDE_CODE_OAUTH_TOKEN (cat /run/secrets/claude_oauth_token)`.

**How an instance receives it, per run:**
1. The operator, as root on the host, passes the file to start: `sudo agent-runtime-instance start ID --credential /run/secrets/claude_oauth_token -- <claude-coder-run> '<task>'`.
2. The start copies it to the run's own tmpfs (`/run/agent-runtime/ID/cred/token`, never `/var/lib`, never the store). It hands it to the instance read-only at `/run/agent-runtime/credentials/token`, owned by the instance's mapped agent uid, mode `0400`.
3. No host directory is mounted. `~/.claude` and `/run/secrets` stay outside the instance.
4. `claude-coder-run`:
   - first probes every pinned egress host (the instance's `/etc/hosts`, loopback skipped) on TCP 443 for 8 s. One that does not connect stops the run at once: exit 75, `result.json` `egress: "unreachable"` with the host and IP. That replaces a 600 s `claude` retry loop (#169);
   - reads the file and passes the token **only in the `claude` process's environment** (`CLAUDE_CODE_OAUTH_TOKEN=… claude -p …`);
   - first unsets `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`, so no other auth path exists;
   - does **not** set `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`. Measured: that mode runs tools in bubblewrap and drops 19 empty placeholder files and directories into the working directory (`.env*`, `package.json`, `yarn.lock`, `node_modules/`, `.claude/`, …). Here that means into the repository, so into every patch. Per `mcp.nix`'s note, 2.1.300 withholds `CLAUDE_CODE_OAUTH_TOKEN` from tools even with the scrub off;
   - adds a `Read(//run/agent-runtime/credentials/**)` deny rule for the Read tool.

   Which processes see the token at runtime is the harness's behaviour and is not tested offline here.
5. **Logs and artifacts:**
   - the export redacts it from `run.log`;
   - it **refuses** an export whose output files *or source patch* contain it;
   - it refuses an export of a run that had a credential whose tmpfs copy is gone (a reboot) until the token is re-passed: `export ID --credential FILE`.
6. `destroy` removes the tmpfs copy.

**Residual risk, stated plainly.** The agent's tools run as the same uid as the delivered file and the
`claude` process. So code the agent writes and runs (`cargo test` on its own edit) can read the file or
`/proc/<claude>/environ`, and the subscription token is long-lived and broad. The literal-match leak
gate stops a plain copy in the patch, the output or the log. An *encoded* copy defeats a literal grep.
The defences then are:
- no egress except the API host in a live run, so no direct exfiltration;
- the human review of the patch before promotion.

Separating the tool uid from the credential holder is not done here.

A live run also needs egress to the API host only: `network.allow = [ "api.anthropic.com" ]`. The
#137 egress allowlist pins it to the resolved IPs (DNS and TLS 443, nothing else). That template
change, and the run itself, are owner-gated.

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
4. **Promotion is the trusted host's:** `agent-runtime-promote --bundle <dir> --template <manifest> --into <clean clone at the base rev> --branch <name>` re-verifies the bundle (refusing an unverified or no-op one), applies the verified patch, confirms the staged tree equals the verifier's, commits it on the branch, and prints a record with the new commit sha and the bundle digest. Then push that branch with the host's own `gh` and open the PR. The tool never fetches, pushes, or holds a GitHub token; nothing is pushed or merged from inside the runtime.

## The supervised live run (owner-gated, not performed here)

**This run uses the real subscription token and real egress; it is the owner's to perform, and it is
not done in this change.** It is armed only once acer-swift is deployed with `claude-coder` eligible
and the egress allowlist set (both in `hosts/acer-swift/configuration.nix`: `eligibleTemplates =
[ "rust-pilot" "claude-coder" ]` and `templates.claude-coder.network.allow = [ "api.anthropic.com" ]`).
`checks.x86_64-linux.agent-runtime-acer-pilot` pins exactly that shape, so a widened allowlist, an
extra host, a credential capability or a reintroduced `ANTHROPIC_*` auth path fails `nixos:qa`.

The run holds acer's heavy-work lock the whole time, so no agent gate (VM tests, `nixos:qa`, nix
builds) runs beside it; the 4 GiB reserve covers a k3s surge, not a second heavy job. Root steps are
`sudo` on acer; driven from a trusted workstation they are `ssh deploy@acer-swift sudo …`. The
commands are bash; your login shell is fish.

```
flock --verbose /tmp/acer-swift-heavy-work.lock bash   # on acer; holds the lock until this shell exits
H=/etc/agent-runtime/host.json
T=/nix/var/nix/profiles/agent-runtime/templates/templates/claude-coder.json
RUN=$(jq -r '.packages[] | select(.name == "claude-coder-run") | .storePath' "$T")/bin/claude-coder-run
CRED=/run/secrets/claude_oauth_token
# B, the run's own bundle (exports/coder.runs/<runId>, #184; survives destroy; 0700 root), is set at export (step 6)
# create/attach take the tracking REF (OWNER/REPO#N); the model is given the PROMPT. They are NOT the
# same string: `agent-runtime-herdr attach` dies 64 on a ref that is not OWNER/REPO#N, and `create
# --task` records that same ref. The PROMPT (below) is the runner's argument, i.e. `claude -p`'s task.
REF=sammasak/nixos-config#169
PROMPT='In src/lib.rs, add a #[must_use] attribute to the public `varint` function (the one-line fixture helper, "/// Encode a varint length prefix (test/fixture helper)."). Change nothing else.'

# 1. Preflight (read-only; must end "preflight: go"). --herdr-user is the user whose Herdr answers.
#    --credential adds the subscription-token check: present, a regular file, owner-only (0400/0600),
#    non-empty and owned by the operator -- metadata only, the token is never read or printed (#169).
sudo agent-runtime-preflight --template "$T" --herdr-user lukas --credential "$CRED"

# 2. (optional, same facts by eye) owner/mode of the token; never prints it:
stat -c '%U %G %a' "$CRED"                       # expect: lukas users 400 (sops-nix, modules/core/sops.nix)

# 3. Create the instance against the tracking REF:
sudo agent-runtime-instance create coder --template "$T" --host "$H" --task "$REF"

# 3b. (Herdr visibility) As the HERDR USER — not root — attach a status MIRROR, so the run shows in
#     Herdr with NO new privilege. It starts nothing: its pane holds a benign placeholder that only
#     waits, and a follower maps the root-written, world-readable mirror.status to Herdr. The follower
#     needs no sudo, no root and no credential. Do this BEFORE the start so Herdr shows `working` the
#     moment the run begins. The single attach also launches the follower (unit agent-runtime-herdr-
#     follow-coder). Run as lukas (the Herdr user), e.g. from the user's own session:
MIRROR_STATUS=/run/agent-runtime/coder/mirror.status             # root writes it 0644 at start and exit
export AGENT_RUNTIME_HERDR_STATE=$HOME/.local/state/agent-runtime-herdr
agent-runtime-herdr attach coder "$T" "$REF" "$MIRROR_STATUS" --mirror

# 4. Deliver the credential and run — the direct root start. The token reaches the run ONLY this way:
#    `start --credential` copies it to the run's own tmpfs (/run/agent-runtime/coder/cred/token), binds
#    it read-only at /run/agent-runtime/credentials/token (mode 0400, the mapped agent uid), and
#    claude-coder-run exports it as CLAUDE_CODE_OAUTH_TOKEN for the claude process only — no host dir,
#    ~/.claude or /run/secrets is mounted. The PROMPT is the runner's argument (not the REF):
sudo agent-runtime-instance start coder --credential "$CRED" --wait -- "$RUN" "$PROMPT"

# 5. Watch progress with the instance tool (authoritative, root). Herdr also now reflects the run
#    via the step-3b mirror (working during, idle/blocked after); the instance tool is the truth:
sudo agent-runtime-instance status coder         # record runtimeUSec, memoryPeakBytes, uidBase; succeeded
sudo agent-runtime-instance logs coder           # the run's log (during or after)

# 6. Export (redacts the token from run.log; refuses an export whose outputs or source patch contain it):
sudo agent-runtime-instance export coder
B=$(sudo agent-runtime-instance status coder | jq -r .export.dir)   # this run's bundle; a rerun of `coder` gets a new one

# 7. Verify on acer, IN THIS SAME LOCKED SHELL — so $T/$CRED/$B are in scope and the lock is still held
#    (w12: do not run verify/leak in a shell that has exited the one where T/CRED were set). First record
#    the transfer digest over bundle.json AND every file it lists (for the lenovo re-run below):
sudo sh -c 'cd "$1" && sha256sum bundle.json $(jq -r ".files[].path" bundle.json)' _ "$B"   # record every value
sudo agent-runtime-verify --bundle "$B" --template "$T" --require-change

# 8. Destroy, then the leak checks — still this shell, so $CRED/$B are set; the export at $B survives destroy:
sudo agent-runtime-instance destroy coder        # removes the tmpfs credential copy
sudo grep -rlIFf "$CRED" /run/agent-runtime /var/lib/agent-runtime "$B" 2>/dev/null   # expect: no output
sudo journalctl -b -u 'agent-runtime*' | grep -cFf "$CRED"                            # expect: 0

# 8b. Detach the status mirror — AS LUKAS (the Herdr user, same AGENT_RUNTIME_HERDR_STATE as step 3b),
#     NOT root. `detach` stops the follower unit (agent-runtime-herdr-follow-coder) and closes the
#     mirror's workspace, so no `rt-coder (mirror)` agent or workspace is left listed in Herdr. Do this
#     after the leak checks and before the final preflight; a run that skips it leaves the mirror agent
#     listed at idle/blocked forever:
agent-runtime-herdr detach coder                 # stops the follower, closes the workspace
# teardown checks — nothing of the mirror remains:
herdr agent list | jq -e '[.result.agents[] | select(.name == "rt-coder")] | length == 0'   # expect: true
systemctl --user list-units --all 'agent-runtime-herdr-follow-coder.service' | grep -q . && echo LEFTOVER || echo "no follower unit"
agent-runtime-herdr status | grep -E '^coder\s' || true   # expect: coder ... torn_down

# 9. Preflight is clean again, then release the lock:
sudo agent-runtime-preflight --template "$T" --herdr-user lukas   # go again: nothing left
exit                                             # releases the heavy-work lock
```

**The task (`$PROMPT`).** A single behaviour-preserving, test-backed one-line edit to
`sammasak/rf-proto` at the pinned `inputs.rf-proto` rev `d878c58ebaca9c5281ef522b6fbd1761e122dfb6`
(flake.lock): **add `#[must_use]` to the public `varint` function in `src/lib.rs`** (at that rev it is
line 66, `pub fn varint(mut v: u64) -> Vec<u8>` — the fixture helper that encodes a base-128 varint
length prefix). It returns `Vec<u8>`, which is not already `#[must_use]`, and every existing caller
consumes the result, so the attribute adds no `unused_must_use` warning (and the crate sets no
`-D warnings`), keeping the build clean. The existing unit test **`decodes_multibyte_varint_length`**
(`src/lib.rs`, the `#[cfg(test)] mod tests`) covers it directly — it asserts `varint(200) == vec![0xc8,
0x01]` — and `decodes_two_short_frames` exercises it too; `cargo test --offline --locked` already runs
both, so the run's own `cargo test` step is the oracle (no new test to trust). The patch is one line,
nonempty, and reviewable by eye. rf-proto is a single zero-dependency crate, so it builds and tests
with no network.

**Herdr visibility — the status mirror (#169).** The credentialed run is still the direct root
`start --credential` above; it does **not** run inside a Herdr pane, and the token never reaches
Herdr. To make it *show* in Herdr with **no new privilege**, attach a **status mirror** (step 3b): as
the Herdr user, `agent-runtime-herdr attach coder "$T" "$REF" "$MIRROR_STATUS" --mirror`. This:

- creates a Herdr agent `rt-coder (mirror)` whose pane foreground is a **benign placeholder that only
  waits** — it starts nothing, and is *not* `agent-runtime-pane … -- "$RUN"` (which would run the
  instance) — and starts a follower;
- the follower runs as the **unprivileged Herdr user** and reads ONLY the **root-written,
  world-readable** `/run/agent-runtime/coder/mirror.status` (mode 0644). It never calls
  `agent-runtime-instance status` (which needs root), never `sudo`, and never the credential — the
  token lives at `/run/agent-runtime/coder/cred/token` (0400), a **different file**. The mirror carries
  only non-secret lifecycle state `{state, outcome, reason}`. The mirror's read path depends on
  `/run/agent-runtime/<id>/` being world-traversable; what protects the credential is `cred/` (0700)
  and `cred/token` (0400), so **never loosen `cred/`** to make anything else readable;
- `instance.sh` (root) writes that file at the run's state transitions — `starting` at launch, the
  recorded outcome at `record-exit` — and the follower maps it to Herdr: `starting`/`running` →
  **working** (during the run), `succeeded` → **idle** (Herdr shows it done), and
  `failed`/`oom-killed`/`timed-out` → **blocked** with the non-secret reason. So Herdr now reflects
  the **real** run (working during, idle or blocked after), not a fixed `idle`.

- **`deliver` to the mirror is refused.** `agent-runtime-herdr deliver coder …` dies 75
  (`runtime coder is a status mirror; it starts nothing — not delivering`) **before any Herdr call**:
  a mirror starts nothing, so a stray handoff can never trigger a second, credential-less run.
- **Never `deliver` to this instance** by any path, and do not `detach` mid-run — `detach` belongs in teardown (step 8b), where it stops the follower and closes the mirror's workspace so nothing is left listed.
- Threading `--credential` through the pane / the #172 pane launcher (now merged, `df4049d`) so a
  credentialed run can be *driven* through Herdr is a separate code change, **not done here** — do
  not improvise a token path around the pane. The mirror only *reflects* state; the run stays the
  direct root `start --credential`.

### Trusted-side verification

The verifier and the template manifest both live on **acer**. `agent-runtime-verify` is on acer's PATH
from the host closure (`modules/agent-runtime/host.nix` ships `tools.verify`, i.e. the `verify`
attribute of `modules/agent-runtime/runtime.nix`); it is **not** exposed as a flake package output —
`flake-modules/25-agent-runtime.nix` exports only `agent-runtime-{assign,materialize,export,reclaim,instance}`,
not `verify`, `preflight` or `pane`. So **lenovo cannot `nix build` the verifier** without first adding
it to that packages list (a one-line flake change, out of this offline slice). Two honest options:

**(a) Verify on acer, as root** — this is **step 7 of the locked shell above**, where `$T`/`$CRED`/`$B`
are already set and the lock is still held. If you instead verify in a separate acer-root session, first
re-derive the variables (they do not survive the run shell's `exit`):

```
# on acer (a fresh session): re-derive what the locked shell set, then verify:
T=/nix/var/nix/profiles/agent-runtime/templates/templates/claude-coder.json
B=/var/lib/agent-runtime/exports/coder.runs/latest     # the newest run of coder (#184); or the exact exports/coder.runs/<runId>
sudo sh -c 'cd "$1" && sha256sum bundle.json $(jq -r ".files[].path" bundle.json)' _ "$B"   # record every value
sudo agent-runtime-verify --bundle "$B" --template "$T" --require-change
# prints: {kind: "agent-runtime-verified", bundleSha256, sources: {rf-proto: {base, patchSha256, tree, changedPaths}}}
```

`agent-runtime-verify --bundle DIR --template MANIFEST --require-change` is the exact signature
(`modules/agent-runtime/runtime/verify.sh`); `$T` is the same claude-coder manifest path as above.

**(b) Re-run rf-proto's own tests on lenovo** (verification itself stays on acer per (a), unless you
make the flake change). The bundle is `0700 root`, so move it as root, re-check the recorded digest,
then apply the verified patch to a fresh checkout at the recorded base rev:

```
# on lenovo, PULL the root-only bundle from acer. Do not push from acer: acer cannot resolve `lenovo`
# and lenovo rejects acer's key; `ssh deploy@acer-swift` (the lenovo->acer deploy account, the direction
# that works) with `sudo tar` reads the 0700 export:
mkdir -p /tmp/coder-bundle
ssh deploy@acer-swift 'sudo tar -C /var/lib/agent-runtime/exports -c coder' | tar -C /tmp/coder-bundle -x
# re-check the digest of bundle.json AND every file it lists (not bundle.json alone, so a swapped
# file+bundle.json pair is caught); every line must equal what acer printed in step 7 / option (a):
( cd /tmp/coder-bundle/coder && sha256sum bundle.json $(jq -r '.files[].path' bundle.json) )
git clone https://github.com/sammasak/rf-proto /tmp/rf-proto-verify   # private repo; uses your git/gh credentials
git -C /tmp/rf-proto-verify checkout d878c58ebaca9c5281ef522b6fbd1761e122dfb6
git -C /tmp/rf-proto-verify apply /tmp/coder-bundle/coder/sources/rf-proto.patch
( cd /tmp/rf-proto-verify && cargo test --offline --locked )   # rf-proto's own test command; stays green
```

To promote the reviewed artifact, let `agent-runtime-promote` do the apply/commit onto that checkout
(it re-verifies first and records the commit sha), then push:

```
git -C /tmp/rf-proto-verify checkout d878c58ebaca9c5281ef522b6fbd1761e122dfb6   # back to the base rev, clean
agent-runtime-promote --bundle /tmp/coder-bundle/coder --template "$T" \
  --into /tmp/rf-proto-verify --branch coder/<issue>   # prints the promotion record; no push, no gh
git -C /tmp/rf-proto-verify push -u origin coder/<issue> && gh pr create ...   # the trusted host's gh
```

`d878c58ebaca9c5281ef522b6fbd1761e122dfb6` is the pinned `inputs.rf-proto` rev (flake.lock); `--locked`
keeps the committed `Cargo.lock` and the zero-dependency crate needs no network, so `--offline` holds.

`agent-runtime-verify` never runs the patch; it checks every file's sha256 against `bundle.json`, that
the patch applies at the recorded base narHash and reproduces the recorded tree, that the touched paths
match the record, that no path is outside the repo or under `.git`, and (with `--require-change`) that
the patch is nonempty.

### Leak checks after destroy

- `sudo agent-runtime-instance status` shows no instance; `ls /run/agent-runtime/` has no `coder/`,
  so the tmpfs `cred/token` copy is gone; `findmnt` shows no leftover instance mounts.
- Grep for the token **without ever putting it on a command line** — `grep -f FILE` reads the pattern
  *from the file*, so the token never reaches `argv`, `/proc/<pid>/cmdline` or the sudo log (unlike
  `grep -F "$(cat "$CRED")"`, which passes the token itself as an argument):

These are **step 8 of the locked shell** above, where `$CRED`/`$B` are set. If run in a separate
acer-root session, re-derive them first (they do not survive the run shell's `exit`):

```
# on acer: re-derive, then the leak checks (names-only -l, recursive -r, skip binaries -I,
# fixed-string -F, pattern read from the file -f so the token never reaches argv/cmdline/the sudo log):
CRED=/run/secrets/claude_oauth_token
B=/var/lib/agent-runtime/exports/coder.runs/latest     # the newest run of coder (#184); or the exact exports/coder.runs/<runId>
sudo grep -rlIFf "$CRED" /run/agent-runtime /var/lib/agent-runtime "$B" 2>/dev/null   # expect: no output
# the journal of every agent-runtime unit this boot, counting matches rather than printing them:
sudo journalctl -b -u 'agent-runtime*' | grep -cFf "$CRED"                            # expect: 0
```

  The export already refuses a bundle whose output files or source patch contain the token; these
  checks widen that to the run's tmpfs, the persistent state and the journal. An *encoded* copy defeats
  any literal grep; the human patch review before promotion is the backstop.

### Rollback

1. **Drain:** `sudo agent-runtime-instance status` shows nothing running; otherwise `cancel`, `export`
   and `destroy` the instance (`docs/agent-runtime-runbook.md`, Stop and tear down).
2. **Disable:** drop `"claude-coder"` from `eligibleTemplates` (back to `[ "rust-pilot" ]`) and remove
   the `templates.claude-coder.network.allow` line, then `just deploy-acer` (on msi also drop
   `sam.hostSecrets.enable`, then `just deploy-msi`). (Set `eligibleTemplates =
   [ ]` to disarm both templates.)
3. **Or roll back what deploy-rs activated:** `ssh deploy@acer-swift sudo nix-env -p
   /nix/var/nix/profiles/agent-runtime/templates --rollback` for the templates, and the deploy-rs
   `--rollback` / system-profile rollback for the host (`docs/agent-runtime-deploy.md`, Rollback).

## Status of #169's acceptance

- **Disposable VM evidence:** `packages.x86_64-linux.agent-runtime-coder-test`, model-free.
  - nspawn launch and cleanup, with the real binary, the skill and the source inside;
  - bounded resources;
  - fail-closed auth, from both the real binary and the runner;
  - a bounded run without egress that never leaks the key;
  - a nonempty patch verified against the pinned rev;
  - the verifier's refusals;
  - cancellation, and the host unaffected.
- **A real model turn producing a patch:** **not done**. It needs the owner's Claude Code subscription token (the SOPS `claude_oauth_token`, Authentication above) delivered per run and the egress allowlist, and it is a live run on a host. The VM's nonempty patch comes from a labelled model-free fixture edit, not from Claude.
- **Independent review and promotion of a real artifact, with SHA, digest and cost:** after that live run.
