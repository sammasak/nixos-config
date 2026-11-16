#!/usr/bin/env bash
# One platform-health record (Grafana "Platform health"): a logfmt line to Loki's {job="platform"} stream, kept 720h
# (loki.nix), and to a local spool. A failed push, or an unknown KIND, never fails the caller: the record is best effort
# evidence, and the spool shows what was not sent. Labels are KIND and this host only; callers put no path or secret
# in a value. KIND is one of the case list below, which scripts/test-platform-records.py holds the dashboard to.
# Loki is black-pi's fleet address (modules/core/fleet.nix, pinned by the test): the name resolves only on black-pi.
# Usage: platform-record.sh KIND key=value...
set -uo pipefail

kind=${1:?usage: platform-record.sh KIND key=value...}
shift
case $kind in
  gate | gate-step | deploy | checks-run | coverage | instructions | delivery) ;;
  *)
    echo "platform-record: unknown kind '$kind', nothing recorded" >&2
    exit 0
    ;;
esac

line="$*"
spool=${PLATFORM_RECORD_SPOOL:-${XDG_STATE_HOME:-$HOME/.local/state}/platform-records}
{ mkdir -p "$(dirname "$spool")" && printf '%s %s %s\n' "$(date -Is)" "$kind" "$line" >>"$spool" \
  && tail -n 2000 "$spool" >"$spool.$$" && mv -f "$spool.$$" "$spool"; } || true

# a Loki that did not answer in the last 5 min is not tried again: a gate writes dozens of records, and a dropped
# connection (a dev-environment guest, black-pi down) would otherwise cost each one its timeout
down="$spool.loki-down"
if [ -n "$(find "$down" -mmin -5 2>/dev/null)" ]; then
  echo "platform-record: Loki was unreachable within 5 min; the $kind record is only in $spool" >&2
  exit 0
fi

body=$(jq -cn --arg k "$kind" --arg h "$(uname -n)" --arg ts "$(date +%s%N)" --arg l "$line" \
  '{streams: [{stream: {job: "platform", kind: $k, host: $h}, values: [[$ts, $l]]}]}') || exit 0
if curl -fsS --connect-timeout 1 -m 3 -H 'Content-Type: application/json' --data "$body" \
  "${PLATFORM_LOKI_URL:-http://192.168.10.137:3100}/loki/api/v1/push" >/dev/null 2>&1; then
  rm -f "$down"
else
  touch "$down" 2>/dev/null || true
  echo "platform-record: Loki did not take the $kind record; it is in $spool" >&2
fi
exit 0
