# Homelab Platform - NixOS Layer

> **Purpose:** NixOS-level platform provisioning for the homelab cluster. This repo manages hosts, k3s bootstrap, secrets, and base security defaults.

---

## Scope Boundaries

This repo (`nixos-config`) owns:
- Host OS configuration (NixOS modules/roles)
- k3s server/agent lifecycle on hosts
- SSH/firewall/base hardening defaults
- SOPS/age secret decryption on hosts
- Flux bootstrap wiring

`homelab-gitops` owns:
- Kubernetes manifests/Helm releases
- In-cluster platform services (ingress, MetalLB, observability, cert-manager)
- Application workloads

```mermaid
flowchart LR
  subgraph NIXOS["nixos-config (host platform)"]
    A[Host roles\nserver/agent/desktop]
    B[k3s service lifecycle]
    C[sops-nix + age keys]
    D[flux bootstrap inputs]
  end

  subgraph GITOPS["homelab-gitops (cluster desired state)"]
    E[flux-system]
    F[infra]
    G[apps]
  end

  A --> B
  C --> B
  D --> E
  E --> F
  E --> G
```

---

## Current Cluster Topology (February 2026)

| Node | Function | Kubernetes Role | Labels | Notes |
|------|----------|-----------------|--------|-------|
| `lenovo-21cb001pmx` | control-plane host | `control-plane` | default + control-plane labels | kept relatively light |
| `acer-swift` | worker host | worker | `node-pool=workers` | primary workload node |

```mermaid
flowchart TB
  subgraph LAN["LAN 192.168.10.0/24"]
    Client[Client device]
    DNS[AdGuard Home\n192.168.10.154]
  end

  subgraph K3S["k3s cluster"]
    CP[lenovo-21cb001pmx\ncontrol-plane]
    WK[acer-swift\nnode-pool=workers]
    LB[MetalLB IP\n192.168.10.200]
    Ingress[ingress-nginx]
  end

  Client --> DNS
  DNS -->|*.sammasak.dev| LB
  LB --> Ingress
  Ingress --> WK
  CP -. api/control .-> WK
```

---

## Repository Layout

```text
nixos-config/
├── modules/
│   ├── core/                 # users, ssh, security baseline
│   ├── homelab/              # k3s, flux bootstrap, secrets
│   └── roles/                # host role composition
├── hosts/                    # per-host config + variables
└── docs/homelab-platform/
```

`homelab-gitops` cluster layout (high level):

```text
clusters/homelab/
├── flux-system/              # Flux controllers + bootstrap artifacts
├── infra/                    # cluster platform services
│   ├── cluster-policies/     # quotas, limits, priority classes
│   └── jarvis/               # shared platform dependencies
└── apps/                     # app workloads
```

---

## Operational Model

### Host management
- local: `sudo nixos-rebuild switch --flake .#<host>`
- remote: `nixos-rebuild switch --flake .#<host> --target-host <user@ip> --sudo --ask-sudo-password`

### Cluster management
- all workload/runtime changes happen via `homelab-gitops`
- apply flow: commit -> push -> `flux reconcile`

---

## Security Defaults (Host Side)

- SSH key-based auth
- root SSH login disabled
- firewall enabled with least-open-port posture
- secrets sourced from SOPS, not plaintext in repo

---

## Related Docs

- `docs/homelab-platform/BOOTSTRAP.md`
- `docs/homelab-platform/tech/k3s.md`
- `docs/homelab-platform/tech/flux.md`
- `https://github.com/sammasak/homelab-gitops`
