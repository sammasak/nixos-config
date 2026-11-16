#!/usr/bin/env bash
# Realise HOST's system.checks where its deploy builds (the target for remoteBuild nodes, here otherwise) and print,
# per check, whether it was built there or substituted, and the signatures it carries: a harmonia cache signs what it
# serves with its own key, so a signature names the store it came from, not the builder. A toplevel that is already valid or
# substitutable is fetched without its build inputs, so otherwise no check of a deploy need run or show for that host.
# Usage: scripts/system-checks.sh HOST [systemd-run property...] (the Justfile passes its memcap). Exits non-zero if a
# check is not a toplevel input or fails.
set -euo pipefail

host=${1:?usage: system-checks.sh HOST [systemd-run property...]}
shift
cap=(systemd-run --user --scope -q "$@")

eval_json() { "${cap[@]}" nix eval --json "$@"; }
plan=$(eval_json ".#nixosConfigurations.${host}.config.system" --apply \
  's: { top = s.build.toplevel.drvPath; checks = map (c: { inherit (c) name drvPath; out = c.outPath; }) s.checks; }')
node=$(eval_json ".#deploy.nodes.${host}" --apply 'n: { inherit (n) hostname; remoteBuild = n.profiles.system.remoteBuild or false; }')

top=$(jq -r .top <<<"$plan")
mapfile -t names < <(jq -r '.checks[].name' <<<"$plan")
mapfile -t drvs < <(jq -r '.checks[].drvPath' <<<"$plan")
mapfile -t outs < <(jq -r '.checks[].out' <<<"$plan")
if [ "${#drvs[@]}" -eq 0 ]; then
  echo "system-checks: ${host} declares no system.checks; every host has check-sshd-config at least" >&2
  exit 1
fi

inputs=$(nix derivation show "$top" | jq -r '.derivations[] | .inputs.drvs | keys[]')
for i in "${!drvs[@]}"; do
  if ! grep -qxF "$(basename "${drvs[$i]}")" <<<"$inputs"; then
    echo "system-checks: ${names[$i]} is not a build input of ${host}'s toplevel ${top}" >&2
    exit 1
  fi
done

if [ "$(jq -r .remoteBuild <<<"$node")" = true ]; then
  where=$(jq -r .hostname <<<"$node")
  export NIX_SSHOPTS="-o StrictHostKeyChecking=yes"
  on() { ssh -o StrictHostKeyChecking=yes "deploy@${where}" "$(printf '%q ' "$@")"; }
  nix copy --derivation --to "ssh-ng://deploy@${where}" "${drvs[@]}"
else
  where=$(uname -n)
  on() { "$@"; }
fi

before=$(on nix-store --check-validity --print-invalid "${outs[@]}")
echo "system-checks: realising ${#drvs[@]} check(s) of ${host} on ${where}"
on nix build --no-link "${drvs[@]/%/^*}"
missing=$(on nix-store --check-validity --print-invalid "${outs[@]}")
if [ -n "$missing" ]; then
  echo "system-checks: still not valid on ${where} after the build:" "$missing" >&2
  exit 1
fi
info=$(on nix path-info --json --json-format 1 "${outs[@]}")
for i in "${!outs[@]}"; do
  how=$(jq -r --arg p "${outs[$i]}" '.[$p] | if .ultimate then "built"
    elif .signatures == [] then "substituted, unsigned"
    else "substituted, signed by " + ([.signatures[] | split(":")[0]] | join(" ")) end' <<<"$info")
  if grep -qxF "${outs[$i]}" <<<"$before"; then how="$how now"; else how="already valid ($how earlier)"; fi
  printf '  %-36s %s on %s\n' "${names[$i]}" "$how" "$where"
done
