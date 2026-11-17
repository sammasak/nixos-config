# Nix store paths instead of images: environments (k3s half superseded)

Research and plan, 2026-11-12; phase 1 of the environments half is live. It answers one
question: what Anthropic's "Nix instead of Docker on Kubernetes" setup really
is, and how the same workflow fits this fleet when developer environments run
on the NixOS hosts and only "production" workloads run on k3s (since removed).

Sources: the two PlanetNix talks (captions read in full), the five RFC issues
that cite them (nixos-config #200, #201, homelab-gitops #146, devenv-platform
#120, #121), upstream repos, and an inventory of the cluster as it was.

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

## k3s workloads

Superseded: the cluster was removed (see [k3s-to-nixos-native.md](k3s-to-nixos-native.md)).
The store-path delivery pilot (nix-store-csi, preloaded images, snapshotter) was dropped with it.
