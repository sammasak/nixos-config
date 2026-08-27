set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"

# ── Configuration Verification ────────────────────────────────────────

# Verify all host configurations build successfully
verify:
    bash scripts/verify-all-hosts.sh

# Run flake checks (includes all configurations)
check:
    nix flake check --all-systems --no-write-lock-file

# ── Metrics ───────────────────────────────────────────────────────────

# Measure eval time + static readability metrics, append to metrics/history.jsonl
bench:
    bash scripts/bench.sh bench

# Delta table between the last two metrics/history.jsonl entries
bench-diff:
    bash scripts/bench.sh diff

# Compare both toplevel drvPaths against the last bench entry; non-zero if they moved.
# Run this after a refactor that is meant to change nothing. Deliberately NOT part
# of `check` or `verify`: a change that legitimately moves the derivation should
# not fail the build gates.
parity:
    bash scripts/bench.sh parity

# ── Registry ──────────────────────────────────────────────────────────

# Login to Harbor
harbor-login:
    nix shell nixpkgs#skopeo -c skopeo login {{registry}}

# ── Image Supply Chain Security ───────────────────────────────────────

# Scan image for vulnerabilities before publishing
# Fails if any CRITICAL severity CVEs are found
scan IMAGE:
    nix shell nixpkgs#trivy -c trivy image --exit-code 1 --severity CRITICAL {{IMAGE}}

# Sign image with Cosign after publishing
# Requires SOPS-encrypted cosign.key in secrets/
sign IMAGE:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPKEY=$(mktemp)
    trap "rm -f $TMPKEY" EXIT
    cd secrets && sops --decrypt cosign.key > "$TMPKEY"
    nix shell nixpkgs#cosign -c cosign sign --key "$TMPKEY" --yes {{IMAGE}}

# Generate SBOM and attach as OCI attestation
sbom IMAGE:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPKEY=$(mktemp)
    TMPSBOM=$(mktemp --suffix=.spdx.json)
    trap "rm -f $TMPKEY $TMPSBOM" EXIT
    cd secrets && sops --decrypt cosign.key > "$TMPKEY"
    nix shell nixpkgs#syft -c syft {{IMAGE}} -o spdx-json > "$TMPSBOM"
    nix shell nixpkgs#cosign -c cosign attest --key "$TMPKEY" --predicate "$TMPSBOM" --type spdx --yes {{IMAGE}}
