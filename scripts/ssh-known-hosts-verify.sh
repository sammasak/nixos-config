#!/usr/bin/env bash
# Re-check the pinned SSH host keys (modules/core/ssh-known-hosts.nix, nixos-config#86). github.com is compared with
# api.github.com/meta, the publisher. Each fleet host is checked two ways: offline, the pinned key's age form must be
# that host's recipient in secrets/.sops.yaml (the key it decrypts its secrets with: evidence independent of ssh);
# live, its /etc/ssh/ssh_host_ed25519_key.pub read over the pinned connection must equal the pin, a consistency
# check (a changed key makes the connection fail, which shows as UNREACHABLE). ssh-keyscan is never consulted.
# Exit 1 on any mismatch, 2 when something could not be checked, 0 when every check passed.
# Needs ssh-keygen, ssh-to-age, curl and jq on PATH.
set -euo pipefail
for tool in ssh-keygen ssh-to-age curl jq; do command -v "$tool" >/dev/null || { echo "UNCHECKED: $tool is not on PATH"; exit 2; }; done
here=$(cd "$(dirname "$0")/.." && pwd)
known="${KNOWN_HOSTS:-/etc/ssh/ssh_known_hosts}"; sops="$here/secrets/.sops.yaml"
hosts=("$@"); [ "${#hosts[@]}" -gt 0 ] || hosts=(lenovo-21CB001PMX acer-swift msi-ms7758 black-pi naked-pi)
rc=0
pinned() { { ssh-keygen -F "$1" -f "$known" 2>/dev/null || true; } | { grep -v '^#' || true; } | awk '$2 == "ssh-ed25519" {print $3; exit}'; }
fp() { printf 'ssh-ed25519 %s\n' "$1" | ssh-keygen -lf - | awk '{print $2}'; }
worse() { [ "$rc" -ge "$1" ] || rc=$1; }
gh_key=$(curl -fsS --max-time 15 https://api.github.com/meta 2>/dev/null | jq -r '.ssh_keys[] | select(startswith("ssh-ed25519 "))' | awk '{print $2}' || true)
pin=$(pinned github.com)
if [ -z "$pin" ]; then echo "UNCHECKED github.com: not pinned in $known"; worse 2
elif [ -z "$gh_key" ]; then echo "UNCHECKED github.com: api.github.com/meta did not answer (pinned $(fp "$pin"))"; worse 2
elif [ "$pin" = "$gh_key" ]; then echo "OK   github.com publisher $(fp "$pin")"
else echo "DIFF github.com pinned $pin publisher $gh_key"; worse 1; fi
for h in "${hosts[@]}"; do
  pin=$(pinned "$h")
  [ -n "$pin" ] || { echo "UNCHECKED $h: not pinned in $known"; worse 2; continue; }
  age=$(printf 'ssh-ed25519 %s\n' "$pin" | ssh-to-age) || { echo "UNCHECKED $h: ssh-to-age failed on the pinned key"; worse 2; continue; }
  if grep -Eq -- "- ${age}[[:space:]]+# ${h}\b" "$sops"; then echo "OK   $h sops-recipient $age"; else echo "DIFF $h: $age is not $h's recipient in secrets/.sops.yaml"; worse 1; fi
  if [ "$h" = "$(hostname)" ]; then live=$(awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub)
  else live=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "$h" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' || true); fi
  if [ -z "$live" ]; then echo "UNREACHABLE $h (pinned $(fp "$pin"); a changed key looks like this too)"; worse 2
  elif [ "$pin" = "$live" ]; then echo "OK   $h live $(fp "$pin")"
  else echo "DIFF $h pinned $pin live $live"; worse 1; fi
done
exit "$rc"
