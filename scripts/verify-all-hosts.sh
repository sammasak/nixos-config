#!/usr/bin/env bash
# Verify all NixOS host configurations build successfully before deploying.
#
# Usage:
#   ./scripts/verify-all-hosts.sh           # Build all physical hosts
#   ./scripts/verify-all-hosts.sh --all     # Build all hosts including VM images
set -euo pipefail

cd "$(dirname "$0")/.."

# Physical hosts that should always build
PHYSICAL_HOSTS=("acer-swift" "lenovo" "msi-ms7758")

# VM/image hosts (may have different requirements)
IMAGE_HOSTS=("workstation-template" "openfang-agent-template")

BUILD_ALL=false
if [[ "${1:-}" == "--all" ]]; then
  BUILD_ALL=true
fi

failed=()
succeeded=()

build_host() {
  local host=$1
  echo ""
  echo "=== Building $host ==="

  if nix build ".#nixosConfigurations.$host.config.system.build.toplevel" \
       --no-link --show-trace 2>&1 | tail -20; then
    echo "✓ $host built successfully"
    succeeded+=("$host")
    return 0
  else
    echo "✗ $host build failed"
    failed+=("$host")
    return 1
  fi
}

echo "Verifying NixOS host configurations..."
echo "========================================"

# Always build physical hosts
for host in "${PHYSICAL_HOSTS[@]}"; do
  build_host "$host"
done

# Optionally build image hosts
if $BUILD_ALL; then
  echo ""
  echo "Building VM/image hosts..."
  for host in "${IMAGE_HOSTS[@]}"; do
    build_host "$host" || true  # Don't fail on image build errors
  done
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Succeeded: ${#succeeded[@]} (${succeeded[*]:-none})"
echo "Failed: ${#failed[@]} (${failed[*]:-none})"

if [ ${#failed[@]} -eq 0 ]; then
  echo ""
  echo "✓ All required hosts built successfully"
  echo "  Safe to run: sudo nixos-rebuild switch --flake .#<hostname>"
  exit 0
else
  echo ""
  echo "✗ Some hosts failed to build"
  echo "  Review errors above before deploying"
  exit 1
fi
