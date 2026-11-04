#!/usr/bin/env bash
# Re-verify the pinned SSH host keys (modules/core/ssh-known-hosts.nix, nixos-config#86) against their sources:
# github.com against api.github.com/meta, each fleet host against its own /etc/ssh/ssh_host_ed25519_key.pub read
# over the already pinned connection. Prints OK, DIFF or UNREACHABLE per host; exits 1 on any DIFF. ssh-keyscan is
# never consulted: a scan proves what a server says, not who it is.
set -euo pipefail
known="${KNOWN_HOSTS:-/etc/ssh/ssh_known_hosts}"
hosts=("$@"); [ "${#hosts[@]}" -gt 0 ] || hosts=(lenovo-21CB001PMX acer-swift msi-ms7758 black-pi)
rc=0
pinned() { ssh-keygen -F "$1" -f "$known" 2>/dev/null | grep -v '^#' | awk '$2 == "ssh-ed25519" {print $3; exit}'; }
report() { # <host> <pinned-key> <live-key|"">
  if [ -z "$3" ]; then printf 'UNREACHABLE %s (pinned %s)\n' "$1" "$(printf 'ssh-ed25519 %s\n' "$2" | ssh-keygen -lf - | awk '{print $2}')"
  elif [ "$2" = "$3" ]; then printf 'OK   %s %s\n' "$1" "$(printf 'ssh-ed25519 %s\n' "$2" | ssh-keygen -lf - | awk '{print $2}')"
  else printf 'DIFF %s pinned %s live %s\n' "$1" "$2" "$3"; rc=1; fi
}
gh_key=$(curl -fsS --max-time 15 https://api.github.com/meta 2>/dev/null | jq -r '.ssh_keys[] | select(startswith("ssh-ed25519 "))' | awk '{print $2}' || true)
report github.com "$(pinned github.com)" "$gh_key"
for h in "${hosts[@]}"; do
  if [ "$h" = "$(hostname)" ]; then live=$(awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub)
  else live=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "$h" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' || true); fi
  report "$h" "$(pinned "$h")" "$live"
done
exit "$rc"
