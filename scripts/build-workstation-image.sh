#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_NAME="${1:-workstation-template}"
FORMAT="${2:-kubevirt}"
OUT_LINK="${3:-result-${HOST_NAME}-${FORMAT}}"

cd "${ROOT_DIR}"

echo "Building ${HOST_NAME} as format=${FORMAT}"
nix run github:nix-community/nixos-generators -- \
  --flake "path:.#${HOST_NAME}" \
  --format "${FORMAT}" \
  --out-link "${OUT_LINK}"

echo "Build complete: ${ROOT_DIR}/${OUT_LINK}"
echo "Inspect output:"
echo "  ls -lah ${ROOT_DIR}/${OUT_LINK}"
