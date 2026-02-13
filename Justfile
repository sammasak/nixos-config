set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"
project := "workstations"
image := "nixos-workstation"
host := "workstation-template"

# Build NixOS qcow2 image
build host=host:
    bash scripts/build-workstation-image.sh {{host}}

# Publish qcow2 as OCI containerDisk to Harbor
publish tag=`date +%Y%m%d`:
    #!/usr/bin/env bash
    set -euo pipefail

    qcow2=$(find result-{{host}}-kubevirt/ -name '*.qcow2' | head -1)
    if [[ -z "$qcow2" ]]; then
      echo "ERROR: no qcow2 found in result-{{host}}-kubevirt/"
      exit 1
    fi
    echo "Found image: $qcow2"

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    # Create the disk layer tarball (qcow2 at /disk/disk.qcow2 owned by 107:107 = qemu)
    layertar="$tmpdir/layer.tar"
    layerdir="$tmpdir/layerroot/disk"
    mkdir -p "$layerdir"
    cp "$qcow2" "$layerdir/disk.qcow2"
    tar cf "$layertar" --owner=107 --group=107 -C "$tmpdir/layerroot" disk/

    # Compute layer digest and size
    layer_sha=$(sha256sum "$layertar" | awk '{print $1}')
    layer_size=$(stat -c%s "$layertar")

    # Build OCI directory layout
    ocidir="$tmpdir/oci"
    mkdir -p "$ocidir/blobs/sha256"
    cp "$layertar" "$ocidir/blobs/sha256/$layer_sha"

    # Config (must include rootfs.diff_ids matching the layer)
    config=$(jq -n --arg layer_sha "$layer_sha" '{
      architecture: "amd64",
      os: "linux",
      rootfs: {
        type: "layers",
        diff_ids: [("sha256:" + $layer_sha)]
      }
    }')
    config_sha=$(echo -n "$config" | sha256sum | awk '{print $1}')
    config_size=${#config}
    echo -n "$config" > "$ocidir/blobs/sha256/$config_sha"

    # Manifest
    manifest=$(jq -n \
      --arg config_sha "$config_sha" \
      --argjson config_size "$config_size" \
      --arg layer_sha "$layer_sha" \
      --argjson layer_size "$layer_size" \
      '{
        schemaVersion: 2,
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        config: {
          mediaType: "application/vnd.oci.image.config.v1+json",
          digest: ("sha256:" + $config_sha),
          size: $config_size
        },
        layers: [
          {
            mediaType: "application/vnd.oci.image.layer.v1.tar",
            digest: ("sha256:" + $layer_sha),
            size: $layer_size
          }
        ]
      }')
    manifest_sha=$(echo -n "$manifest" | sha256sum | awk '{print $1}')
    manifest_size=${#manifest}
    echo -n "$manifest" > "$ocidir/blobs/sha256/$manifest_sha"

    # Index
    jq -n \
      --arg manifest_sha "$manifest_sha" \
      --argjson manifest_size "$manifest_size" \
      '{
        schemaVersion: 2,
        manifests: [
          {
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: ("sha256:" + $manifest_sha),
            size: $manifest_size
          }
        ]
      }' > "$ocidir/index.json"

    echo '{"imageLayoutVersion":"1.0.0"}' > "$ocidir/oci-layout"

    # Push to Harbor
    dest="{{registry}}/{{project}}/{{image}}"
    echo "Pushing to $dest:{{tag}} ..."
    nix shell nixpkgs#skopeo -c skopeo copy \
      "oci:$ocidir" "docker://$dest:{{tag}}"
    echo "Tagging as latest..."
    nix shell nixpkgs#skopeo -c skopeo copy \
      "docker://$dest:{{tag}}" "docker://$dest:latest"
    echo "Done: $dest:{{tag}} (also tagged latest)"

# Build + publish in one step
release tag=`date +%Y%m%d`:
    just build
    just publish {{tag}}

# Login to Harbor
harbor-login:
    nix shell nixpkgs#skopeo -c skopeo login {{registry}}

# Show current image in Harbor
image-info tag="latest":
    nix shell nixpkgs#skopeo -c skopeo inspect "docker://{{registry}}/{{project}}/{{image}}:{{tag}}"
