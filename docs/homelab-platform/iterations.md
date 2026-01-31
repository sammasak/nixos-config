# Homelab Platform - NixOS Iterations

> **Purpose:** NixOS-level configuration for homelab nodes.

---

## Iteration Overview

| Iteration | Goal | Status | Location |
|-----------|------|--------|----------|
| **0** | Foundation (NixOS + k3s + Flux) | 🔄 In Progress | This repo |
| **1** | Argo Workflows | ⬜ Not Started | [homelab-gitops](https://github.com/sammasak/homelab-gitops) |
| **2** | Observability | ⬜ Not Started | [homelab-gitops](https://github.com/sammasak/homelab-gitops) |
| **3** | Ephemeral Nodes | ⬜ Not Started | This repo |
| **4** | Hardening | ⬜ Not Started | [homelab-gitops](https://github.com/sammasak/homelab-gitops) |

**Status Legend:** ⬜ Not Started | 🔄 In Progress | ✅ Complete

---

## Repository Separation

The homelab platform spans two repositories:

| Repository | Concerns |
|------------|----------|
| **[nixos-config](https://github.com/sammasak/nixos-config)** | Node provisioning, k3s installation, Flux bootstrap, NixOS modules |
| **[homelab-gitops](https://github.com/sammasak/homelab-gitops)** | Kubernetes workloads, Flux manifests, platform services |

---

## NixOS Iterations (This Repo)

### [Iteration 0: Foundation](iterations/iteration-0-foundation.md)

**Goal:** Establish NixOS hosts with k3s and automated Flux bootstrap.

**Key Deliverables:**
- NixOS modules for k3s server/agent
- sops-nix for cluster token and Flux credentials
- Automated Flux bootstrap via systemd service

**Definition of Done:**
- [x] k3s cluster running on NixOS
- [x] kubectl access from local machine
- [x] Flux bootstrap automated via NixOS module
- [ ] All secrets managed via sops-nix

---

### [Iteration 3: Ephemeral Nodes](iterations/iteration-3-ephemeral-nodes.md)

**Goal:** Enable idle machines to join cluster temporarily.

**Key Deliverables:**
- NixOS module for ephemeral k3s agent
- Idle detection service
- Safe drain on user activity

**Definition of Done:**
- [ ] Laptop joins cluster when idle
- [ ] Clean drain when user returns
- [ ] No disruption to user's work

---

## Kubernetes Iterations (homelab-gitops)

See [homelab-gitops/docs/iterations.md](https://github.com/sammasak/homelab-gitops/blob/main/docs/iterations.md) for:

- **Iteration 1:** Argo Workflows (job execution)
- **Iteration 2:** Observability (metrics, logs, dashboards)
- **Iteration 4:** Hardening (security, backups)

---

## Quick Reference

### Deploy a node

```bash
# Add homelab-server or homelab-agent role to host variables
# Then:
sudo nixos-rebuild switch --flake .#hostname
```

### Enable Flux (automated bootstrap)

```nix
# In your host's configuration.nix
homelab.flux = {
  enable = true;
  gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
  gitPath = "clusters/homelab";
};
```

Flux bootstraps automatically when the system starts. No manual commands needed.

See [BOOTSTRAP.md](BOOTSTRAP.md) for full instructions.

---

## Technology Stack

Learn more about the technologies:

- [NixOS](tech/nixos.md) - Declarative OS configuration
- [k3s](tech/k3s.md) - Lightweight Kubernetes
- [SOPS](tech/sops.md) - Secret management
- [age](tech/age.md) - Modern encryption
- [FluxCD](tech/flux.md) - GitOps for Kubernetes
