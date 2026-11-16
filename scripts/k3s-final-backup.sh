#!/usr/bin/env bash
# The last copy of every k3s local-path claim before the cluster goes (#422 step 3), run from lenovo by the coordinator
# right before the scale-to-0: each claim is streamed as a tarball from its node, gzip-tested, and listed with its
# sha256 in MANIFEST. A running database is copied crash-consistent (Authentik's was dumped at its cut-over).
# zot's images and the ollama models are skipped: both are re-fetchable. Nothing in k3s changes.
#   scripts/k3s-final-backup.sh [DIR]   default ~/.local/state/k3s-final/<stamp>
set -euo pipefail
# the claims hold Postgres data, session keys and tokens
umask 077
out=${1:-$HOME/.local/state/k3s-final/$(date +%Y%m%d-%H%M%S)}
skip='^(zot/zot-data|llm/ollama-msi-models)$'
mkdir -p "$out"

say() { printf '== %s\n' "$*"; }
mapfile -t claims < <(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-path")]}{.spec.claimRef.namespace} {.spec.claimRef.name} {.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]} {.spec.local.path}{"\n"}{end}')
[[ ${#claims[@]} -gt 0 ]] || { echo "no local-path claims listed: is kubectl pointed at the cluster?" >&2; exit 1; }

# lenovo's root disk is small: the raw size of what is kept, plus 2 GiB, must fit before anything is written
need=$((2 << 30))
for c in "${claims[@]}"; do
  read -r ns pvc node path <<<"$c"
  [[ $ns/$pvc =~ $skip ]] && continue
  need=$((need + $(ssh -o BatchMode=yes "deploy@$node" sudo -n du -sb "$path" | cut -f1)))
done
free=$(df --output=avail -B1 "$out" | tail -1)
((need < free)) || { echo "need $((need >> 20)) MiB in $out, $((free >> 20)) MiB free" >&2; exit 1; }

fail=0
for c in "${claims[@]}"; do
  read -r ns pvc node path <<<"$c"
  if [[ $ns/$pvc =~ $skip ]]; then
    say "skip $ns/$pvc (re-fetchable)"
    continue
  fi
  f=$out/${node}_${ns}_${pvc}.tar.gz
  say "$ns/$pvc from $node:$path"
  # --numeric-owner: the uids belong to the pods' images, not to any host user
  if ssh -o BatchMode=yes "deploy@$node" sudo -n tar --numeric-owner -C "$path" -czf - . >"$f" && gzip -t "$f"; then
    printf '%s  %s  %s files\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "${f##*/}" "$(tar -tzf "$f" | grep -vc '/$')" >>"$out/MANIFEST"
  else
    echo "FAILED: $ns/$pvc" >&2
    fail=1
  fi
done

say "manifest: $out/MANIFEST"
cat "$out/MANIFEST"
du -sh "$out"
exit "$fail"
