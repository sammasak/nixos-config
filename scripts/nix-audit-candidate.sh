#!/usr/bin/env bash
# Report-only nix-audit comparison of HOST's running system and its candidate,
# built here without activating it. Records every exit code and always exits 0:
# a verdict never blocks a switch or deploy. Usage: nix-audit-candidate.sh HOST [TARGET]
# TARGET is `local` (this machine) or an ssh destination; it defaults to HOST.
set -euo pipefail
trap 'echo "aborted (exit $?) at line $LINENO; partial evidence in ${run:-none}" >&2; exit 0' ERR

host=${1:?usage: nix-audit-candidate.sh HOST [TARGET]}
target=${2:-$host}
flake=$(cd "$(dirname "$0")/.." && pwd)
bin=$(command -v nix-audit) || { echo "nix-audit is not installed on this host" >&2; exit 0; }
policy=${NIX_AUDIT_POLICY:-$(dirname "$(readlink -f "$bin")")/../share/nix-audit/policy.toml}
lock=/tmp/$(hostname)-heavy-work.lock
rev=$(git -C "$flake" describe --always --dirty --abbrev=12 2>/dev/null || echo unknown)
run=$HOME/nix-audit-pilot/$(date +%F-%H%M)-$host-$rev
mkdir -p "$run"
cd "$run"

if [ "$target" = local ]; then
  baseline=$(readlink -f /run/current-system)
else
  baseline=$(ssh "$target" readlink -f /run/current-system) || {
    echo "cannot read the running system of $target over ssh" | tee note.txt
    exit 0
  }
fi
if ! nix-store --check-validity "$baseline" 2>/dev/null; then
  echo "baseline $baseline is not in this store; scan it on $target instead" | tee note.txt
  exit 0
fi

step() {
  local name=$1
  shift
  local code=0
  "$@" > "$name.out" 2> "$name.err" || code=$?
  echo "$code" > "$name.exit"
  echo "$name: exit $code"
}

nix-audit --version > version.txt 2>&1 || true
grype db status > grype-db.txt 2>&1 || true
step build flock "$lock" nix build --out-link candidate \
  "$flake#nixosConfigurations.$host.config.system.build.toplevel"
[ -e candidate ] || { echo "candidate did not build; see build.err"; exit 0; }
candidate=$(readlink -f candidate)
rm -f current.json candidate.json
step current flock "$lock" nix-audit scan "$baseline" --policy "$policy" --json-out current.json
step candidate flock "$lock" nix-audit scan "$candidate" --policy "$policy" --json-out candidate.json
if [ -s current.json ] && [ -s candidate.json ]; then
  step gate nix-audit diff current.json candidate.json --policy "$policy" --gate
  if [ "$(cat gate.exit)" = 3 ]; then
    step gate-grype nix-audit diff current.json candidate.json --scanners grype --policy "$policy" --gate
  fi
fi
echo "evidence in $run; record it per nix-audit docs/PILOT.md"
exit 0
