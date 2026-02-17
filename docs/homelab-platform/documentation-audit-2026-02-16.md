# Documentation Audit: nixos-config vs homelab-gitops

> **Date:** 2026-02-16
>
> Cross-reference audit of nixos-config documentation against the actual homelab-gitops implementation. Identifies gaps, inaccuracies, and missing cross-repo documentation.

---

## Summary

The homelab-gitops repo has evolved significantly — workstation fleet, WorkspaceClaim CRD, Project Jarvis, SurrealDB, OpenTelemetry, voice/screen interaction layer — while nixos-config docs have not kept pace. The ownership split is architecturally clean, but nixos-config documentation is thin on its side of the boundary.

## Gap Table

| Topic | nixos-config | homelab-gitops | Gap |
|-------|-------------|----------------|-----|
| Workstation image pipeline | Vague (6-line section) | Comprehensive | Needs detail |
| WorkspaceClaim CRD | Not mentioned | Full CRD + controller | Should contextualize |
| K3s bootstrap | Not documented in README | References "see nixos-config" | Should document |
| Flux bootstrap | Not documented in README | References `homelab.flux` option | Should document |
| Project Jarvis | Not mentioned | 2000+ lines of design docs | Should acknowledge |
| SurrealDB / knowledge graph | Not mentioned | Research doc + deployment | Should acknowledge |
| DNS management (AdGuard) | Not documented | References nixos-config as owner | Should document |
| Cross-repo integration | Weak links | Well-referenced | Should strengthen |
| Cluster topology | Partially in overview.md | Current and detailed | Should update |

---

## Detailed Findings

### 1. Workstation Image Build Pipeline

**Current README (lines 134-158):** Lists `just build/publish/release` commands and related files but doesn't explain what happens under the hood.

**What homelab-gitops docs describe:**

```
1. nixos-generators builds qcow2 from hosts/workstation-template/
2. Justfile wraps qcow2 into OCI image (tar + jq + sha256sum, no Docker needed)
3. skopeo pushes to Harbor: registry.sammasak.dev/workstations/nixos-workstation:<tag>
4. KubeVirt pulls containerDisk from Harbor on VM start
5. Container runtime caches on node — subsequent starts are near-instant
```

**Action:** Expand README's "Workstation Image Builds" section to explain the full pipeline, prerequisites (skopeo, Harbor project), and post-publish workflow (how to update running workstations via homelab-gitops).

### 2. K3s & Flux Bootstrap

**Current README:** Does not mention k3s installation, Flux bootstrap, or the `homelab.k3s` / `homelab.flux` configuration options.

**What homelab-gitops references:**
- "k3s cluster running (see nixos-config bootstrap guide)"
- `homelab.flux.enable = true` with `gitUrl` and `gitPath` options

**Existing files:** `docs/homelab-platform/BOOTSTRAP.md`, `docs/homelab-platform/tech/k3s.md`, `docs/homelab-platform/tech/flux.md` exist but are not linked from README.

**Action:** Add a "K3s & Flux Bootstrap" section to README linking to the existing tech docs. Include quick-start snippets showing how to enable k3s and Flux on a host.

### 3. Workstation Fleet Management

**Current README:** No mention of how workstations are deployed or managed after image publishing.

**What homelab-gitops provides:**
- WorkspaceClaim CRD (`workstations.sammasak.dev/v1alpha1`)
- workspace-controller (reconciles claims into VM + PVC + Service)
- Instancetypes: standard (2 vCPU/4Gi), large (4/8), xlarge (8/16)
- SSH via MetalLB LoadBalancer + AdGuard DNS or Tailscale

**Action:** Add a "Workstation Fleet" section to README explaining the two-repo workflow: nixos-config builds images, homelab-gitops deploys them. Link to homelab-gitops workstation-fleet.md.

### 4. DNS Management (AdGuard)

**Current README:** Not documented.

**What homelab-gitops says:** "Records are managed as AdGuard rewrites in `../nixos-config/hosts/lenovo-21CB001PMX/configuration.nix`"

**Action:** Document where AdGuard rewrites are configured, the pattern for adding new workstation DNS entries, and the workflow (add rewrite in nixos-config, add WorkspaceClaim in homelab-gitops).

### 5. Project Jarvis

**Current README:** Not mentioned.

**What exists in homelab-gitops:**
- `docs/plans/2026-02-15-project-jarvis-design.md` — core orchestrator design
- `docs/plans/2026-02-16-jarvis-interaction-layer-design.md` — voice, screens, PWA
- `docs/plans/2026-02-15-surrealdb-knowledge-graph-research.md` — knowledge graph
- `apps/workstations/jarvis/` — deployment, service, ingress, monitoring (8 manifests)
- `apps/workstations/surrealdb/` — StatefulSet, service, credentials
- `apps/workstations/otel/` — OpenTelemetry collector

**Action:** Add a brief "Project Jarvis" section to README or overview.md acknowledging its existence, clarifying nixos-config's role (provides the k3s cluster only), and linking to the homelab-gitops design docs.

### 6. overview.md Accuracy

**homelab-gitops repo layout diagram (line 108-115):** Previously showed `jarvis/` under `infra/` — already fixed (removed in earlier cleanup). The actual location is `apps/workstations/jarvis/`.

**Cluster topology (line 56-83):** Accurate for the physical nodes. Does not mention workstation VMs or Jarvis as in-cluster services, but this may be intentionally scoped to host-level only.

**Repository layout (line 89-104):** Missing `docs/hosts/` and some module subdirectories, but is labeled as high-level so this is acceptable.

### 7. Cross-Repo Integration Model

**Current state:** README mentions homelab-gitops in the workstation section only. overview.md has a scope boundaries section with a mermaid diagram.

**What's missing:** A clear integration flow showing:

```
nixos-config                              homelab-gitops
    |                                          |
    +-- Host OS (NixOS modules)                +-- Flux-system
    +-- k3s server/agent                       +-- infra (MetalLB, ingress, certs, monitoring)
    +-- Flux bootstrap wiring                  +-- apps (harbor, lab, workstations)
    +-- Workstation image build                +-- Jarvis + SurrealDB + OTel
    +-- AdGuard DNS rewrites                   +-- WorkspaceClaim CRD + controller
    +-- SOPS age key distribution              +-- SOPS-encrypted secrets (in-cluster)
    |                                          |
    +-- Harbor: nixos-workstation:tag  -------->   containerDiskImage in WorkspaceClaim
    +-- Flux gitUrl/gitPath  ----------------->   clusters/homelab/ reconciliation
    +-- AdGuard rewrites  -------------------->   MetalLB LoadBalancer IPs
```

**Action:** Add this integration diagram to overview.md or a new cross-reference section in README.

---

## Recommended Actions (Priority Order)

### High Priority

1. **Expand workstation image build section** in README — explain full pipeline, prerequisites, post-publish workflow
2. **Add K3s & Flux quick-start** to README — link to existing tech docs (BOOTSTRAP.md, k3s.md, flux.md)
3. **Document AdGuard DNS management** — where to add rewrites, the per-workstation pattern

### Medium Priority

4. **Add workstation fleet workflow** to README — two-repo pattern, link to homelab-gitops docs
5. **Add cross-repo integration diagram** to overview.md
6. **Acknowledge Project Jarvis** — brief section in README or overview.md with links

### Low Priority

7. **Update cluster topology** in overview.md to mention workstation VMs as in-cluster services
8. **Review tech docs** (k3s.md, flux.md, workstation-images.md) for accuracy against current implementation
9. **Add homelab-gitops link** to README's "Related Docs" or "See Also" section
