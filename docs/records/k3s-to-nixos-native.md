# Moving the homelab from k3s to NixOS: decision record

Status: done. Decided (owner) 2026-11-15: no k3s at all. k3s, Flux and Cilium
were removed from every host in #442; the cluster no longer exists. Tracking
issue: nixos-config #299. The 2026-11-13 hybrid record (the edge and the
scale-to-zero workloads staying on k3s) is superseded:
`git show 77cfa81:docs/k3s-to-nixos-native.md`. The pre-removal inventory,
baseline and step tables are in git history at that commit and at
`git show 716fdf91^:docs/k3s-to-nixos-native.md`.

## Answer to the request

The request was a Kubernetes-like model that is native to NixOS, the right fit
without overengineering or hacks.

Nothing gives Kubernetes semantics (scheduling, rescheduling, service
discovery, scale to zero, admission) on plain NixOS without adding a scheduler
or a framework: Nomad, Clan and selfhostblocks are each one of those, and
nixpkgs' own modular services are not ready. With one general worker, the
scheduler buys least here. What NixOS gives natively is the other half of what
Flux and Kubernetes did: declared desired state per host, atomic activation,
generations to roll back to, supervised units with readiness and restart, and
secrets. So the fit is a composition, not a platform: every service is a plain
NixOS module on a named host, and the deployment tool stays deploy-rs.

## Decision

1. No k3s at all, reached in four steps (all landed):
   1. monitoring native on black-pi (#414, #419);
   2. Caddy on acer fronts every name and replaces Traefik; herman is a
      Nix-built static site; karta was dropped with k3s (#442, its name now
      404s, #463); zot retired (#420, #437);
   3. Authentik and Postgres native, behind Caddy `forward_auth` (#421);
   4. k3s, Flux, Cilium, kyverno, KEDA, MetalLB, cert-manager, external-dns
      and metrics-server removed (#422, #442).
2. Deployment stays deploy-rs from the one flake: `just deploy HOST`, owner
   approved, `magicRollback` and `autoRollback`, then the end-to-end check.
   No host upgrades itself (`system.autoUpgrade` is asserted off, #311).
3. No service framework. A service is one `homelab.<name>` module in
   `modules/homelab/` that wraps the upstream NixOS module, opens its port with
   `mkDualBackendFirewall`, and gets a `scripts/test-<name>.py` gate when it has behaviour to pin. A shared
   helper is written only when a third service repeats the same wiring.
4. Pod telemetry ended with the pods. Hosts ship their own journals through the
   journald collector; Prometheus, Alertmanager, Grafana and Loki run on
   black-pi, the OTLP intake on acer.
5. Nix store delivery into k3s was dropped with the cluster
   (`nix-native-delivery.md`).

Removed instead of migrated: styrka-web, system-one, monty-runner, kokoro,
whisper, workout and karta (#442).

## What replaced what

| Was | Now |
|---|---|
| Flux reconcile from Git | an explicit `just deploy HOST` after merge |
| Flux health checks and remediation | an `ExecStartPost` probe on the long-start units plus deploy-rs rollback |
| Flux SOPS decryption | sops-nix with per-host age keys |
| Traefik, cert-manager, external-dns | Caddy on acer with ACME; AdGuard on lenovo rewrites the names |
| Prometheus operator, kube-state-metrics, Alloy DaemonSet | native Prometheus, Alertmanager, Grafana, Loki on black-pi; journald collector per host |
| Flux notifications, k3s ntfy | `OnFailure=` to ntfy; ntfy native on lenovo |
| KEDA scale to zero | socket activation where it matters (open-webui) |
| admission policy, network policy | module assertions, systemd sandboxing, the host firewall |
| Kubernetes Services | static host address and port |

Given up for a moved service: rescheduling on node loss (placement is static),
horizontal scaling, per-pod network policy, ServiceMonitor discovery (a
declared scrape target replaces it).

## Why not another tool

| Option | Verdict | What would reopen it |
|---|---|---|
| comin (pull) | not now | hosts regularly missing deploys while asleep or unreachable; it has no automatic rollback or health check |
| devenv machines | not now | deploying existing flake hosts over a non-root login, and leaving experimental status (devenv #3242, #3226, #3342) |
| Colmena | no | no rollback |
| `system.autoUpgrade` as the pull path | no | no health gate |
| Clan, Nomad, selfhostblocks | no | a framework or scheduler to adopt whole |
| nixpkgs modular services | wait | upstream still in development (nixpkgs #428084) |
| GitHub Actions building closures | no | no runner reaches the LAN cache |

comin (pull) is not now: every host would evaluate the flake, including the
Pis, and it is pre-1.0. With several hosts down nothing reconciles
automatically; that is accepted (push, not pull).

Push fits because changes are few, approved by one person, and ordered across
hosts by hand.

## Conventions

- **Placement.** black-pi has a 29 GB SD card. A host whose journal would add
  more than Loki's daily intake gets a drop rule for its noisiest units first
  (#301). After a change there: MemAvailable stays at or above 600 MiB for
  24 h with no new OOM kill, and the root filesystem keeps at least 3 GB free
  over 72 h; otherwise roll back and reopen placement.
- **Rollout order.** One host at a time, least critical first: msi, black-pi,
  acer, lenovo. After each deploy: `systemctl is-system-running`, the
  generation link, and the service's user-visible check
  (`scripts/post-deploy-check.sh` does part of it): magicRollback's
  connectivity path is unrehearsed (#297).
- **Persistent state.** A fixed `/var/lib/<service>` on a named host, with the
  backup job declared in the same module.
- **Probe gotcha.** A failing `ExecStartPost` probe fails the whole host
  activation, so it checks only the service's own local ready endpoint, never
  a remote dependency.

## Operations

- **lenovo down.** deploy-rs pushes from lenovo and the deploy key is accepted
  from lenovo's address only. The fallback is `just switch` on the host
  itself. The remote form (`nixos-rebuild --target-host`) from another machine
  is unverified: workers trust only root and lenovo's signing key.
- **Several hosts down.** Each host's services are independent once
  activated; a host that was off is deployed when it returns.
- **Paging.** `cluster-watchdog.nix` (on lenovo, despite its name) is live: it
  checks black-pi's Prometheus and Alertmanager from another host, the paging
  floor when black-pi is down. `nixos-rebuild-trigger` is also live (ADR-024).
  Neither is a cluster leftover.
- **Paging when hosts fail.** lenovo down means no pages (ntfy is on lenovo;
  owner accepted, #399), and dashboards need client-side hosts entries
  (AdGuard is on lenovo). black-pi down pages only through cluster-watchdog on
  lenovo. acer down takes Authentik and so Grafana's login with it (OIDC only,
  no local fallback, grafana.nix); Alertmanager on black-pi still posts to
  lenovo's ntfy.

## Open

- Archive the homelab-gitops repository (owner). Deleting its PVC and other
  state stays on the owner's by-hand list (homelab-gitops #146). The claim list is at
  `git show 716fdf91^:docs/k3s-to-nixos-native.md` ("Removed or decided").
- Backups: Authentik's Postgres dump is pulled off-host to lenovo nightly
  (`authentik-offhost.nix`). open-webui and llm-gateway back up daily on the
  same disk only; Loki has none, accepted. A stateful service moves only with
  an off-host backup and a rehearsed restore, or the owner's acceptance in its
  issue.
- naked-pi takes the patched deploy-rs rollback at its next deploy (#474).

Vault ADR-001 (Flux) and ADR-005 (single k3s cluster) are superseded by this
record.
