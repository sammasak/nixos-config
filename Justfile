set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"

# nh selects by nixosConfigurations attribute, and lenovo's attribute is not its
# hostname, so the default cannot just be the hostname. `uname -n` rather than
# `hostname`: the latter arrives via nettools, which nothing here declares.
host := if `uname -n` == "lenovo-21CB001PMX" { "lenovo" } else { `uname -n` }

# ── Build & Deploy ────────────────────────────────────────────────────

# Build and activate this host's configuration
switch HOST=host:
    nh os switch . -H {{HOST}}

# Build this host's configuration without activating it
build HOST=host:
    nh os build . -H {{HOST}}

# Build and print the package diff against the running system
diff HOST=host:
    nh os build . -H {{HOST}} --diff always

# ── Configuration Verification ────────────────────────────────────────

# Verify all host configurations build successfully
verify:
    bash scripts/verify-all-hosts.sh

# Enforce the CLAUDE.md Comment Policy: density ceiling + forbidden shapes
lint-comments:
    bash scripts/nix-comment-lint.sh

# The .sh files under modules/ are shellchecked by their writeShellApplication
# derivation; these are the ones nothing else would ever check.
[doc("Shellcheck the repo's own scripts (the ones no derivation builds)")]
lint-shell:
    nix shell nixpkgs#shellcheck -c shellcheck scripts/*.sh

# Run flake checks (includes all configurations) and both lints
check: lint-comments lint-shell
    nix flake check --all-systems --no-write-lock-file

# ── Metrics ───────────────────────────────────────────────────────────

# Measure eval time + static readability metrics, append to metrics/history.jsonl
bench:
    bash scripts/bench.sh bench

# Delta table between the last two metrics/history.jsonl entries
bench-diff:
    bash scripts/bench.sh diff

# Run this after a refactor that is meant to change nothing. Deliberately NOT part
# of `check` or `verify`: a change that legitimately moves the derivation should
# not fail the build gates.
[doc("Compare both toplevel drvPaths against the last bench entry; non-zero if they moved")]
parity:
    bash scripts/bench.sh parity

# ── Registry ──────────────────────────────────────────────────────────

# Log in to the image registry (zot)
registry-login:
    nix shell nixpkgs#skopeo -c skopeo login {{registry}}

# ── Image Supply Chain Security ───────────────────────────────────────

[doc("Scan image for CRITICAL CVEs before publishing; non-zero if any are found")]
scan IMAGE:
    nix shell nixpkgs#trivy -c trivy image --exit-code 1 --severity CRITICAL {{IMAGE}}

[doc("Sign image with Cosign after publishing; needs SOPS-encrypted secrets/cosign.key")]
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
