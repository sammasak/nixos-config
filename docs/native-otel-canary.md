# Native OTLP canary

The Lenovo profile enables the native telemetry canary. Traces are
disabled, Codex logs are disabled, and Claude log forwarding is limited to
collector-sanitized tool-result events. The client configuration is gated on
the private OTLP receiver being reviewed and live; this change does not alter
subscriptions, API credentials, or inference routing.

Codex does not consume `OTEL_EXPORTER_OTLP_HEADERS`, so its metrics use a
localhost-only Nginx relay. The relay runs as a dynamic systemd user, reads the
SOPS credential through `LoadCredential`, and creates its configuration in a
0700 runtime directory. It accepts only `POST /v1/metrics`, forwards only the
OTLP content/encoding/accept headers plus its bearer credential over verified
TLS, and does not log request bodies or headers. Neither Codex nor its tool
subprocesses receive the receiver credential. The relay is enabled only with
`nativeOtel = true`.
The upstream certificate chain is verified to depth 3; Nginx's default depth
of 1 rejects the receiver's valid certificate chain.

Claude Code removes every `OTEL_*` variable, including the OTLP authorization
header, from the environment of Bash, hooks and stdio MCP subprocesses.

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
and a mock OTLP receiver, with a fake OTLP credential. It checks that:
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
that full host-build gate. Four `PASS:` lines indicate success; an assertion
failure blocks activation. The no-inference
test checks that composing Herdr and telemetry produces one Fish dispatch,
preserves arguments and exit status, and keeps telemetry settings local to
the function. It covers native telemetry enabled and disabled, missing
credentials, and hosts without Herdr. On Herdr hosts, the Fish telemetry
module supplies environment setup before the existing Herdr dispatch.

The composition cases substitute local recording stubs for the launcher/binaries.
A separate non-TTY case executes the real Herdr launcher with client stubs,
checking exactly-once execution and exit-status propagation. It does not
exercise interactive Herdr workspace/attach/fallback branches, launch a real
CLI, contact an inference endpoint, or read a live credential.
To reproduce the defect, keep these test scripts but restore the
parent revision of `modules/programs/cli/native-otel.nix` in a disposable
worktree: the duplicated dispatch must fail. Restore the fixed module and
rerun for green.

After the receiver and its host credential are approved and deployed, switch
to the NixOS generation containing the canary, open a fresh shell, and verify
the two CLI wrappers still invoke the expected binaries and that
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
`hosts/lenovo-21CB001PMX/variables.nix`, rebuild and switch to that generation,
then start a fresh shell. The standard Claude telemetry-disable setting is
restored, Codex's OTLP exporter stanza and telemetry preludes are removed, and
the host secret and relay are no longer installed. Verify no new requests
arrive at the receiver. Keep the prior NixOS generation available until
rollback is confirmed; do not revoke the shared receiver credential if another
approved client uses it.

Herdr's launcher functions remain installed on devTools hosts when telemetry
is disabled. After an approved activation or rollback, use a fresh shell and
`claude --version` / `codex --version` to check one version response per
invocation; this performs no inference. Never switch generations while an
existing agent session depends on the current shell environment. Activation
and rollback checks are operator steps, not actions performed by the fixture.
