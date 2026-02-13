# Workstation Images (KubeVirt)

> Build and publish a reusable NixOS workstation image for the Kubernetes workstation fleet.

## Purpose

This doc defines the `nixos-config` side of the workstation architecture:

1. one reusable workstation template configuration
2. one repeatable image build command
3. one versioning flow to update VM fleets in `homelab-gitops`

## Implemented Template

The repository now includes:

- `hosts/workstation-template/configuration.nix`
- `hosts/workstation-template/variables.nix`
- `hosts/workstation-template/home.nix`
- `modules/homelab/workstation-image.nix`
- `flake-modules/hosts/workstation-template.nix`
- `scripts/build-workstation-image.sh`

`workstation-template` is a headless base-role host profile with:

- SSH enabled and key-based auth via existing user module flow
- cloud-init enabled (for KubeVirt bootstrap userdata)
- qemu guest service enabled
- desktop/audio daemons forced off to reduce VM overhead

## Build Commands

Build KubeVirt image:

```bash
./scripts/build-workstation-image.sh workstation-template kubevirt
```

Build QCOW2 image:

```bash
./scripts/build-workstation-image.sh workstation-template qcow
```

Direct command (without wrapper script):

```bash
nix run github:nix-community/nixos-generators -- \
  --flake path:.#workstation-template \
  --format kubevirt \
  --out-link result-workstation-template-kubevirt
```

`path:.#...` ensures local uncommitted changes are included while iterating.

## Suggested Versioning

Use image tags tied to date + short git SHA:

- `2026-02-11-<sha>`

Recommended release flow:

1. Build image from `workstation-template`.
2. Publish to registry/artifact store.
3. Update `spec.imageURL` in WorkspaceClaim YAML files under `homelab-gitops/apps/workstations/claims/`.
4. Delete rootdisk DataVolumes to trigger re-import, then commit and let Flux + workspace-controller roll out.

## Centralized Module Update Model

For fleet consistency, treat workstation updates as immutable image releases:

1. Update shared Nix modules (`modules/homelab/workstation-image.nix`, `modules/core/*`, selected program modules).
2. Rebuild `workstation-template` image.
3. Publish new image tag.
4. Update all workstation VM manifests to the same tag in `homelab-gitops`.
5. Roll the fleet.

Avoid per-workstation ad-hoc `nixos-rebuild` changes inside running VMs. Keep drift at zero by making Git + image the only mutation path.

## AdGuard DNS Integration

Workstation SSH names are served by AdGuard rewrites in:

- `hosts/lenovo-21CB001PMX/configuration.nix`

Keep this list in sync with workstation service IPs declared in `homelab-gitops`:

```bash
cd ../homelab-gitops
kubectl -n workstations get workspaceclaims -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.loadBalancerIP}{"\n"}{end}'
```

After updating rewrites, deploy NixOS config on the AdGuard host:

```bash
sudo nixos-rebuild switch --flake .#lenovo
```

## Required Customization Before Production

1. Add/adjust dev tooling in `modules/homelab/workstation-image.nix`.
2. Decide if workstation images are:
- immutable + ephemeral root disk
- or persistent root (via DataVolume/PVC import strategy)
3. Confirm cloud-init behavior in the chosen image format.
4. Keep authorized user public keys current in `lib/users.nix` (or per-host overrides).

## Validation

```bash
# Validate image build path end-to-end
./scripts/build-workstation-image.sh workstation-template kubevirt

# Validate full flake
nix flake check --all-systems --no-write-lock-file
```

## Related

- `../homelab-gitops/docs/tech/workstation-fleet.md`
- `../homelab-gitops/docs/tech/workstation-fleet-scope.md`
- `../homelab-gitops/docs/tech/workstation-fleet-verification.md`
- `../homelab-gitops/apps/workstations/`
- `hosts/lenovo-21CB001PMX/configuration.nix`

Upstream references:

- https://github.com/nix-community/nixos-generators
- https://github.com/nix-community/nixos-generators#supported-formats
