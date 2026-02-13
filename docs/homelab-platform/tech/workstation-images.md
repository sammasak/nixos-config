# Workstation Images (KubeVirt)

> Build and publish reusable NixOS workstation images for the Kubernetes workstation fleet.

## Purpose

This doc defines the `nixos-config` side of the workstation architecture:

1. One reusable workstation template configuration
2. One repeatable image build command
3. One publish command to push OCI containerDisk images to Harbor
4. One versioning flow to update VM fleets in `homelab-gitops`

## Quick Start

```bash
# Build the NixOS qcow2 image
just build

# Publish as OCI containerDisk to Harbor
just publish

# Or both in one step:
just release

# Check the published image
just image-info
```

> **Prerequisite:** First-time Harbor login: `just harbor-login`

## Implemented Template

The repository includes:

- `hosts/workstation-template/configuration.nix`
- `hosts/workstation-template/variables.nix`
- `hosts/workstation-template/home.nix`
- `modules/homelab/workstation-image.nix`
- `flake-modules/hosts/workstation-template.nix`
- `scripts/build-workstation-image.sh`
- `Justfile` (build, publish, release recipes)

`workstation-template` is a headless base-role host profile with:

- SSH enabled and key-based auth via existing user module flow
- cloud-init enabled (for KubeVirt bootstrap userdata)
- qemu guest service enabled
- Desktop/audio daemons forced off to reduce VM overhead

## Build Commands

### Using Justfile (recommended)

```bash
just build                    # Build qcow2 image
just publish                  # Publish to Harbor (tags with YYYYMMDD + latest)
just publish v1.2.3           # Publish with custom tag
just release                  # Build + publish in one step
just harbor-login             # Login to Harbor registry
just image-info               # Show image metadata in Harbor
just image-info 20260213      # Inspect a specific tag
```

### Direct commands (without Justfile)

Build KubeVirt image:

```bash
./scripts/build-workstation-image.sh workstation-template kubevirt
```

Build QCOW2 image:

```bash
./scripts/build-workstation-image.sh workstation-template qcow
```

Direct nix command:

```bash
nix run github:nix-community/nixos-generators -- \
  --flake path:.#workstation-template \
  --format kubevirt \
  --out-link result-workstation-template-kubevirt
```

`path:.#...` ensures local uncommitted changes are included while iterating.

## OCI ContainerDisk Publish Pipeline

The `just publish` recipe converts the qcow2 into an OCI container image suitable for KubeVirt's [containerDisk](https://kubevirt.io/user-guide/storage/disks_and_volumes/#containerdisk) volume type.

### What happens under the hood

1. Finds the qcow2 in `result-workstation-template-kubevirt/`
2. Creates a tar layer with the qcow2 at `/disk/disk.qcow2` (owned by `107:107` — the qemu user)
3. Builds a minimal OCI image layout with proper `rootfs.diff_ids` in the config
4. Pushes to Harbor via `skopeo copy oci:<dir> docker://<registry>/<project>/<image>:<tag>`
5. Also tags as `latest`

### Why not Docker/Podman/Buildah?

The OCI image spec is just JSON metadata + content-addressed blobs. We construct it directly with standard tools (`tar`, `sha256sum`, `jq`) and push with `skopeo` via `nix shell`. This avoids installing container build tooling on the NixOS host — keeping the dependency footprint minimal.

> **Advanced:** The OCI config must include `rootfs.diff_ids` matching the layer digests. Without this, containerd rejects the image with "layers and diffIDs don't match". See the [OCI Image Specification](https://github.com/opencontainers/image-spec) for the full format.

### Harbor setup

Images are stored in the `workstations` project on Harbor:

```
registry.sammasak.dev/workstations/nixos-workstation:latest
registry.sammasak.dev/workstations/nixos-workstation:20260213
```

The project is public — no `imagePullSecrets` needed in KubeVirt VM specs.

## Versioning

Images are tagged with the publish date (`YYYYMMDD`) and also `latest`:

```
registry.sammasak.dev/workstations/nixos-workstation:20260213
registry.sammasak.dev/workstations/nixos-workstation:latest
```

Custom tags are supported: `just publish v1.2.3`

## Update Workflow (Centralized)

For fleet consistency, treat workstation updates as immutable image releases:

1. Update shared Nix modules (`modules/homelab/workstation-image.nix`, `modules/core/*`, selected program modules).
2. Build and publish: `just release`
3. In `homelab-gitops`:
   - If claims use `:latest`: `just ws-restart rocket` (picks up new image on restart)
   - If claims use pinned tags: `just image-update rocket registry.sammasak.dev/workstations/nixos-workstation:<new-tag>`

Avoid per-workstation ad-hoc `nixos-rebuild` changes inside running VMs. Keep drift at zero by making Git + image the only mutation path.

> **Why immutable images?** NixOS's strength is reproducibility — the system state is fully determined by the configuration. Running `nixos-rebuild` inside a VM bypasses Git and creates drift between workstations. By treating images as artifacts (built once, deployed everywhere), we maintain the same NixOS guarantee across the entire fleet.

## AdGuard DNS Integration

Workstation SSH names are served by AdGuard rewrites in:

- `hosts/lenovo-21CB001PMX/configuration.nix`

Keep this list in sync with workstation service IPs declared in `homelab-gitops`:

```bash
cd ../homelab-gitops
just fleet-status
```

After updating rewrites, deploy NixOS config on the AdGuard host:

```bash
sudo nixos-rebuild switch --flake .#lenovo
```

## Validation

```bash
# Validate image build path end-to-end
just build

# Validate full flake
nix flake check --all-systems --no-write-lock-file

# Verify published image
just image-info
```

## Related

- `../homelab-gitops/docs/tech/workstation-fleet.md`
- `../homelab-gitops/docs/tech/kubevirt-image-import-pattern.md`
- `../homelab-gitops/docs/tech/workstation-fleet-scope.md`
- `../homelab-gitops/apps/workstations/`
- `hosts/lenovo-21CB001PMX/configuration.nix`

Upstream references:

- https://github.com/nix-community/nixos-generators
- https://github.com/nix-community/nixos-generators#supported-formats
- https://kubevirt.io/user-guide/storage/disks_and_volumes/#containerdisk
- https://github.com/opencontainers/image-spec
- https://github.com/containers/skopeo
- https://github.com/casey/just
