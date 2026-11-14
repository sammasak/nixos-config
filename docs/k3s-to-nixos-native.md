# Moving suitable services from k3s to NixOS: decision record and inventory

Status: proposed, 2026-11-13. Nothing here is deployed. It records what the
audit observed, which delivery model fits this fleet, and the order of work.
Deploying to a host, deleting state and removing a running k3s service each
need the owner's approval; every step below names its gate.

Evidence: read-only audits of homelab-gitops at main 32b7c88 (what Flux runs),
nixos-config at main 9342c37, the live cluster (kubectl, Loki, and Prometheus
queried from black-pi), and a research pass on deployment tooling checked
against upstream repositories on 2026-11-13. Tracking issue: nixos-config
#299.

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

- services that should outlive the cluster become plain NixOS modules on a
  named host;
- workloads that use what Kubernetes is good at here stay on k3s;
- the deployment tool stays the one already in use.

What is lost for a moved service is listed under "Given up". devenv machines
and comin are the two tools worth reopening, each under a stated condition
below.

## Decision

1. **Hybrid, by failure domain.** Telemetry and paging move to NixOS modules,
   because the tools used to diagnose a broken cluster should not run inside
   it. Workloads that rely on KEDA scale to zero, Traefik with cert-manager and
   Authentik forward auth stay on k3s. k3s is not removed.
2. **Deployment stays deploy-rs from the existing flake.** No new tool now.
   While a moved service still has clients or routes in the cluster, its
   migration is a two-repository change (see "Two repositories").
3. **No service framework.** A moved service is one `homelab.<name>` module in
   `modules/homelab/` that wraps the upstream NixOS module, opens its port with
   `mkDualBackendFirewall`, and has one `scripts/test-<name>.py` gate reading
   the shared probe evaluation. A shared helper is written only when a third
   service repeats the same wiring.
4. **Pod concerns stay in the cluster.** Pod logs and Kubernetes object metrics
   are collected by the DaemonSet and the operator stack for as long as k3s
   runs pods. Hosts get their own journald collector, as a host service so
   that it keeps working when the cluster does not and covers msi. The cost is
   a second Alloy process on each host, which is measured (see Placement).
5. **Nix store delivery into k3s is ranked after telemetry and decided by one
   measurement** (E0). See "Relation to the delivery plan".

Vault ADR-001 (Flux) and ADR-005 (single k3s cluster) stay in force for what
remains on k3s.

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

Today, from the placement above:

| Outage | Metrics | Logs | Dashboards | Paging |
|---|---|---|---|---|
| acer down | collected (black-pi) | collected, minus acer | unreachable: Traefik, Authentik and the interceptor are on acer | alerts reach the k3s ntfy; the public name is down with Traefik |
| lenovo down | collected until pods need the API | collected | only with client-side hosts entries for the Grafana and Authentik names: LAN DNS is AdGuard on lenovo and the routes are host-based | none: both ntfy instances are on lenovo |
| black-pi down | none | none | none | only the cluster watchdog on lenovo |
| k3s or Cilium broken, hosts up | none | none | none | only the cluster watchdog |

The last row is the one this work addresses: when the cluster is the thing
that is broken, nothing is left to look at. Steps P1, P4 and P2 fix the logs
column of that row (msi after P4, every host after P2); metrics, dashboards and alert-driven paging follow only if P5
moves Prometheus, Alertmanager and Grafana. After the steps below, with the
stores as NixOS services on black-pi:

| Outage | Metrics | Logs | Dashboards | Paging |
|---|---|---|---|---|
| acer down | as today | as today | after P5: Grafana on a LAN port (needs a local login, Authentik is on acer) | bridge posts to the native ntfy on the LAN |
| lenovo down | as today | host logs keep flowing | as today | none; unchanged, and not fixable without a second ntfy host or an external dead-man check, neither proposed here |
| black-pi down | none | none | none | cluster watchdog; unchanged |
| k3s or Cilium broken, hosts up | after P5: host metrics | msi's journal after P4, every host's (k3s, containerd, kernel) after P2, queried through Loki's LAN port until P5 | after P5 | cluster watchdog as today, plus `OnFailure=` pages from the moved units; alert rules page only after P5 |

## Deployment workflow

### What is used

"Present" means it exists in nixos-config today; "to build" means the first
migration adds it.

| Need | Mechanism | State |
|---|---|---|
| Desired state per host | `nixosConfigurations.<host>` in one flake; a service is enabled per host in that host's `configuration.nix` | present |
| Reproducible builds | flake lock; x86 hosts substitute from the signed harmonia caches, the Pis build their own closures | present |
| Quality gates | pre-push `nixos:qa` on the pushed commit (flake check plus the Python gates), run off lenovo; one `scripts/test-<name>.py` per new module | present; test per module built for P1 |
| Trigger and approval | merge to main, then an explicit `just deploy HOST` that the owner approves; no host upgrades itself (`system.autoUpgrade` is asserted off on every host since #311) | present |
| Rollout order | one host at a time, least critical first: msi, black-pi, acer, lenovo | convention |
| Activation safety | deploy-rs `magicRollback`: a host that cannot be reached after activation reverts | present |
| Service health | `services.alloy` and most upstream units are `Type=simple`, so each module adds an `ExecStartPost` probe of the service's own local ready endpoint with a start timeout, the upstream restart policy with a slower `RestartSec` and a start limit, and `OnFailure=` to ntfy. A unit that fails its probe fails the activation and so the whole host deploy; the probe therefore never tests anything remote (a collector must not fail a deploy because Loki is away) | built for P1 |
| Rollback on a failed unit | deploy-rs `autoRollback` | present on x86 (rehearsed on msi, #324); the Pis are still exposed, see gap 1 |
| End-to-end check | after every deploy: `systemctl is-system-running`, the generation link, and the service's user-visible check (a log line queryable in Loki, a test page arriving on the phone) | to build, as a checklist in each issue |
| Secrets | sops-nix with per-host age keys; adding a recipient is an owner step. The first three steps need no new secret | present |
| Persistent state | a fixed directory under `/var/lib/<service>` on a named host, with a backup job declared in the same module | to build, see gap 3 |
| Service discovery | static: one host address and port, set once in each repository | to build |
| Ingress and TLS | Traefik in k3s keeps the public names and certificates; a moved service is also reachable on a LAN port so that it works when k3s does not | design below |
| Observability of the moved service | its journal through the host collector; its scrape target and alert rule in homelab-gitops while Prometheus runs there | to build |

### Two repositories

While Prometheus, Traefik and the clients of a moved service live in k3s, a
migration touches both repositories. Order: (1) nixos-config adds the module
and a deploy brings the service up next to the old one; (2) homelab-gitops
repoints clients, routes and scrape targets through Flux; (3) after an
observation period, homelab-gitops removes the old workload. Rollback runs the
other way: revert the gitops change first, then disable the module. Step 3 is
the only one that cannot be undone by a revert when it deletes a volume, so it
is always a separate owner gate.

### Reaching a host service from the cluster

Default: clients are repointed by configuration to the host's LAN address and
port. Loki's clients are few and all declared in Git (the Alloy DaemonSet,
alloy-otlp, the Grafana datasource, the usage report script, one hard-coded
ClusterIP in nixos-config for pi-offload and, after P1, msi's collector), so no Service object needs to be swapped. A
selectorless Service with an EndpointSlice is used only where a cluster DNS
name must stay; it has to be a new object with its own name, because the
chart-owned `loki` Service has a selector and an unpinned ClusterIP and cannot
be converted in place without a gap.

What this changes, and what must be rehearsed before the first stateful move:

- **Who can reach the port.** The k3s module trusts the Cilium interfaces
  (`cilium_host`, `cilium_vxlan`, `lxc+`) in the NixOS firewall, so pods can
  already reach every listening port on their node, and only a Cilium policy
  can limit that. The NixOS firewall rule that the module adds scopes LAN
  sources only. Whether a pod on another node arrives with its pod address
  through the tunnel or masqueraded to the node's LAN address is not assumed
  here; the reachability check R1 records it, and the rule admits the pod
  network only if R1 shows it is needed.
- **Trust, for Loki.** Nothing changes for pods: no network policy selects
  Loki today, the `monitoring` namespace is an accepted exception to
  default-deny, and Loki runs without authentication, so every pod can already
  push and query. What is new is the host side: an unauthenticated Loki on a
  port of black-pi, reachable from whatever LAN sources the firewall rule
  admits (the other cluster hosts) and from any process on those hosts. The
  owner accepts that in the Loki issue, or the step waits for an
  authenticating proxy, which is not proposed now.
- **Cilium host firewall** is on and passes host traffic today only because
  the single host policy does not default-deny. Any later host policy has to
  admit these ports; the module's test records the port so the dependency is
  visible.
- **Reachability check R1.** Once the native Loki is up on its port and
  before any client uses it (P4 step 1, in msi's power window), it is queried
  from a pod on each node and from each other host, and the source address of
  each request is recorded. Loki does not log source addresses by default, so
  the module turns on source-address and request logging for the check, or
  the addresses are read with tcpdump on black-pi. This tests the real
  firewall rule without a throwaway service. If it shows the rule must also
  admit the pod network, that costs one more black-pi deploy.

### Why not another tool

| Option | Verdict | Reason, and what would reopen it |
|---|---|---|
| comin (pull, closest to Flux) | not now | no automatic rollback or health check; every host evaluates the flake, including the Pis; pre-1.0. Reopen if hosts regularly miss deploys because they were asleep or unreachable |
| devenv machines | not now | exists since devenv 2.4.0 with a target-side watchdog and a health check, the best safety model of the push tools. Experimental; needs root SSH where this fleet forbids root login (devenv #3242); takes modules, not the existing flake hosts (#3226); the target cannot substitute from harmonia (#3342); requires a disko input; one shell health check per machine. Reopen when it deploys existing flake hosts over a non-root login and leaves experimental status |
| Colmena | no | no rollback; nothing deploy-rs lacks that is needed here |
| `system.autoUpgrade` as the pull path | no | no health gate; acer's former use was a gap, not a model |
| lenovo's `nixos-rebuild-trigger` | keep, do not generalise | it rebuilds lenovo at a pinned commit with a health gate on request from the cluster. Extending it to other hosts would be writing a deploy controller |
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
discovery (replaced by a declared scrape target).

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
   aarch64 build is evidenced, and the connectivity rollback is unexercised,
   so every deploy still ends with the end-to-end check above (#297).
2. **acer upgraded itself from main.** Closed by #300: acer's
   `system.autoUpgrade` is off, and since #311 every host asserts it. Until that change
   is deployed to acer, the running timer still switches to main weekly, so
   the old rule holds: a commit that changes a moved service on acer merges
   only with the owner's approval of the acer deploy, deployed the same day.
3. **Backups.** No tooling exists beyond Postgres dumps and a local k3s
   datastore snapshot. A stateful service does not move until its module
   declares an off-host backup with a rehearsed restore, or the owner accepts
   in its issue that the data has none. Loki is the second case: it has no
   backup today, its content is 72 hours of logs and 30 days of telemetry, and
   P4 proposes to move it with that posture unchanged.
4. **Hard-coded cluster addresses** in nixos-config (Loki 10.43.92.124 for
   pi-offload, the llm-gateway 10.43.0.80, msi Ollama) are replaced by the
   host address when the service behind them moves. The order of work keeps
   new uses of the Loki address to one host (msi, at P1).

## Inventory and classification

Risk is the cost of getting the move wrong. Every deletion and deploy is an
owner gate.

### Remove (observed unused; deletion is the owner's)

| Item | Evidence | Gate |
|---|---|---|
| `monitoring-tempo` StatefulSet and `monitoring-prometheus-pushgateway` Deployment in `monitoring` | 0 replicas for months; no manifest in Git; repo docs say they were removed | delete the two objects |
| PVCs `prometheus-...-db-...-0` (8Gi) and `alertmanager-...-db-...-0` (1Gi) on acer; PV `pvc-68839200` (old Loki, Retain) | mounted by nothing; the running stack uses the `pi-` claims on black-pi | default: archive each directory to a tarball on lenovo, then delete; the owner may waive the archive |
| Six failed `postgres-backup-offnode` Jobs, 32 to 69 days old | later runs completed; they keep KubeJobFailed firing | delete the Jobs; set `failedJobsHistoryLimit` |

Observed, but not classified as remove; the owner decides in the cleanup issue:

- external-dns: it only acts on Services and Ingresses carrying the
  `external-dns.alpha.kubernetes.io/hostname` annotation, no live object
  carries it, and its log says "All records are already up to date" every
  minute. As configured it manages no record. Removing it also removes the
  option of annotating a Service later.
- qdrant: three collections named `nb-*`, 492 KiB in total, and no request
  other than health probes in the 44 hours its current pod has run. Small and
  idle is not unused; the owner knows what wrote those collections.
- `archive/learn/` in homelab-gitops: applied by no Kustomization and no
  namespace of that name is live. Deleting the directory is a repository
  cleanup, not a cluster change.
- The public hosts with zero requests in three days.

### Migrate (low risk, suited to NixOS)

| Service | Now | Destination | Storage | Consumers | Verification |
|---|---|---|---|---|---|
| Host log collector (new) | no host ships its journal; msi ships nothing | `services.alloy` reading journald only, on each cluster host; labels `host` and `unit`, a distinct `job` so it never overlaps pod logs; `MemoryMax` set | positions file | Loki | each host's journal queryable in Loki; a k3s restart line found by query; resident memory recorded |
| Alert delivery | bridge posts to the k3s ntfy | bridge posts to the native ntfy on lenovo | none | phone | see P3 |
| Loki | StatefulSet on black-pi, `local-path` volume, which is a directory on black-pi | `services.loki` on black-pi | 72 h of logs and 30 days of agent telemetry | Alloy DaemonSet, alloy-otlp, Grafana, pi-offload, the usage report | see P4 |

### Research (stateful or coupled; an experiment first)

| Service | Coupling | Question to answer |
|---|---|---|
| Prometheus, operator, kube-state-metrics, Alertmanager | 28 ServiceMonitors and PodMonitors, 164 rules mostly about Kubernetes objects, targets on the pod network | a native Prometheus needs an API credential on the host to discover pods (a new secret) and declared rules. Does that cost less than the operator it replaces, and does black-pi have the memory? Decided at P5 from measurements |
| node-exporter DaemonSet | chart relabels `instance` and `node` that dashboards join on | moves with Prometheus, not before: while Prometheus is in the cluster a native exporter gains nothing |
| Grafana | Authentik OIDC secret, nine dashboards as ConfigMaps plus chart dashboards, KEDA route | `services.grafana` provisioning from the same JSON; needs the OIDC secret on a host and a local login for when Authentik is down (owner steps) |
| k3s ntfy and `ntfy.sammasak.dev` | auth database, TLS name; publishers other than the bridge not yet attributed (19 requests in three days) | who publishes and subscribes there, from ntfy's own log. Retiring it deletes the auth database and is a separate owner gate from repointing the bridge |
| alloy-otlp (agent telemetry intake) | Traefik allowlist, bearer token, tested privacy pipeline | portable (one Alloy config whose tests run locally); move after Loki, with its secret (owner step) |
| zot registry | every in-house image is pulled from it; 50Gi, no backup | a registry outside the cluster removes the cluster's dependence on itself; needs a backup and a pull test from all nodes |
| llm-gateway | SQLite state, pinned ClusterIP used by hosts, bearer keys in SOPS | already a static Nix-built binary; a natural systemd service, but its secrets must move (owner step) |
| Postgres (Authentik, workout) | data; a past data loss | only with tested dump and restore |

### Keep on k3s

| Service | Why |
|---|---|
| Alloy DaemonSet (pod logs) | pod labels come from the Kubernetes API; a host collector would need a credential or lose the labels dashboards and alerts use. Running it on msi too is a one-line toleration, raised as a question |
| Authentik | no upstream NixOS module; it gates sign-in for everything; high risk, low saving |
| Traefik, cert-manager, MetalLB, Cilium, KEDA, Flux, Kyverno | the platform for what stays |
| open-webui, ollama, kokoro, whisper, monty-runner, workout | scale to zero through KEDA; they hold no memory while idle |
| ollama on msi | always on (no scaler), 20Gi of models on msi, reached by a pinned ClusterIP; a candidate for a host service later, but coupled to the llm-gateway's move |
| herman, styrka, karta, system-one | 7 to 8 MiB each and public; moving them saves nothing |

## Placement

The stores stay on black-pi. It is always on, it is neither the single worker
(acer, whose loss the monitoring must report) nor the control plane (lenovo,
which has had memory incidents and already carries both ntfy instances), and
the data is already on its disk, which turns the Loki move into a local copy
instead of a 30-day parallel run. Its limits are memory (75% used) and a 29 GB
SD card with 5.9 GB free, so each step on black-pi has floors: over the 24
hours after it, available memory stays at or above 600 MiB (about 970 today)
with no new OOM kill; over 72 hours (one full retention period), the root
filesystem keeps at least 3 GB free. A
step that breaks a floor is rolled back and placement is reopened with those
numbers. P1 also records journal volume per host in bytes per day; a host
whose journal would add more than Loki's current daily intake gets a drop rule
for its noisiest units before its collector is enabled. Running Loki as a host
service removes its pod overhead but not its working set (148 MiB today).

## Relation to the delivery plan

`docs/records/nix-native-delivery.md` (2026-11-12) plans a pilot that delivers Nix
store paths into pods, and homelab-gitops #146 holds the owner's choice between
OCI, NixOS services and that pilot. This record leaves that choice with #146
and proposes two changes to the plan for the owner to accept or reject there:
telemetry on hosts goes before the pilot, and the pilot's "Phase 1 Baseline"
becomes E0 with a decision rule.

- The Anthropic pattern earns its speed on images of tens of gigabytes across
  many nodes. The in-house images here are 13 to 30 MiB, so the speed case has
  to be shown, not assumed.
- **E0** measures a real pod start on acer (pull, sandbox, start, ready; cold
  and warm, plus one KEDA wake from zero). If image pull is under about 20% of
  schedule-to-ready, the pilot is not a speed project.
- Its other reasons remain valid: no registry for the cluster to depend on,
  and no base-image CVE drift. That plan picks the CSI driver with preloaded
  images as fallback; given that the driver is weeks old and has one author,
  this record suggests weighing the stock options (preloaded images, layered
  images built by Nix) first. That is a proposed reordering, not a decision.
- Telemetry on hosts goes first because it is useful under every outcome of
  #146.

## Order of work

| Step | Change | Proves | Reversible by | Gate |
|---|---|---|---|---|
| 0 | Remove the observed-unused items (homelab-gitops #157) | n/a | archives for the volumes | owner, per item |
| G1 | deploy-rs rehearsal on msi: a unit that fails on purpose (#297) | whether a failed unit rolls back with the current pin | switched back by hand if it does not | owner: deploy msi, in its power window |
| E0 | Pod start timing on acer in a scratch namespace | the speed case for store delivery | delete the namespace | owner: one throwaway Deployment |
| P1 | Journald collector on msi, writing to Loki's ClusterIP | module shape, readiness probe, test gate, deploy and end-to-end check on the least critical host; journal volume | disable the module, deploy | owner: deploy msi |
| P3 | Bridge posts to the native ntfy (gitops only) | a cluster client using a host service; a gitops-only change | revert the URL | owner: merge to gitops |
| P4 | Loki to a NixOS service on black-pi, with the reachability check R1 as its first sub-step | cluster to host networking, state, client cut-over, the two-repository order | below | owner: each sub-step |
| P2 | Journald collector on black-pi, acer, lenovo, one at a time, writing to Loki's LAN address | memory on the tight hosts, a native build on the Pi, the acer rule from gap 2, lenovo's self-push | as P1 | owner: each deploy |
| P5 | Decide Prometheus, Alertmanager, Grafana and node-exporter from the numbers above | n/a | n/a | owner |

P2 comes after P4 so that only msi's collector ever uses the cluster address
and has to be repointed. Until P4, msi's collector works only while Cilium is
up on msi. naked-pi is not a cluster node and can join after P4.

P1 proves the deploy path and the module shape only. A cluster client is first
exercised at P3, cluster to host networking and state at P4, secrets not
before P5.

### P3 in detail

The native ntfy is plain HTTP on the LAN with open read-write access, so alert
text crosses the LAN in clear and any LAN device can read or publish the
topic. That posture is already accepted for the cluster watchdog and recorded
in the network-policy README of homelab-gitops; P3 extends it to alerts and
says so in its issue. The path is open today: the bridge's namespace has no
egress policy and port 2586 admits any LAN source.

1. Before the change: the phone is subscribed to the alert topic on the native
   instance, and a test publish arrives on the LAN and over the tailnet. A
   subscription on `ntfy.sammasak.dev` would stop receiving alerts after the
   repoint, and the k3s instance may deliver differently off the LAN, so this
   is checked, not assumed.
2. Repoint the bridge; a test alert and then a real firing alert arrive.
3. The k3s ntfy keeps running. Retiring it is a Research item with its own
   gate, after its publishers and subscribers are attributed from its log.

### P4 in detail

Loki holds about 1.8 GB according to a comment in its chart values; the issue
measures the directory first. The chart runs Loki 3.0 and nixpkgs carries a
newer release, so this is also an upgrade: both versions are named in the
issue and the schema configuration is carried over unchanged.

1. Module with `services.loki` on black-pi, same schema and retention, port
   opened to the cluster hosts only. R1 runs against it. A scrape target for
   it is declared in homelab-gitops and `up` is confirmed for the new job;
   `LokiIngesterDown` is confirmed after the cut-over, since the old pod masks
   it while both run, and it is silenced for the cut-over itself. `LokiPVCNearCapacity` reads the volume's kubelet
   metrics and cannot see a host directory, so the cut-over commit replaces it
   with a rule on black-pi's root filesystem at the 3 GB floor.
   `LokiNamespaceSilent` reads the DaemonSet's metrics and is unaffected.
2. One gitops commit is prepared that repoints every in-cluster client (the
   Alloy DaemonSet, alloy-otlp, the Grafana datasource), replaces the usage
   report script's port-forward to the old Service with the LAN address, swaps
   the disk alert, and scales the StatefulSet to zero. The commit is rendered
   before the merge to confirm the chart accepts zero replicas. alloy-otlp's change is an endpoint only; its privacy tests, which
   today assert against Loki 3.0, are run against the nixpkgs version before
   the merge.
3. Cut-over, in one sitting, inside msi's power window: record line counts
   for fixed queries over a fixed time range that has already ended; stop the native Loki and empty its data directory; apply
   the commit; once the pod has stopped, copy its whole data directory (chunks,
   index, write-ahead log, compactor state) with ownership fixed for the
   service user; start the native Loki; the same queries over the same range
   return the same counts. Writers retry for a bounded time, so logs
   produced during the copy can be lost; the issue states the measured
   duration. msi's journald collector is repointed by a deploy in the same
   sitting; what it could not deliver in between is accepted as lost. The
   pi-offload address ships on lenovo and acer and changes with a gated deploy
   of each; until then pi-offload on that host cannot reach Loki, which the
   issue states.
4. Disk, two branches decided by the measurement:
   - **The copy fits within the 3 GB floor:** the old volume stays untouched.
     Rollback: revert the gitops commit, which scales the StatefulSet back up
     on it.
   - **It does not fit:** the old directory is archived to lenovo and verified
     there, then moved instead of copied. Rollback: restore the archive into
     the volume, then revert the commit.
   In both branches the rollback ends on the nixos-config side: stop the
   native Loki and redeploy msi (and lenovo and acer if already repointed)
   back to the cluster address. Logs written to the native store after the cut-over are
   not in the old one; that loss grows with how long a rollback is delayed.
5. Releasing the old volume, or the archive, is a later, separate owner gate.

## Not done here

No scheduler, controller, operator or service framework. No second ingress on
the hosts while Traefik in k3s serves the public names. No change to secret
values, DNS or the MetalLB address. No new secret before P5.
