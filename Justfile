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
publish-agent tag=`date +%Y%m%d`:
    bash scripts/publish-oci-image.sh "result-{{agent_host}}-kubevirt" "{{registry}}" "{{agent_project}}" "{{agent_image}}" "{{tag}}"

# Build + publish agent in one step
release-agent tag=`date +%Y%m%d`:
    just build-agent
    just publish-agent {{tag}}

# Show current agent image in Harbor
agent-info tag="latest":
    nix shell nixpkgs#skopeo -c skopeo inspect "docker://{{registry}}/{{agent_project}}/{{agent_image}}:{{tag}}"
