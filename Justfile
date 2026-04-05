set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"
project := "workstations"
image := "nixos-workstation"
host := "workstation-template"

# ── Configuration Verification ────────────────────────────────────────

# Verify all physical host configurations build successfully
verify:
    bash scripts/verify-all-hosts.sh

# Verify all hosts including VM images
verify-all:
    bash scripts/verify-all-hosts.sh --all

# Run flake checks (includes all configurations)
check:
    nix flake check --all-systems --no-write-lock-file

# ── Workstation Image Management ──────────────────────────────────────

# Build NixOS qcow2 image
build host=host:
    bash scripts/build-workstation-image.sh {{host}}

# Publish qcow2 as OCI containerDisk to Harbor
publish tag=`date +%Y%m%d`:
    bash scripts/publish-oci-image.sh "result-{{host}}-kubevirt" "{{registry}}" "{{project}}" "{{image}}" "{{tag}}"

# Build + publish in one step
release tag=`date +%Y%m%d`:
    just build
    just publish {{tag}}

# Login to Harbor
harbor-login:
    nix shell nixpkgs#skopeo -c skopeo login {{registry}}

# Show current image in Harbor
image-info tag="latest":
    nix shell nixpkgs#skopeo -c skopeo inspect "docker://{{registry}}/{{project}}/{{image}}:{{tag}}"

# ── Claude Worker agent image ─────────────────────────────────────────

agent_project := "agents"
agent_image := "claude-worker"
agent_host := "claude-worker-template"

# Build Claude Worker agent qcow2 image
build-agent host=agent_host:
    bash scripts/build-workstation-image.sh {{host}}

# Publish agent qcow2 as OCI containerDisk to Harbor
# Scans the published image for CRITICAL vulnerabilities before completing
publish-agent tag=`date +%Y%m%d`:
    bash scripts/publish-oci-image.sh "result-{{agent_host}}-kubevirt" "{{registry}}" "{{agent_project}}" "{{agent_image}}" "{{tag}}"
    just scan {{registry}}/{{agent_project}}/{{agent_image}}:{{tag}}

# Build + publish agent in one step; signs image and attests SBOM after publish
release-agent tag=`date +%Y%m%d`:
    just build-agent
    just publish-agent {{tag}}
    just sign {{registry}}/{{agent_project}}/{{agent_image}}:{{tag}}
    just sbom {{registry}}/{{agent_project}}/{{agent_image}}:{{tag}}

# Show current agent image in Harbor
agent-info tag="latest":
    nix shell nixpkgs#skopeo -c skopeo inspect "docker://{{registry}}/{{agent_project}}/{{agent_image}}:{{tag}}"

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
