# Nix store paths instead of images: environments and k3s workloads

Research and plan, 2026-11-12. Nothing here is built yet. It answers one
question: what Anthropic's "Nix instead of Docker on Kubernetes" setup really
is, and how the same workflow fits this fleet when developer environments run
on the NixOS hosts and only "production" workloads run on k3s.

Sources: the two PlanetNix talks (captions read in full), the five RFC issues
that cite them (nixos-config #200, #201, homelab-gitops #146, devenv-platform
#120, #121), upstream repos, and an inventory of the live cluster.

## What Anthropic does

Sourced from the talks. Nothing below is known to hold after March 2026.

**Production (Aneesh Agrawal, SCALE 22x, 2025).**

- The problem was one 35 GB image: 4 minutes to pull, close to an hour to
  rebuild. Layered Nix images did not fix it, because 128 layers over 35 GB is
  250 MB a layer at best, and containerd unpacks layers one at a time.
- No image holds the closure. CI builds, uploads to a binary cache, and the pod
  spec carries a store path. The path is fetched at pod start and put on PATH.
- The fetcher is `nix-sidecar`: a privileged sidecar init container of about
  200 lines, described as "nix-snapshotter in user space". It downloads the
  closure to a hostPath cache on the node's SSD, then bind-mounts only the
  paths that pod declared into an empty volume the app container mounts as
  `/nix`. It keeps running to clean up the mounts and to collect old paths.
- Caches are layered: object storage, a replica per region, a cache service per
  region, and the node SSD.
- Result: about 70 s for a scaled image pull, 15 s for a cold Nix fetch, and
  zero on a warm node.
- They rejected a shared host store (a pod would see every path on the node,
  and the lower store cannot be collected) and nix-snapshotter (they could not
  change containerd on managed nodes, and did not want a Nix daemon per node).
- Kubernetes stays the orchestrator. `nix-sidecar` is not published.

**Developer environments (Sam Fu, SCALE 23x, 2026).**

- A dev box is a long-lived pod (a StatefulSet, declared in Terraform) that the
  developer reaches over SSH.
- Its store is read-write with a Nix database, so builds work in place.
- Nix's build sandbox failed inside the pod. They refused privileged pods and
  fixed it with user namespaces (`hostUsers: false`) and an unmasked `/proc`,
  which cost a control plane upgrade and a wrapper around `runc`.

**Not sourced anywhere:** how environments are created, parked or torn down;
any link between this and agent sandboxes; fleet sizes.

## What the issues assumed, and what changed

- None of the five RFCs assumes environments on Kubernetes. Each lists a k8s
  workspace as a paper comparison at most.
- They were written against the daemon-less nspawn runtime that #210 deleted.
  Two of them now state invariants the current environments break by design:
  #201 ("no host Nix daemon socket", closure-only view) and devenv-platform
  #120 (invariants 4 and 6).
- #200 option C, a signed LAN cache, is live (#225, #227) with no recorded
  decision.
- homelab-gitops #146 is the only one about store paths in pods. Every latency
  figure it asks for is still unmeasured.

## Environments: the same workflow on the hosts

The workflow already exists here. Each part of Anthropic's dev box has a
counterpart, and the host version is cheaper because the store needs no
delivery at all.

| Anthropic dev pod | Here |
|---|---|
| StatefulSet declared in Terraform | `sam.workers.instances.<name>` in the host's NixOS config, deployed with deploy-rs |
| SSH into the pod | Herdr from lenovo, or SSH to `<name>.<host>` |
| Closure fetched to a node cache | The host's `/nix/store`, mounted read-only; nothing is fetched or copied |
| Read-write store and database | Host daemon socket, so a build in one environment is there for the next |
| Regional caches | Signed harmonia caches between the hosts |
| User namespaces for the Nix sandbox | nspawn user namespaces; the nested sandbox fix is merged (#239) |
| Privileged pods refused | Secrets stay on the host (phase 1 live); no privileged guests |

What is still missing compared with their setup:

1. **Per-pod view of the store.** A guest sees the whole host store. Anthropic
   rejected exactly that. The plan's answer stays a per-environment nix-daemon
   in the environment's slice; a closure-only mount would break the shared
   daemon.
2. **Nested sandboxes.** Same failure they hit, same cause (masked `/proc`).
   Fixed in #239 and checked in a deployed guest on acer.
3. **Lifecycle past start and stop.** They say nothing; ours is in
   `environments-plan.md` (parked state, slot pool).

No new runtime is needed. extra-container and microvm.nix were looked at:
extra-container adds an imperative path this fleet does not want, and microVMs
stay the exit named in "When to leave nspawn".

## k3s workloads: store paths instead of images

### Where the cluster is

- 61 distinct images. 8 are built here and pulled from zot
  (`registry.sammasak.dev/lab/`); 53 are upstream.
- Builds are manual on lenovo. Nothing is signed or verified at admission.
- acer holds 7.4 GB of images; msi 134 GB, mostly about 14 stale
  `claude-worker` images.
- All nodes: k3s v1.36.5, containerd 2.3.4, kernel 7.2, `landlock` in the LSM
  list. acer has 762 GB free.

### Options

| Option | Registry | Shares host store | Risk to acer | State |
|---|---|---|---|---|
| nix-store-csi | no | no (own store on the node) | low: a DaemonSet, only pods that use it depend on it | 4 weeks old, one author |
| Images preloaded with `services.k3s.images` | no | no | lowest | stock nixpkgs |
| k3s `--snapshotter=nix` | no | yes, with real GC roots | high: changes every pod on the node | `nix:0` refs fail in k3s's containerd (k3s #14393, open) |
| hostPath `/nix/store` | no | yes | medium | forbidden by baseline pod security; whole store visible |
| Layered images through zot | yes | no | none | today |

### Choice

**nix-store-csi for the workloads built here, upstream images unchanged.** It
is the published design closest to `nix-sidecar`: the pod lists store paths,
the node keeps a cache, the pod sees only its closure, and old paths are
collected. Unlike a snapshotter change it is additive, which matters on a
cluster where acer is the only general worker.

How it fits what already runs:

- **Cache.** The harmonia caches the hosts serve on port 5000, with their
  per-host keys as the driver's trusted keys. No new service.
- **Pin.** The manifest carries the store path. Flux syncs it as it syncs an
  image digest today.
- **Base image.** One small runner image without `/nix`, built with Nix and
  preloaded through `services.k3s.images`, so the pilot needs no registry.
- **Arm64.** The driver takes a path per system. Pilot on amd64 only.

Costs and limits, stated plainly:

- The driver's store is separate from the host's, so a closure on acer exists
  twice. Disk is not the constraint there.
- Anyone who can create a pod can mount any path the caches serve, and harmonia
  serves each host's whole store. Set the driver's namespace allowlist and its
  store size cap from the start.
- The project is new and has no scaling data. The fallback is preloaded images,
  which use only stock parts but tie every rollout to a NixOS deploy.
- Revisit the snapshotter when k3s #14393 closes, on msi first. It is the only
  option that shares the host store.

### Phases

Each phase ends with a measurement; "no change" is a valid result.

1. **Baseline.** For `llm-gateway` on acer, time a cold and a warm rollout from
   scheduled to Ready, three runs each, and record image and closure size. This
   is the figure homelab-gitops #146 asks for.
2. **Pilot.** Install the driver in `kube-system` (kubelet root is
   `/var/lib/kubelet` here; confirm at install). Run `llm-gateway` from its
   existing static derivation as a second Deployment beside the image-based
   one. Repeat the baseline runs. Check that a pod outside the allowlist is
   refused and that the driver's collection leaves a running pod alone.
3. **Decide.** Adopt if the warm start is no worse and the cold start or the
   build-to-running path is clearly better. Otherwise fall back to preloaded
   images or stop.
4. **Migrate.** In order of how ready the derivation is: system-one, karta-web,
   styrka-web, herman-web, then the rest. Each app repo renders its manifest
   with the store path.
5. **Remove.** When nothing pulls from zot, remove zot and the manual build
   steps. Prune the stale images on msi.

### Owner decisions

- Start the pilot (a privileged DaemonSet on the cluster is a new privileged
  component).
- Record the choice on homelab-gitops #146, and close or restate #201 and
  devenv-platform #120 against the current environments.
- Removing zot and pruning msi images, when phase 5 is reached.

### Not verified

- Image volumes (stable in Kubernetes 1.36) were not tested on k3s; they still
  need a registry or a preload.
- Whether the driver's pods can reach port 5000 on the hosts through Cilium and
  the host firewall.
- Kernel KVM support on black-pi, which only matters for the microVM exit.
