#!/usr/bin/env bash
# Move Authentik from k3s to acer's native units (#421), run from lenovo by the coordinator: every step is checked and
# a mismatch aborts into the rollback. Sign-in is down from step 1 until step 6. Nothing in k3s is deleted: the
# Postgres claim stays as it was, and the dump is kept on lenovo and acer.
#   scripts/authentik-cutover.sh            the cut-over
#   scripts/authentik-cutover.sh rollback   stop the native units and bring the k3s pods back
set -Eeuo pipefail
# the dump holds password hashes, tokens and OAuth client secrets
umask 077
acer=deploy@acer-swift
ns=authentik
stamp=$(date +%Y%m%d-%H%M%S)
dump=/var/tmp/authentik-cutover-$stamp.sql.gz
tables=(authentik_core_user authentik_core_group authentik_core_application authentik_core_token
  authentik_providers_oauth2_oauth2provider authentik_providers_proxy_proxyprovider authentik_flows_flow
  authentik_flows_stage authentik_outposts_outpost authentik_brands_brand authentik_core_session
  authentik_core_authenticatedsession authentik_providers_proxy_proxysession)

say() { printf '\n== %s\n' "$*"; }
on_acer() { ssh -o BatchMode=yes "$acer" sudo -n "$@"; }
k3s_sql() { trap - ERR; kubectl -n "$ns" exec deploy/authentik-postgres -- psql -U authentik -d authentik -tAc "$1"; }
# SQL on stdin: ssh joins its arguments into one shell line, which would re-split and mangle the query
native_sql() { trap - ERR; on_acer -u authentik psql -h /run/postgresql -d authentik -tA <<<"$1"; }
counts() { trap - ERR; local q; for t in "${tables[@]}"; do q+="SELECT '$t', count(*) FROM $t UNION ALL "; done; "$1" "${q% UNION ALL } ORDER BY 1"; }

rollback() {
  trap - ERR INT TERM HUP
  say "rollback: native units stop, k3s comes back on its untouched claim"
  on_acer systemctl stop authentik authentik-worker authentik-migrate || true
  # set the restored copy aside (kept): the units' gate then finds an empty database again after a reboot or switch,
  # so native Authentik cannot come back on stale data ahead of k3s
  if on_acer -u postgres psql -h /run/postgresql -tA <<<"SELECT 1 FROM pg_database WHERE datname = 'authentik'" | grep -q 1; then
    on_acer -u postgres psql -h /run/postgresql -v ON_ERROR_STOP=1 <<<"ALTER DATABASE authentik RENAME TO authentik_rolledback_$stamp" || true
    on_acer systemctl restart postgresql-setup.service || true
  fi
  flux resume helmrelease authentik -n "$ns" || true
  kubectl -n "$ns" scale deploy/authentik-server deploy/authentik-worker --replicas=1
  kubectl -n "$ns" patch cronjob authentik-postgres-backup authentik-postgres-backup-offnode -p '{"spec":{"suspend":false}}'
  kubectl -n "$ns" rollout status deploy/authentik-server --timeout=300s
  echo "k3s Authentik is back; Caddy falls back to it once the native port refuses (fail_duration 10s)."
}
abort() { echo "ABORT: $*" >&2; rollback; exit 1; }

if [[ ${1:-} == rollback ]]; then rollback; exit 0; fi

say "0. preflight"
on_acer test -s /run/secrets/authentik/secret_key || { echo "acer has no authentik secret; deploy the PR first" >&2; exit 1; }
on_acer systemctl is-active --quiet postgresql || { echo "acer's postgresql is not running" >&2; exit 1; }
n=$(native_sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
[[ $n == 0 ]] || { echo "acer's authentik database is not empty ($n tables): not restoring over it" >&2; exit 1; }
kubectl -n "$ns" rollout status deploy/authentik-server --timeout=30s

# from here on any failure rolls back, not just a failed check
# and so does a dropped session or ^C, which would otherwise leave k3s at 0
trap 'echo "ABORT: a step failed (line $LINENO)" >&2; rollback; exit 1' ERR
# a dropped session has no tty left: the rollback writes to a log beside the dump instead, so it does not die mid-way
trap 'exec >>"$dump.log" 2>&1 </dev/null; echo "ABORT: interrupted"; rollback; exit 1' INT TERM HUP

say "1. stop the k3s Authentik (sign-in is down from here)"
flux suspend helmrelease authentik -n "$ns"
kubectl -n "$ns" patch cronjob authentik-postgres-backup authentik-postgres-backup-offnode -p '{"spec":{"suspend":true}}'
kubectl -n "$ns" scale deploy/authentik-server deploy/authentik-worker --replicas=0
kubectl -n "$ns" wait --for=delete pod -l app.kubernetes.io/instance=authentik --timeout=120s || abort "pods did not stop"

say "2. final dump, kept on lenovo and copied to acer"
kubectl -n "$ns" exec deploy/authentik-postgres -- pg_dump -U authentik --no-owner --no-privileges authentik | gzip >"$dump"
gzip -t "$dump" && [[ $(stat -c %s "$dump") -gt 1000000 ]] || abort "the dump is broken or too small: $dump"
ext=$(zcat "$dump" | grep -c '^CREATE EXTENSION' || true)
[[ $ext == 0 ]] || abort "the dump creates $ext extension(s), which the authentik role cannot"
ssh -o BatchMode=yes "$acer" "umask 077; cat > $dump" <"$dump"
source=$(counts k3s_sql) || abort "could not count the k3s tables"
echo "$source"

say "3. restore as the authentik role, in one transaction"
zcat "$dump" | on_acer -u authentik psql -h /run/postgresql -d authentik -1 -v ON_ERROR_STOP=1 -q >/dev/null || abort "the restore failed"
restored=$(counts native_sql) || abort "could not count the restored tables"
[[ $restored == "$source" ]] || abort "row counts differ: $(diff <(echo "$source") <(echo "$restored") || true)"
host=$(native_sql "SELECT _config->>'authentik_host' FROM authentik_outposts_outpost WHERE name = 'authentik Embedded Outpost'") || abort "could not read the outpost"
[[ $host == https://auth.sammasak.dev/ ]] || abort "the embedded outpost's authentik_host is '$host'"

say "4. start the native units (migrate: 2026.2.3 to 2026.5.6)"
on_acer systemctl start authentik-migrate authentik-worker authentik || abort "the native units did not start"
for _ in $(seq 60); do on_acer curl -fsS -o /dev/null http://127.0.0.1:9000/-/health/ready/ && break; sleep 5; done
on_acer curl -fsS -o /dev/null http://127.0.0.1:9000/-/health/ready/ || abort "the native server is not ready after 5 minutes"

say "5. through Caddy, as a client would (acer's address, whatever DNS says)"
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve auth.sammasak.dev:443:192.168.10.110 https://auth.sammasak.dev/-/health/live/)
[[ $code == 200 || $code == 204 ]] || abort "auth.sammasak.dev answers $code"
loc=$(curl -s -o /dev/null -w '%{redirect_url}' --resolve chat.sammasak.dev:443:192.168.10.110 https://chat.sammasak.dev/)
[[ $loc == https://auth.sammasak.dev/* ]] || abort "an unauthenticated chat request is not sent to Authentik ($loc)"

trap - ERR INT TERM HUP
say "6. done: sign in at auth, chat and grafana by hand; the dump is $dump on lenovo and acer"
