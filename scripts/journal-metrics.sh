#!/usr/bin/env bash
set -euo pipefail

directory=${1:?usage: journal-metrics.sh DIRECTORY URL}
url=${2:?usage: journal-metrics.sh DIRECTORY URL}
umask 022
input=$(mktemp "$directory/.journal-input.XXXXXX")
output=$(mktemp "$directory/.journal-output.XXXXXX")
trap 'rm -f "$input" "$output"' EXIT
success=0

if curl -fsS --max-time 5 --max-filesize 262144 "$url" -o "$input" && LC_ALL=C awk '
  function emit(name, value, reason, key) {
    key = name (reason == "" ? "" : "{reason=\"" reason "\"}")
    values[key] += value
  }
  /^loki_(source_journal_target_lines_total|write_(sent_entries|batch_retries|dropped_entries)_total|process_dropped_lines_total)\{/ {
    if (!match($1, /^([a-z_]+)\{(.*)\}$/, fields)) { bad = 1; next }
    name = fields[1]; labels = fields[2]
    component = name ~ /^loki_source/ ? "loki.source.journal.host" : (name ~ /^loki_write/ ? "loki.write.loki" : "loki.process.drop")
    if (!match(labels, /(^|,)component_id="([^"]+)"(,|$)/, identity) || identity[2] != component) next
    if (NF != 2 || $2 !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ || $2 + 0 > 1e30) { bad = 1; next }
    reason = ""
    if (name ~ /dropped/) {
      if (!match(labels, /(^|,)reason="([a-z_]+)"(,|$)/, why)) { bad = 1; next }
      reason = why[2]
    }
    if (seen[name SUBSEP reason]++) { bad = 1; next }
    if (name == "loki_source_journal_target_lines_total") {
      reader = 1; emit("homelab_journal_reader_lines_total", $2, "")
    } else if (name == "loki_write_sent_entries_total") {
      sent = 1; emit("homelab_journal_writer_sent_entries_total", $2, "")
    } else if (name == "loki_write_batch_retries_total") {
      retries = 1; emit("homelab_journal_writer_retries_total", $2, "")
    } else if (name == "loki_write_dropped_entries_total") {
      dropped = 1
      if (reason !~ /^(ingester_error|line_too_long|queue_is_full|rate_limited|stream_limited)$/) reason = "other"
      emit("homelab_journal_writer_dropped_entries_total", $2, reason)
    } else {
      if (reason !~ /^(private_unit|ak_command|loki_query_log|loki_table_lookup|egress_access_log)$/) reason = "other"
      emit("homelab_journal_filtered_lines_total", $2, reason)
    }
  }
  END {
    if (bad || !reader || !sent || !retries || !dropped) exit 1
    print "# HELP homelab_journal_reader_lines_total Journal entries read before filtering."
    print "# TYPE homelab_journal_reader_lines_total counter"
    print "# HELP homelab_journal_writer_sent_entries_total Journal entries successfully sent to Loki."
    print "# TYPE homelab_journal_writer_sent_entries_total counter"
    print "# HELP homelab_journal_writer_retries_total Journal export batch retries."
    print "# TYPE homelab_journal_writer_retries_total counter"
    print "# HELP homelab_journal_writer_dropped_entries_total Journal entries dropped by the export writer."
    print "# TYPE homelab_journal_writer_dropped_entries_total counter"
    print "# HELP homelab_journal_filtered_lines_total Journal entries deliberately filtered before export."
    print "# TYPE homelab_journal_filtered_lines_total counter"
    for (key in values) printf "%s %.17g\n", key, values[key]
  }
' "$input" > "$output"; then
  success=1
else
  # Do not leave old counter values looking freshly collected after a failed scrape or schema change.
  : > "$output"
  echo 'journal-metrics: loopback collection failed' >&2
fi
{
  echo '# HELP homelab_journal_metrics_collection_success Whether the last loopback counter collection succeeded.'
  echo '# TYPE homelab_journal_metrics_collection_success gauge'
  echo "homelab_journal_metrics_collection_success $success"
  echo '# HELP homelab_journal_metrics_collection_timestamp_seconds Unix time of the last collection attempt, not delivery.'
  echo '# TYPE homelab_journal_metrics_collection_timestamp_seconds gauge'
  echo "homelab_journal_metrics_collection_timestamp_seconds $(date +%s)"
} >> "$output"
chmod 0644 "$output"
mv -f "$output" "$directory/journal.prom"
[ "$success" = 1 ]
