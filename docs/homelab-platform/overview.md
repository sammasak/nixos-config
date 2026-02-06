# Homelab Platform - NixOS Configuration

> **Purpose:** NixOS modules for provisioning k3s cluster nodes with automated GitOps bootstrap.

---

## Overview

This directory contains documentation for the NixOS-level homelab configuration. The NixOS modules handle:

- k3s server/agent installation and configuration
- Automated Flux GitOps bootstrap
- Cluster token and credentials management via sops-nix
- Firewall and networking setup
- Ephemeral node support (join when idle)

For Kubernetes workloads and GitOps configuration, see [homelab-gitops](https://github.com/sammasak/homelab-gitops).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     nixos-config (this repo)                         │
│                                                                      │
│  modules/homelab/                                                    │
│  ├── k3s/               # Kubernetes cluster                         │
│  │   ├── default.nix    # Common k3s configuration                  │
│  │   ├── server.nix     # Control plane settings                    │
│  │   └── agent.nix      # Worker node settings                      │
│  ├── sops.nix           # Secret decryption (token, flux, cloudflare)│
│  ├── flux.nix           # Automated Flux bootstrap                  │
│  ├── adguardhome.nix    # DNS server with DoT/DoH                   │
│  └── acme.nix           # Let's Encrypt certificates                │
│                                                                      │
│  modules/roles/                                                      │
│  ├── homelab-server.nix # Role for control plane nodes              │
│  └── homelab-agent.nix  # Role for worker nodes                     │
└───────────────────────┬─────────────────────────────────────────────┘
                        │
                        │ Flux automatically syncs ↓
                        │
┌───────────────────────▼─────────────────────────────────────────────┐
│                     homelab-gitops (separate repo)                   │
│                                                                      │
│  clusters/homelab/                                                   │
│  ├── flux-system/       # GitOps controller                         │
│  ├── infra/             # Platform services                         │
│  │   ├── metallb        # LoadBalancer (192.168.10.200-210)         │
│  │   ├── ingress-nginx  # Ingress controller                        │
│  │   ├── cert-manager   # TLS certificates for K8s                  │
│  │   └── observability  # Prometheus/Grafana stack                  │
│  └── apps/              # Application workloads                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Network Flow

```
Internet/LAN
     │
     ▼
┌────────────────────────────────────────────────────────┐
│ AdGuard Home (192.168.10.154)                          │
│ ├── DNS:53      - Plain DNS                            │
│ ├── DoT:853     - DNS-over-TLS (Android Private DNS)   │
│ └── DoH:443     - DNS-over-HTTPS                       │
│     Certificate: Let's Encrypt (dns.sammasak.dev)      │
└────────────────────────────────────────────────────────┘
     │
     │ *.sammasak.dev → 192.168.10.200 (MetalLB)
     ▼
┌────────────────────────────────────────────────────────┐
│ ingress-nginx (192.168.10.200 via MetalLB)             │
│ └── TLS terminated by cert-manager certificates        │
│     ├── grafana.sammasak.dev → Grafana                 │
│     └── hello.sammasak.dev   → Hello app               │
└────────────────────────────────────────────────────────┘
```

---

## NixOS Modules

### `homelab.k3s`

Main k3s configuration module.

```nix
homelab.k3s = {
  enable = true;
  role = "server";  # or "agent"
  serverAddr = "https://192.168.1.10:6443";  # Required for agents
  clusterName = "homelab";
  flannel.backend = "host-gw";
  disableComponents = [ "traefik" "servicelb" ];
};
```

### `homelab.secrets`

SOPS-based secrets management.

```nix
homelab.secrets = {
  enable = true;
  sopsFile = ../../secrets/homelab/k3s.yaml;
  cloudflareSecretsFile = ../../secrets/homelab/cloudflare.yaml;
};
```

### `homelab.flux`

Automated Flux GitOps bootstrap.

```nix
homelab.flux = {
  enable = true;
  gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
  gitBranch = "main";
  gitPath = "clusters/homelab";
};
```

### `homelab.dns`

AdGuard Home DNS server with encrypted DNS (DoT/DoH).

```nix
homelab.dns = {
  enable = true;
  tls = {
    enable = true;
    domain = "dns.sammasak.dev";
    dohPort = 443;
  };
  rewrites = [
    { domain = "*.sammasak.dev"; answer = "192.168.10.200"; }
    { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }
  ];
};
```

### `homelab.acme`

ACME certificate management for DNS-over-TLS/HTTPS.

```nix
homelab.acme = {
  enable = true;
  email = "admin@sammasak.dev";
  dnsDomain = "dns.sammasak.dev";
};
```

Uses Cloudflare DNS-01 validation (no public exposure required).

When enabled, a systemd service automatically:
1. Waits for k3s to be ready
2. Creates the `flux-system` namespace
3. Creates Kubernetes secrets from sops-decrypted credentials
4. Runs `flux bootstrap git` if not already bootstrapped

---

## Roles

### `homelab-server`

For control plane nodes. Includes:
- k3s server with flannel networking
- Firewall rules for API server (6443)
- kubectl, helm, k9s, fluxcd packages
- Flux bootstrap module

### `homelab-agent`

For worker nodes. Includes:
- k3s agent configuration
- Connection to server via `serverAddr`

---

## Quick Start

1. **Add role to host variables:**
   ```nix
   roles = [ "base" "homelab-server" ];
   ```

2. **Set up secrets:**
   ```bash
   # Generate age key
   age-keygen -o ~/.config/sops/age/keys.txt

   # Create and encrypt secrets (cluster token, flux deploy key, flux age key)
   sops secrets/homelab/k3s.yaml
   ```

3. **Enable Flux in your host configuration:**
   ```nix
   homelab.flux = {
     enable = true;
     gitUrl = "ssh://git@github.com/youruser/homelab-gitops";
   };
   ```

4. **Deploy:**
   ```bash
   sudo nixos-rebuild switch --flake .#hostname
   ```

Flux bootstraps automatically. No manual `flux bootstrap` command needed.

See [BOOTSTRAP.md](BOOTSTRAP.md) for detailed instructions.

---

## Technology Stack

Learn more about the technologies used:

- [NixOS](tech/nixos.md) - Declarative OS configuration
- [k3s](tech/k3s.md) - Lightweight Kubernetes distribution
- [SOPS](tech/sops.md) - Secret management for GitOps
- [age](tech/age.md) - Modern encryption
- [FluxCD](tech/flux.md) - GitOps for Kubernetes

---

## Related Documentation

- [BOOTSTRAP.md](BOOTSTRAP.md) - Full bootstrap guide
- [iterations.md](iterations.md) - Implementation roadmap
- [homelab-gitops](https://github.com/sammasak/homelab-gitops) - Kubernetes workloads
