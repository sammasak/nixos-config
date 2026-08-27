#!/usr/bin/env bash
# Verify all NixOS host configurations build successfully before deploying.
#
# Usage:
#   ./scripts/verify-all-hosts.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Every host in the flake. The VM/image hosts (workstation-template,
# claude-worker-template) were retired with the KubeVirt platform, so there is
# no longer a second, optional build tier.
HOSTS=("acer-swift" "lenovo")

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

for host in "${HOSTS[@]}"; do
  # `set -e` would abort the loop on the first failure and skip the summary.
  build_host "$host" || true
done

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
