#!/usr/bin/env bash
# Publish a qcow2 image as an OCI containerDisk to Harbor.
#
# Usage: publish-oci-image.sh <result-dir> <registry> <project> <image> <tag>
set -euo pipefail

result_dir="$1"
registry="$2"
project="$3"
image="$4"
tag="$5"

qcow2=$(ls "$result_dir"/*.qcow2 2>/dev/null | head -1)
if [[ -z "$qcow2" ]]; then
  echo "ERROR: no qcow2 found in $result_dir"
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
dest="$registry/$project/$image"
# Harbor credentials — prefer env vars; fall back to ~/.config/containers/auth.json
if [[ -n "${HARBOR_ADMIN_USER:-}" ]]; then
  harbor_user="$HARBOR_ADMIN_USER"
  harbor_pass="${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD must be set when HARBOR_ADMIN_USER is set}"
else
  auth_file="${XDG_CONFIG_HOME:-$HOME/.config}/containers/auth.json"
  auth_encoded=$(jq -r --arg reg "$registry" '.auths[$reg].auth // empty' "$auth_file" 2>/dev/null || true)
  if [[ -n "$auth_encoded" ]]; then
    harbor_user=$(echo "$auth_encoded" | base64 -d | cut -d: -f1)
    harbor_pass=$(echo "$auth_encoded" | base64 -d | cut -d: -f2-)
  else
    echo "ERROR: no credentials for $registry. Set HARBOR_ADMIN_USER/HARBOR_ADMIN_PASSWORD or run: skopeo login $registry"
    exit 1
  fi
fi

echo "Pushing to $dest:$tag ..."
nix shell nixpkgs#skopeo -c skopeo copy \
  --dest-creds "$harbor_user:$harbor_pass" \
  "oci:$ocidir" "docker://$dest:$tag"
echo "Tagging as latest..."
nix shell nixpkgs#skopeo -c skopeo copy \
  --src-creds "$harbor_user:$harbor_pass" \
  --dest-creds "$harbor_user:$harbor_pass" \
  "docker://$dest:$tag" "docker://$dest:latest"
echo "Done: $dest:$tag (also tagged latest)"
