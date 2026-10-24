# Native OTLP canary

The Lenovo profile enables Claude Code and Codex metrics only. Traces are
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

Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is enabled so OTLP
authorization headers are not inherited by Bash, hooks, or stdio MCP
subprocesses. Validate this without a paid request using
`python3 scripts/test-native-otel-subprocess-env.py`; the test sends a fake
OTLP credential to a local mock API and checks the Bash tool result, never
printing the fake credential.

## Smoke check

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
restored, Codex's OTLP exporter stanza and wrapper functions are removed, and
the host secret and relay are no longer installed. Verify no new requests
arrive at the receiver. Keep the prior NixOS generation available until
rollback is confirmed; do not revoke the shared receiver credential if another
approved client uses it.
