# Native OTLP canary

lenovo, acer-swift and msi-ms7758 enable native telemetry (`nativeOtel = true`). On acer and msi that is the relay, its secret, host Codex metrics and their environments' telemetry: the runtime-host role's `sam.claude.telemetry.enable = false` keeps host Claude sessions as they were (no export, no change to `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` or `permissions.defaultMode`), so only lenovo's host Claude sessions report. The secret is root-owned (evaluation fails otherwise); only the relay's `LoadCredential` reads it. Traces are
disabled, Codex logs are disabled, and Claude log forwarding is limited to
collector-sanitized tool-result events. The client configuration is gated on
the private OTLP receiver being reviewed and live; this change does not alter
subscriptions, API credentials, or inference routing.

Claude and Codex both export through a localhost-only Nginx relay on
`127.0.0.1:4319` (`modules/homelab/native-otel-relay.nix`, on every host with
`nativeOtel = true`, which also declares its `native_otlp_auth` secret;
`nixos:known-hosts-test` fails if that host is not a recipient of the file;
that test runs only in `nixos:qa` at pre-push, and `just deploy` skips checks
and only warns on an unpushed tree, so a non-recipient host deployed from a
local tree still fails at activation; an eval-time form is left to #293).
The relay runs as a dynamic systemd user, reads the
SOPS credential through `LoadCredential`, and creates its configuration in a
0700 runtime directory. It accepts only `POST /v1/metrics` and `POST /v1/logs`,
forwards only the OTLP content/encoding/accept headers plus its bearer
credential over verified TLS, and does not log request bodies or headers.
Neither client nor its tool subprocesses receive the receiver credential.
The upstream certificate chain is verified to depth 3; Nginx's default depth
of 1 rejects the receiver's valid certificate chain.

Any local process reaches `127.0.0.1:4319`, hostNetwork pods included, and
since this change it takes `/v1/logs` as well as `/v1/metrics`, signed with
the host's token. It forwards `X-Otel-Worker` as sent (an environment's egress
proxy overwrites it with the instance name) and rate-limits per value of that
header, 20 requests/s with a burst of 50 (then 429); requests without it share
one host bucket, so a flooding environment cannot starve the host's clients. A
local process can set the header itself, so a value is trustworthy only when
it came through an environment's proxy. The per-header limit therefore binds
only environments: a host process can vary `X-Otel-Worker` per request or
borrow a guest's name. On acer that includes hostNetwork pods: one can post
forged events under an environment's name (telemetry pollution, bounded by the
gateway's allowlist; the token stays out of its reach).

Claude's endpoint is the relay, not the receiver, because a headless
`claude -p` started by a script or by another session's Bash tool never passes
a shell wrapper, so a header exported there was missing and the receiver
rejected its telemetry. Claude now holds no credential at all. It sends
(`sam.claude.telemetry`, on by default with `nativeOtel`):
- metrics and log events over `http/protobuf`, with
  `host.name=<host>` and no account UUID;
- `session.id` on events (`OTEL_METRICS_INCLUDE_SESSION_ID=true`; the gateway
  strips it from metrics);
- `vcs.owner.name` and `vcs.repository.name` on both
  (`OTEL_METRICS_INCLUDE_REPOSITORY=true`);
- no prompts, tool content, tool details or raw API bodies (all four flags `0`).

Claude Code removes every `OTEL_*` variable from the environment of Bash,
hooks and stdio MCP subprocesses, so the settings also carry
`HARNESS_OTLP_ENDPOINT` (the relay) and `HARNESS_RESOURCE_ATTRIBUTES` (the
same attributes) for the skills hook `emit-work-ref.sh`, registered on `Stop`
(after `check-git-state.sh`) and `SessionStart` once the skills pin carries it,
and for `emit-skill-use.sh` on `PreToolUse` (`Skill`) and `UserPromptSubmit`:
Claude's own `skill_activated` event reports a user skill as `custom_skill`
while the content flags are off, so this hook sends the skill's name and
nothing else as a `skill_use` event.
`nixos:harness-telemetry-test` checks all of this. A developer environment
sends through its host's relay with
`sam.workers.instances.<name>.telemetry`
([nspawn-workers.md](nspawn-workers.md)), on by default on a
`nativeOtel` host; it also turns on the guest's Codex metrics exporter and
`codex` wrapper. Codex sends metrics only, which the gateway counts under
`host.name` (no worker). Codex has no credential path into a guest yet, so
that half is evaluated, not run.
A guest's Claude also has `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. With it
set, OTel events and metrics are still exported; only `DISABLE_TELEMETRY`-style
product analytics stop. Verified on a host session 2026-11-12 against a local
OTLP receiver; not yet verified inside a guest, which stays unverified until
one environment is enabled. A guest's telemetry leaves its
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` and `permissions.defaultMode` as they are
without it: both are set only where `sam.profile.nativeOtel` and the host's own `sam.claude.telemetry` are on, and the first is off in every guest.

`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is `"0"`. In Claude Code 2.1.300, `"1"`
forces every session into the default permission mode, so
`claude --dangerously-skip-permissions` could not work. Sessions still start in
default mode unless that flag is passed.

The cost of `"0"` applies to every session: subprocesses inherit other
credential-shaped variables (`AWS_*`, `*_TOKEN`, …) and run outside the
bubblewrap sandbox. `CLAUDE_CODE_OAUTH_TOKEN` is still withheld.

Validate this without a paid request:

```sh
python3 scripts/test-native-otel-subprocess-env.py <generated settings.json>
```

It runs the real client with the generated settings against a local mock API
and a mock OTLP receiver, with a fake OTLP credential in its environment. It checks that:
- `claude` starts in default mode;
- `claude --dangerously-skip-permissions` starts in `bypassPermissions`;
- Bash never sees the credential;
- exports stay authorized.

It never prints the fake credential.

## Smoke check

Before activation, from the repository root run:

```bash
nixpkgs_source=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
python3 scripts/test-native-otel-fish.py "$nixpkgs_source"
```

Use Fish, Python 3 and Nix from the project environment. This regression also
runs in `devenv tasks run nixos:qa`; reserve a shared verification slot before
that full host-build gate. Five `PASS:` lines indicate success; an assertion
failure blocks activation. The no-inference
test checks that composing Herdr and telemetry produces one Fish dispatch,
preserves arguments and exit status, and keeps telemetry settings local to
the function. It covers native telemetry enabled and disabled and hosts
without Herdr. The `codex` on PATH is a wrapper (hiPrio over `pkgs.codex`) that
exports `host.name` and cumulative metrics temporality, so `codex exec` from a
script or agent exports too; no Fish or Bash function sets `OTEL_`, and no OTLP header reaches either client.

The composition cases substitute local recording stubs for the launcher/binaries.
A separate non-TTY case executes the real Herdr launcher with client stubs,
checking exactly-once execution and exit-status propagation. It does not
exercise interactive Herdr workspace/attach/fallback branches, launch a real
CLI, contact an inference endpoint, or read a live credential.
To reproduce the defect, keep these test scripts but restore the
parent revision of `modules/programs/cli/native-otel.nix` in a disposable
worktree: its Fish prelude must fail. Restore the fixed module and
rerun for green.

After the receiver and its host credential are approved and deployed, switch
to the NixOS generation containing the canary, open a fresh shell, and verify
the CLIs still invoke the expected binaries and that
`native-otel-relay.service` is active. Run one bounded synthetic command with
each CLI, then confirm at the receiver that only
allowlisted metrics arrive with `host.name=lenovo-21cb001pmx`. Confirm
`/v1/traces` receives no data and that logs contain no prompt, tool content,
tool details, raw API bodies, or Codex events. Check for both successful
authorization and a rejected request using an invalid token; do not print or
copy the live token into test output.

Do not run a real inference solely to test telemetry. Gateway-observed token
usage remains separate from harness-observed metrics.

## Rollback

Set `nativeOtel = false` in
`sam.profile` in `hosts/lenovo-21CB001PMX/configuration.nix`, rebuild and switch to that generation,
then start a fresh shell. An assertion in `modules/core/system.nix`, evaluated on every host and
environment, fails the build of a configuration whose telemetry surfaces do not follow its switches: with
`nativeOtel = false` and `sam.claude.telemetry` at its default, no Claude telemetry variable (`OTEL_*`,
`HARNESS_*`, `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`), OTEL codex wrapper, relay
or receiver secret is left, and Claude's `DISABLE_TELEMETRY = "1"` is set. Codex's `[otel]` stanza is not
asserted (reading `config.toml` forces chromium); `codex/default.nix` writes it on the wrapper's rule. The
standard Claude telemetry-disable setting is restored, Codex's OTLP exporter stanza and telemetry preludes
are removed, and the host secret and relay are no longer installed. Verify no new requests
arrive at the receiver. Keep the prior NixOS generation available until
rollback is confirmed; do not revoke the shared receiver credential if another
approved client uses it.

Herdr's launcher functions remain installed on devTools hosts when telemetry
is disabled. After an approved activation or rollback, use a fresh shell and
`claude --version` / `codex --version` to check one version response per
invocation; this performs no inference. Never switch generations while an
existing agent session depends on the current shell environment. Activation
and rollback checks are operator steps, not actions performed by the fixture.
