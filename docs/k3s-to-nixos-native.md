# Moving the homelab from k3s to NixOS: decision record and inventory

Status: decided (owner) 2026-11-15: no k3s at all, in four steps. Deploying
to a host, adding a secret, changing DNS and deleting state each need the
owner's approval; every step below names its gate.

Evidence: read-only audits of homelab-gitops at main 32b7c88 (what Flux runs),
nixos-config at main 9342c37, the live cluster (kubectl, Loki, and Prometheus
queried from black-pi), and a research pass on deployment tooling checked
against upstream repositories on 2026-11-13; updated against homelab-gitops
5c44dea and nixos-config 77cfa81 on 2026-11-15. Tracking issue: nixos-config
#299.

The 2026-11-13 hybrid record: `git show 77cfa81:docs/k3s-to-nixos-native.md`.

## Answer to the request

The request was a Kubernetes-like model that is native to NixOS, the right fit
without overengineering or hacks.

Nothing gives Kubernetes semantics (scheduling, rescheduling, service
discovery, scale to zero, admission) on plain NixOS without adding a scheduler
or a framework: Nomad, Clan and selfhostblocks are each one of those, and
nixpkgs' own modular services are not ready. With one general worker, the
scheduler is also the part that buys least here. What NixOS does give natively
is the other half of what Flux and Kubernetes do today: declared desired state
per host, atomic activation, generations to roll back to, supervised units with
readiness and restart, and secrets. So the fit is a composition, not a
platform:

- every service becomes a plain NixOS module on a named host;
- the deployment tool stays the one already in use.

What is lost for a moved service is listed under "Given up". devenv machines
and comin are the two tools worth reopening, each under a stated condition
below.

## Decision

1. **No k3s at all** (owner, 2026-11-15). This replaces the 2026-11-13
   hybrid decision, under which the edge and the scale-to-zero workloads
   stayed on k3s. The end state is reached in four steps (see "Order of
   work"):
   1. monitoring native on black-pi (#414, PR #419, homelab-gitops #271);
   2. Caddy on acer fronts everything and replaces Traefik; herman and karta
      become Nix-built static sites; zot retires (#420);
   3. Authentik and Postgres go native, behind Caddy `forward_auth` (#421);
   4. k3s, Flux, Cilium, kyverno, KEDA, MetalLB, cert-manager, external-dns
      and metrics-server are removed (#422).

   DNS needs no new mechanism: AdGuard on lenovo already rewrites
   `*.sammasak.dev` and `sammasak.dev` to Traefik's address
   (`hosts/lenovo-21CB001PMX/configuration.nix:131-143`). Step 2 repoints
   that rewrite to acer; step 4 only removes external-dns. The one possible
   new record is an optional public wildcard at Cloudflare.

   Removed instead of migrated: styrka-web, system-one, monty-runner, kokoro
   and whisper (homelab-gitops #269). Already moved to acer: the llm-gateway
   (homelab-gitops #265) and open-webui (#262). Deleting a PVC or other
   state stays on the owner's by-hand list (homelab-gitops #146).
2. **Deployment stays deploy-rs from the existing flake.** No new tool now.
   While a moved service still has clients or routes in the cluster, its
   migration is a two-repository change (see "Two repositories"); after
   step 4 there is one repository.
3. **No service framework.** A moved service is one `homelab.<name>` module in
   `modules/homelab/` that wraps the upstream NixOS module, opens its port with
   `mkDualBackendFirewall`, and has one `scripts/test-<name>.py` gate reading
   the shared probe evaluation. A shared helper is written only when a third
   service repeats the same wiring.
4. **Pod telemetry ends with the pods (step 1).** Pod logs and Kubernetes
   object metrics were collected by the Alloy DaemonSet and the operator
   stack; homelab-gitops #271 removes both. Hosts get their own journald
   collector, as a host service that covers msi too (#301 on msi; #330 for
   the other hosts, any time before step 4). The cost is one Alloy process
   per host, which is measured (see Placement).
5. **Nix store delivery into k3s is dropped.** With no cluster, homelab-gitops
   #146's choice between OCI, NixOS services and the store-delivery pilot
   (`docs/records/nix-native-delivery.md`) resolves to NixOS services; the
   pilot and its E0 measurement are dropped. #146 keeps the owner's by-hand
   list of claims and state to delete.

Vault ADR-001 (Flux) and ADR-005 (single k3s cluster) hold until step 4 and
are superseded by it.

## Baseline observed 2026-11-13

| Fact | Value |
|---|---|
| Nodes | lenovo (control plane, tainted, 46% memory used), acer-swift (only general worker, 31% used, 7G of it reserved for worker environments), msi-ms7758 (intermittent, opt-in), black-pi (arm64, opt-in, 75% used, 91% requested, 29 GB SD card). naked-pi is not a cluster node |
| Pods | all Running or Completed |
| Flux | 7 of 8 Kustomizations and 13 of 14 HelmReleases ready; the kyverno upgrade to chart 3.10.0 fails on five legacy policy resources |
| Prometheus | 52 scrape targets, all up; 164 alert rules; 214k head series; retention 2 days (captured from black-pi after the live report, which could not reach it) |
| Firing alerts | ContainerOOMKilled, CPUThrottlingHigh, KubeJobFailed (6 old backup Jobs), LokiNamespaceSilent (keda, llm), Watchdog |
| Loki | retention 72 h, 30 days for two agent telemetry streams; no pod logs from msi (the DaemonSet does not run there); no journald logs from any host |
| Where telemetry runs | Prometheus, Alertmanager, its ntfy bridge, Grafana, Loki, the operator and kube-state-metrics on black-pi (about 1.6 of the namespace's 2.1 GiB); the agent telemetry intake (alloy-otlp) on acer |
| Where the edge runs | Traefik, Authentik, the KEDA interceptors, cert-manager and zot all on acer |
| Paging | Alertmanager, bridge, ntfy pod in k3s on lenovo (`ntfy.sammasak.dev`, with an auth file); separately a native ntfy on lenovo port 2586 (LAN, plain HTTP, open read-write) used by the cluster watchdog |
| Storage | every volume is node-local `local-path`; only the two Postgres databases have backups |
| CI | none in either repository; gates are local hooks |

Ingress requests over the three days Loki retains: otlp 17445, ntfy 19,
registry 16, herman 3, every other public host 0. Three days without requests
is not evidence that a service is unused: the window is short and callers
inside the cluster do not pass through Traefik.

## What survives which outage

On 2026-11-13, from the placement above:

| Outage | Metrics | Logs | Dashboards | Paging |
|---|---|---|---|---|
| acer down | collected (black-pi) | collected, minus acer | unreachable: Traefik, Authentik and the interceptor are on acer | alerts reach the k3s ntfy; the public name is down with Traefik |
| lenovo down | collected until pods need the API | collected | only with client-side hosts entries for the Grafana and Authentik names: LAN DNS is AdGuard on lenovo and the routes are host-based | none: both ntfy instances are on lenovo |
| black-pi down | none | none | none | only the cluster watchdog on lenovo |
| k3s or Cilium broken, hosts up | none | none | none | only the cluster watchdog |

End state, after step 4: the stores on black-pi, the edge and Authentik on
acer, AdGuard and ntfy on lenovo. The cluster row no longer exists.

| Outage | Metrics | Logs | Dashboards | Paging |
|---|---|---|---|---|
| acer down | collected (black-pi), minus acer | collected, minus acer | Grafana on black-pi's LAN port with its local login (Caddy and Authentik are on acer) | Alertmanager on black-pi posts to lenovo's ntfy |
| lenovo down | collected | collected | through Caddy, with client-side hosts entries (AdGuard is on lenovo) | none: ntfy is on lenovo; accepted by the owner, "Not now" (#399) |
| black-pi down | none | none | none | the host-side replacement for the cluster watchdog, a step 4 prerequisite (#422) |

## Deployment workflow

### What is used

"Present" means it exists in nixos-config today; "to build" means the first
migration adds it.

| Need | Mechanism | State |
|---|---|---|
| Desired state per host | `nixosConfigurations.<host>` in one flake; a service is enabled per host in that host's `configuration.nix` | present |
| Reproducible builds | flake lock; x86 hosts substitute from the signed harmonia caches, the Pis build their own closures | present |
| Quality gates | pre-push `nixos:qa` on the pushed commit (flake check plus the Python gates), run off lenovo; one `scripts/test-<name>.py` per new module | present |
| Trigger and approval | merge to main, then an explicit `just deploy HOST` that the owner approves; no host upgrades itself (`system.autoUpgrade` is asserted off on every host since #311) | present |
| Rollout order | one host at a time, least critical first: msi, black-pi, acer, lenovo | convention |
| Activation safety | deploy-rs `magicRollback`: a host that cannot be reached after activation reverts | present |
| Service health | `services.alloy` and most upstream units are `Type=simple`, so each module adds an `ExecStartPost` probe of the service's own local ready endpoint with a start timeout, the upstream restart policy with a slower `RestartSec` and a start limit, and `OnFailure=` to ntfy. A unit that fails its probe fails the activation and so the whole host deploy; the probe therefore never tests anything remote (a collector must not fail a deploy because Loki is away) | present (#301) |
| Rollback on a failed unit | deploy-rs `autoRollback` | present on x86 (rehearsed on msi, #324); the Pis are still exposed, see gap 1 |
| End-to-end check | after every deploy: `systemctl is-system-running`, the generation link, and the service's user-visible check (a log line queryable in Loki, a test page arriving on the phone) | a checklist in each issue |
| Secrets | sops-nix with per-host age keys; a new secret file and its creation rule are owner steps, needed in steps 2 and 3 | present |
| Persistent state | a fixed directory under `/var/lib/<service>` on a named host, with a backup job declared in the same module | to build, see gap 3 |
| Service discovery | static: one host address and port, set once in each repository | present |
| Ingress and TLS | Traefik in k3s keeps the names and certificates until step 2, when Caddy on acer takes them over | Caddy in step 2 |
| Observability of the moved service | its journal through the host collector; its scrape target and alert rule in nixos-config after step 1 | step 1 |

### Two repositories

While Traefik and the clients of a moved service live in k3s, a migration
touches both repositories. Order: (1) nixos-config adds the module and a
deploy brings the service up next to the old one; (2) homelab-gitops
repoints clients and routes through Flux; (3) after an observation period,
homelab-gitops removes the old workload. Rollback runs the other way: revert
the gitops change first, then disable the module. The removal (3) is the only one that
cannot be undone by a revert when it deletes a volume, so it is always a
separate owner gate.

Reaching a host service from the cluster (selectorless Services, the R1
source check, the Cilium interface trust) is settled in #414 and its
homelab-gitops half #271.

### Why not another tool

| Option | Verdict | Reason, and what would reopen it |
|---|---|---|
| comin (pull, closest to Flux) | not now | no automatic rollback or health check; every host evaluates the flake, including the Pis; pre-1.0. Reopen if hosts regularly miss deploys because they were asleep or unreachable |
| devenv machines | not now | exists since devenv 2.4.0 with a target-side watchdog and a health check, the best safety model of the push tools. Experimental; needs root SSH where this fleet forbids root login (devenv #3242); takes modules, not the existing flake hosts (#3226); the target cannot substitute from harmonia (#3342); requires a disko input; one shell health check per machine. Reopen when it deploys existing flake hosts over a non-root login and leaves experimental status |
| Colmena | no | no rollback; nothing deploy-rs lacks that is needed here |
| `system.autoUpgrade` as the pull path | no | no health gate; acer's former use was a gap, not a model |
| lenovo's `nixos-rebuild-trigger` | keep until step 4 (#422), do not generalise | it rebuilds lenovo at a pinned commit with a health gate on request from the cluster. Extending it to other hosts would be writing a deploy controller |
| Clan, Nomad, selfhostblocks | no | a framework or a scheduler to adopt whole |
| nixpkgs modular services | wait | upstream but still in development (nixpkgs #428084) |
| GitHub Actions building closures | no | no runner reaches the LAN cache, and Actions use is kept minimal on purpose |

Push or pull: push fits because changes are few, approved by one person, and
ordered across hosts by hand. Pull would add convergence for sleeping hosts
(msi), which a deploy inside its power window already covers.

### Flux features and what replaces them

| Flux gives | After a service moves | Matters here |
|---|---|---|
| Reconcile from Git every few minutes | an explicit deploy after merge | low: changes are few and owner-approved |
| Drift correction | Nix-managed files cannot drift and a switch re-asserts them; data under `/var` can | low |
| `dependsOn` | systemd ordering on one host; deploy order across hosts | low: dependent services share a host |
| Health checks with timeout | readiness probe plus deploy-rs confirmation | yes: to build per service |
| Automatic remediation | rollback on failed activation | yes on x86, rehearsed; Pis pending, gap 1 |
| SOPS decryption | sops-nix | direct |
| Notifications | none configured in Flux today; `OnFailure=` to ntfy | same or better |

### Given up for a moved service

Rescheduling on node loss (placement is static), horizontal scaling, admission
policy (replaced by module assertions and systemd sandboxing), per-pod network
policy (replaced by the host firewall, which is coarser), ServiceMonitor
discovery (replaced by a declared scrape target), scale to zero through KEDA
(replaced by socket activation where it matters, as open-webui does).

### Operations

- **lenovo down.** deploy-rs pushes from lenovo and the deploy key is accepted
  from lenovo's address only. The fallback is `just switch` on the host
  itself, from a checkout there. The remote form (`nixos-rebuild
  --target-host`) from another machine is unverified: workers trust only root
  and lenovo's signing key, so a closure built elsewhere may be refused.
- **Several hosts down.** Each host's services are independent of the
  deploying host once activated; a host that was off is deployed when it
  returns. Nothing reconciles it automatically, which is accepted.
- **Scale.** Five hosts, with one or two more plausible. Nothing here changes
  with that count.

### Gaps to close, in order

1. **deploy-rs rollback under a failing unit.** Closed for x86 by #324:
   upstream issue serokell/deploy-rs #411 (a failed activation left the
   target on the failed generation while the client reported a rollback) was
   reproduced on msi, and the flake now carries the upstream fix (PR #412) as
   a patch on the pin; the same rehearsal then restored the previous
   generation. The Pis still use the unpatched cached binary until a patched
   aarch64 build is evidenced (#406), and the connectivity rollback is
   unexercised, so every deploy still ends with the end-to-end check above
   (#297).
2. **acer upgraded itself from main.** Closed by #300: acer's
   `system.autoUpgrade` is off, and since #311 every host asserts it.
3. **Backups.** No tooling exists beyond Postgres dumps and a local k3s
   datastore snapshot. A stateful service does not move until its module
   declares an off-host backup with a rehearsed restore, or the owner accepts
   in its issue that the data has none. Loki is the second case: it has no
   backup, and step 1 moves it with that posture unchanged. Authentik's
   Postgres (step 3) is the first case.
4. **Hard-coded cluster addresses.** Closed: nixos-config no longer
   hard-codes the Loki (10.43.92.124) or llm-gateway (10.43.0.80) ClusterIPs;
   what remains is the service CIDR in `modules/homelab/k3s/server.nix`, which
   goes in step 4.

## Inventory and classification

Risk is the cost of getting the move wrong. Every deletion and deploy is an
owner gate.

### Removed or decided

- The orphan `monitoring-tempo` and `monitoring-prometheus-pushgateway`
  releases, the six failed `postgres-backup-offnode` Jobs and
  `archive/learn/` in homelab-gitops: removed under the 2026-11-13
  delegation (homelab-gitops #157, closed).
- The old claims `prometheus-...-db-...-0` (8Gi) and
  `alertmanager-...-db-...-0` (1Gi) on acer and PV `pvc-68839200` (old Loki,
  Retain): mounted by nothing; deleting them is on the #146 by-hand list.
- external-dns: it only acts on objects carrying the
  `external-dns.alpha.kubernetes.io/hostname` annotation, none does, and it
  manages no record. Removed in step 4; AdGuard's existing rewrite covers it.
- qdrant: the 2026-11-13 decline was reversed; removed by homelab-gitops #259
  (unused since vault-reader). Its claim is kept, on the by-hand list.
- styrka-web, system-one, monty-runner, kokoro, whisper (homelab-gitops #269)
  and workout (homelab-gitops #175): removed, not migrated.

### Placed

Done: msi's Ollama (#394, #395), open-webui (#262) and the llm-gateway
(homelab-gitops #265) on hosts; the alert bridge posts to lenovo's native
ntfy; the journald collector on msi (#301). Step 1 (#414) takes Prometheus,
the operator, kube-state-metrics, Alertmanager, node-exporter, Grafana, Loki
and alloy-otlp, which also answers #302 (Loki) and #399 (P5). The journald
collector on the other hosts (#330) lands any time before step 4.

### Keep until step N

| Item | Until | Why it waits |
|---|---|---|
| Alloy DaemonSet (pod logs) | step 1 | pod labels come from the Kubernetes API; it goes with the in-cluster stack (homelab-gitops #271) |
| Traefik | step 2 | Caddy on acer takes every name, including the routes to host services |
| herman, karta | step 2 | become Nix-built static sites served by Caddy |
| zot | step 2 | zot retires once nothing pulls from it (karta's pod is its last puller) |
| nixos-config's `registry` Justfile variable, `registry-login` recipe and the skopeo/dive comment in `k3s/server.nix` | done (#420) | removed with the cosign recipes and key |
| k3s ntfy (`ntfy.sammasak.dev`) | step 2 | the name moves off Traefik; whether it routes to lenovo's native ntfy or retires is decided in #420 |
| chat leftovers: the `open-webui-backup` CronJob and its 10Gi claim, the `open-webui-state-v2` claim | step 2 | removed with the gitops cleanup in #420; both claims go on the #146 by-hand list |
| Authentik and its Postgres | step 3 | no upstream NixOS module; it gates sign-in for everything; high risk |
| k3s, Flux, Cilium, kyverno, KEDA, MetalLB, cert-manager, external-dns, metrics-server | step 4 | the platform; removed once nothing runs on it |
| Host cluster modules: `cluster-watchdog.nix`, `k3s-db-snapshot.nix`, `nixos-rebuild-trigger`, `flux.nix` | step 4 | they serve the cluster; the watchdog's paging floor gets a host-side replacement first |

## Placement

The stores stay on black-pi. It is always on, it is neither the single worker
(acer, whose loss the monitoring must report) nor the control plane (lenovo,
which has had memory incidents and already carries both ntfy instances), and
the data is already on its disk, which turns the Loki move into a local copy
instead of a 30-day parallel run. Its limits are memory (75% used) and a 29 GB
SD card with 5.9 GB free, so each step on black-pi has floors: over the 24
hours after it, available memory stays at or above 600 MiB (about 970 today)
with no new OOM kill; over 72 hours (one full retention period), the root
filesystem keeps at least 3 GB free. A step that breaks a floor is rolled
back and placement is reopened with those numbers. #301 records journal
volume per host in bytes per day; a host whose journal would add more than
Loki's current daily intake gets a drop rule for its noisiest units before
its collector is enabled. Running Loki as a host service removes its pod
overhead but not its working set (148 MiB today).

The edge and Authentik go on acer, which already holds Traefik, Authentik and
the moved apps, so its loss costs what it costs today.

## Order of work

The owner's four steps, 2026-11-15. Each step's issue holds its gates, tests
and rollback; each needs the one before it.

| Step | Change | Status | Gate |
|---|---|---|---|
| 1 | Prometheus, Alertmanager, Grafana, Loki and alloy-otlp as NixOS services (black-pi; alloy-otlp on acer); the in-cluster stack removed | done 2026-11-15: #419 deployed, homelab-gitops #271 merged (#414 closed; OTLP metrics fix #424) | owner: each deploy, the #271 merge |
| 2 | Caddy on acer fronts every name and replaces Traefik; herman and karta as Nix-built static sites; zot and the chat leftovers retire | planned, #420 | owner: acer deploy, the Cloudflare secret for acer, the AdGuard repoint, zot and chat claims |
| 3 | Authentik and its Postgres as NixOS services, Caddy `forward_auth` | planned, #421 | owner: host choice, secrets, the database cut-over |
| 4 | Remove k3s, Flux, Cilium, kyverno, KEDA, MetalLB, cert-manager, external-dns, metrics-server and the host cluster modules | planned, #422; needs the watchdog's host-side replacement | owner: every host deploy, external-dns's leftover AdGuard rules, archive homelab-gitops, state deletion |

## Not done here

No scheduler, controller, operator or service framework. One ingress per
name: Caddy replaces Traefik in step 2. No change to secret values. DNS
changes only in steps 2 and 4, each an owner gate. No PVC or state is deleted
by any step; that is the owner's by-hand list (homelab-gitops #146).
