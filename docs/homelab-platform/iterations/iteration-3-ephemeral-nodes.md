# Platform Iteration 3: Ephemeral Nodes

> **Goal:** Enable idle machines (laptops, desktops) to join cluster temporarily.
>
> **Status:** ⬜ Not Started

---

## Overview

Ephemeral nodes allow underutilized machines to contribute compute capacity when idle. When the user returns, the node safely drains and leaves the cluster without disrupting workloads.

---

## Prerequisites

- [Iteration 0: Foundation](iteration-0-foundation.md) complete
- k3s server running
- Understanding of Kubernetes taints/tolerations

---

## Design Principles

1. **User First:** User activity always takes priority over cluster workloads
2. **Safe Drain:** Workloads must complete or relocate before node leaves
3. **No Data Loss:** Ephemeral nodes should not host persistent storage
4. **Opt-In Scheduling:** Only workloads that tolerate ephemeral nodes schedule there

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User's Machine                           │
│                                                             │
│  ┌─────────────────────┐    ┌─────────────────────────┐    │
│  │   Idle Detector     │───▶│   k3s Agent Service     │    │
│  │                     │    │                         │    │
│  │ • Mouse/keyboard    │    │ • Joins when idle       │    │
│  │ • Display state     │    │ • Drains on activity    │    │
│  │ • Audio activity    │    │ • Tainted ephemeral     │    │
│  └─────────────────────┘    └─────────────────────────┘    │
│            │                           │                    │
│            │  "user active"            │                    │
│            └───────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
                              │
                    joins/leaves cluster
                              │
┌─────────────────────────────────────────────────────────────┐
│                    k3s Cluster                              │
│                                                             │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐   │
│  │ Core Node     │  │ Ephemeral     │  │ Ephemeral     │   │
│  │               │  │ (laptop-1)    │  │ (desktop-1)   │   │
│  │ • Always on   │  │               │  │               │   │
│  │ • No taint    │  │ • Tainted     │  │ • Tainted     │   │
│  └───────────────┘  └───────────────┘  └───────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Work Units

### 3.1 Ephemeral Node NixOS Module

**Goal:** Create NixOS module for ephemeral k3s agent.

**Tasks:**
- [ ] Create `platform/modules/k3s/ephemeral.nix`
- [ ] Implement idle detection service
- [ ] Configure automatic join/leave
- [ ] Add taint on join

**NixOS Module:**

```nix
# platform/modules/k3s/ephemeral.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.k3s.ephemeral;
in
{
  options.homelab.k3s.ephemeral = {
    enable = lib.mkEnableOption "ephemeral k3s node";

    serverAddr = lib.mkOption {
      type = lib.types.str;
      description = "k3s server address";
    };

    clusterToken = lib.mkOption {
      type = lib.types.str;
      description = "Cluster token for authentication";
    };

    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;  # 5 minutes
      description = "Seconds of inactivity before joining cluster";
    };

    drainTimeout = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Seconds to wait for drain before force-leaving";
    };
  };

  config = lib.mkIf cfg.enable {
    # k3s agent configuration (disabled by default, controlled by idle service)
    services.k3s = {
      enable = true;
      role = "agent";
      serverAddr = cfg.serverAddr;
      token = cfg.clusterToken;
      extraFlags = toString [
        "--node-taint=node-role=ephemeral:NoSchedule"
        "--node-label=node-type=ephemeral"
      ];
    };

    # Don't auto-start k3s - let idle detector control it
    systemd.services.k3s.wantedBy = lib.mkForce [];

    # Idle detection and node lifecycle service
    systemd.services.ephemeral-node-manager = {
      description = "Ephemeral Node Lifecycle Manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.writeShellScript "ephemeral-manager" ''
          ${ephemeralManagerScript cfg}
        ''}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Required packages
    environment.systemPackages = with pkgs; [
      kubectl
      xprintidle  # For X11 idle detection
    ];
  };
}
```

**Idle Manager Script:**

```nix
# Continued from above - the script content
ephemeralManagerScript = cfg: ''
  #!/usr/bin/env bash
  set -euo pipefail

  IDLE_TIMEOUT=${toString cfg.idleTimeout}
  DRAIN_TIMEOUT=${toString cfg.drainTimeout}
  NODE_NAME=$(hostname)
  KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

  is_user_idle() {
    # Check X11 idle time (works for graphical sessions)
    if command -v xprintidle &>/dev/null && [ -n "''${DISPLAY:-}" ]; then
      idle_ms=$(xprintidle 2>/dev/null || echo 0)
      idle_sec=$((idle_ms / 1000))
      [ "$idle_sec" -ge "$IDLE_TIMEOUT" ]
      return $?
    fi

    # Fallback: check TTY activity
    idle_sec=$(stat -c %Y /dev/tty1 2>/dev/null | xargs -I{} expr $(date +%s) - {} || echo 999999)
    [ "$idle_sec" -ge "$IDLE_TIMEOUT" ]
  }

  is_node_joined() {
    systemctl is-active --quiet k3s
  }

  join_cluster() {
    echo "User idle for $IDLE_TIMEOUT seconds, joining cluster..."
    systemctl start k3s
    sleep 10  # Wait for node to register

    # Verify node is ready
    kubectl --kubeconfig=$KUBECONFIG wait --for=condition=Ready node/$NODE_NAME --timeout=60s
    echo "Node joined cluster"
  }

  leave_cluster() {
    echo "User activity detected, leaving cluster..."

    # Cordon node (prevent new pods)
    kubectl --kubeconfig=$KUBECONFIG cordon $NODE_NAME || true

    # Drain node (evict pods)
    kubectl --kubeconfig=$KUBECONFIG drain $NODE_NAME \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force \
      --grace-period=30 \
      --timeout=''${DRAIN_TIMEOUT}s || true

    # Stop k3s
    systemctl stop k3s
    echo "Node left cluster"
  }

  # Main loop
  while true; do
    if is_user_idle; then
      if ! is_node_joined; then
        join_cluster
      fi
    else
      if is_node_joined; then
        leave_cluster
      fi
    fi
    sleep 10
  done
''
```

---

### 3.2 Workload Tolerations

**Goal:** Configure which workloads can run on ephemeral nodes.

**Tasks:**
- [ ] Document toleration requirements
- [ ] Update Argo workflow templates
- [ ] Create example tolerating deployment

**Toleration for Ephemeral Nodes:**

```yaml
# Add this toleration to pods that can run on ephemeral nodes
spec:
  tolerations:
    - key: "node-role"
      operator: "Equal"
      value: "ephemeral"
      effect: "NoSchedule"
```

**Prefer Ephemeral Nodes (for batch jobs):**

```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: node-type
                operator: In
                values:
                  - ephemeral
  tolerations:
    - key: "node-role"
      operator: "Equal"
      value: "ephemeral"
      effect: "NoSchedule"
```

**Argo Workflow Template with Tolerations:**

```yaml
# platform/clusters/homelab/infra/argo-workflows/templates/ephemeral-job.yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: ephemeral-compatible-job
  namespace: argo
spec:
  entrypoint: main
  tolerations:
    - key: "node-role"
      operator: "Equal"
      value: "ephemeral"
      effect: "NoSchedule"
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: node-type
                operator: In
                values:
                  - ephemeral

  templates:
    - name: main
      container:
        image: alpine:latest
        command: [echo, "Running on potentially ephemeral node"]
```

---

### 3.3 Safe Drain Behavior

**Goal:** Ensure workloads complete or relocate safely.

**Tasks:**
- [ ] Configure PodDisruptionBudgets
- [ ] Set appropriate terminationGracePeriod
- [ ] Test drain under load
- [ ] Document drain behavior

**PodDisruptionBudget Example:**

```yaml
# Ensures at least one replica stays running during drain
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
  namespace: default
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

**Workflow Pod Settings:**

```yaml
# Argo Workflows should set appropriate grace periods
spec:
  templates:
    - name: long-running-job
      # Give pods time to complete on drain
      podSpecPatch: |
        terminationGracePeriodSeconds: 300
      container:
        image: my-job:latest
```

---

### 3.4 Monitoring and Alerting

**Goal:** Track ephemeral node status.

**Tasks:**
- [ ] Add Prometheus metrics for ephemeral nodes
- [ ] Create Grafana dashboard
- [ ] Configure alerts for drain issues

**Metrics to Track:**

```yaml
# platform/clusters/homelab/infra/observability/alerts/ephemeral.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ephemeral-alerts
  namespace: monitoring
data:
  rules.yaml: |
    groups:
      - name: ephemeral-nodes
        rules:
          - alert: EphemeralNodeDrainStuck
            expr: |
              kube_node_spec_unschedulable{node=~".*ephemeral.*"} == 1
              and on(node) time() - kube_node_created > 600
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Ephemeral node {{ $labels.node }} stuck in drain"

          - alert: EphemeralNodePodEvictionFailed
            expr: |
              increase(kube_pod_status_reason{reason="Evicted",node=~".*ephemeral.*"}[10m]) > 5
            labels:
              severity: warning
            annotations:
              summary: "Pods failing to evict from ephemeral node"
```

**Grafana Dashboard Queries:**

```promql
# Active ephemeral nodes
count(kube_node_labels{label_node_type="ephemeral"} == 1)

# Pods on ephemeral nodes
sum(kube_pod_info{node=~".*ephemeral.*"})

# Time since last drain
time() - max(kube_node_created{node=~".*ephemeral.*"}) by (node)
```

---

### 3.5 User Experience

**Goal:** Make ephemeral node behavior transparent to user.

**Tasks:**
- [ ] Add desktop notification on join/leave
- [ ] Create system tray indicator (optional)
- [ ] Document user-facing behavior

**Desktop Notification Script:**

```nix
# Add to ephemeral manager for notifications
notifyUser = pkgs.writeShellScript "notify-ephemeral" ''
  #!/usr/bin/env bash
  ACTION=$1
  if [ "$ACTION" = "join" ]; then
    ${pkgs.libnotify}/bin/notify-send \
      "Homelab Cluster" \
      "Your machine joined the cluster (idle mode)" \
      --icon=network-server
  else
    ${pkgs.libnotify}/bin/notify-send \
      "Homelab Cluster" \
      "Your machine left the cluster (user active)" \
      --icon=network-offline
  fi
''
```

---

## Definition of Done

- [ ] Laptop/desktop joins cluster when idle for N minutes
- [ ] Workloads with tolerations schedule to ephemeral nodes
- [ ] Node drains safely within timeout when user returns
- [ ] User's normal work is not impacted
- [ ] Monitoring shows ephemeral node status

---

## Verification Steps

```bash
# 1. Check node joins when idle
# Leave machine idle for configured timeout
kubectl get nodes
# Expected: Ephemeral node appears

# 2. Check taint applied
kubectl describe node <ephemeral-node> | grep Taint
# Expected: node-role=ephemeral:NoSchedule

# 3. Submit tolerating workload
argo submit -n argo --from workflowtemplate/ephemeral-compatible-job
kubectl get pods -o wide
# Expected: Pod scheduled on ephemeral node

# 4. Test drain
# Move mouse/press key
kubectl get nodes
# Expected: Node drains and disappears (within timeout)

# 5. Check workload relocated
kubectl get pods -o wide
# Expected: Pod rescheduled to core node or completed
```

---

## Troubleshooting

| Issue | Check | Solution |
|-------|-------|----------|
| Node won't join | `journalctl -u ephemeral-node-manager` | Check server address, token |
| Drain stuck | `kubectl get pods -o wide` | Check PDBs, increase timeout |
| Workloads won't schedule | `kubectl describe pod` | Verify tolerations |
| User impact | System monitor | Reduce CPU limits on workloads |

---

## Configuration Examples

**Full Host Configuration:**

```nix
# hosts/laptop/configuration.nix
{ config, ... }:
{
  imports = [
    ../../platform/modules/k3s/ephemeral.nix
  ];

  homelab.k3s.ephemeral = {
    enable = true;
    serverAddr = "https://192.168.1.10:6443";
    clusterToken = "my-cluster-token";  # Use sops-nix
    idleTimeout = 300;  # 5 minutes
    drainTimeout = 120;  # 2 minutes
  };
}
```

---

## Next Steps

After this iteration:
- [Iteration 4: Hardening](iteration-4-hardening.md) - Security and operational polish

