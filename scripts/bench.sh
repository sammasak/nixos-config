#!/usr/bin/env bash
# Eval-time benchmark + static readability metrics for this flake.
#
# Usage:
#   ./scripts/bench.sh bench    # full run, appends one JSON line to metrics/history.jsonl
#   ./scripts/bench.sh diff     # delta table for the last two entries
#   ./scripts/bench.sh parity   # eval drvPaths only, fail if they moved since the last entry
#
# Eval counters come from NIX_SHOW_STATS. Per the nixpkgs metrics.nix caveat
# they are only meaningful as a before/after diff for one change set, never as
# an absolute score.
set -euo pipefail

cd "$(dirname "$0")/.."

HOSTS=("lenovo" "acer-swift")
HISTORY="metrics/history.jsonl"

# Wall-clock milliseconds and the stats JSON for one host's toplevel drvPath.
# The eval cache is disabled so repeated runs actually re-evaluate.
eval_host() {
  local host=$1 statsfile=$2 start end drv
  start=$(date +%s%N)
  drv=$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$statsfile" \
    nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath" \
    --option eval-cache false)
  end=$(date +%s%N)
  printf '%s\t%s\n' "$(((end - start) / 1000000))" "$drv"
}

# files, total lines, comment lines, largest file, median file — over every
# .nix file in the worktree.
#
# A comment line is one whose first non-blank character is '#' AND which is not
# inside a Nix string. Both halves matter: trailing comments are deliberately
# not counted (the metric tracks standalone commentary), and the string check
# stops CSS id selectors in a `programs.waybar.style` block, or shell comments
# in an inline script, from being scored as Nix commentary.
static_metrics() {
  find . -name '*.nix' -not -path './.git/*' -print0 |
    xargs -0 gawk -f scripts/nix-comment-metrics.awk
}

cmd_bench() {
  local statsdir
  statsdir=$(mktemp -d)
  # shellcheck disable=SC2064  # expand statsdir now, not at trap time
  trap "rm -rf '$statsdir'" EXIT

  echo "Benchmarking flake evaluation (eval-cache disabled)..."
  local hostjson='{}'
  for host in "${HOSTS[@]}"; do
    echo "  evaluating $host ..."
    local ms drv
    IFS=$'\t' read -r ms drv < <(eval_host "$host" "$statsdir/$host.json")
    hostjson=$(jq \
      --arg host "$host" --arg drv "$drv" --argjson ms "$ms" \
      --slurpfile stats "$statsdir/$host.json" \
      '.[$host] = {
         drvPath: $drv,
         wallSeconds: ($ms / 1000),
         values: $stats[0].values.number,
         valueBytes: $stats[0].values.bytes,
         gcTotalBytes: $stats[0].gc.totalBytes,
         thunks: $stats[0].nrThunks,
         functionCalls: $stats[0].nrFunctionCalls
       }' <<<"$hostjson")
  done

  local files total comments maxlines p50lines
  IFS=$'\t' read -r files total comments maxlines p50lines < <(static_metrics)

  mkdir -p metrics
  jq -c -n \
    --arg sha "$(git rev-parse HEAD)" \
    --arg timestamp "$(date -Iseconds)" \
    --argjson files "$files" --argjson lines "$total" --argjson comments "$comments" \
    --argjson maxFileLines "$maxlines" --argjson p50FileLines "$p50lines" \
    --argjson hosts "$hostjson" \
    '{
       sha: $sha,
       timestamp: $timestamp,
       static: {
         files: $files,
         lines: $lines,
         comments: $comments,
         commentRatio: (($comments * 1000 / $lines | round) / 1000),
         maxFileLines: $maxFileLines,
         p50FileLines: $p50FileLines
       },
       hosts: $hosts
     }' >>"$HISTORY"

  tail -n 1 "$HISTORY" | jq .
  echo "Appended to $HISTORY"
}

require_history() {
  [ -s "$HISTORY" ] || {
    echo "no entries in $HISTORY — run 'just bench' first" >&2
    exit 1
  }
}

cmd_diff() {
  require_history
  local n
  n=$(wc -l <"$HISTORY")
  if [ "$n" -lt 2 ]; then
    echo "only $n entry in $HISTORY — nothing to diff yet"
    return 0
  fi
  tail -n 2 "$HISTORY" | jq -rs '
    def pct($a; $b):
      if $a == $b then "—"
      elif $a == 0 then "n/a"
      else (($b - $a) * 1000 / $a | round / 10 | tostring) + "%"
      end;
    def num($label; $a; $b): [$label, ($a | tostring), ($b | tostring), pct($a; $b)] | @tsv;
    def short: ltrimstr("/nix/store/") | .[0:12];
    def drv($label; $a; $b):
      [$label, ($a | short), ($b | short), (if $a == $b then "same" else "CHANGED" end)] | @tsv;
    .[0] as $a | .[1] as $b |
    [
      (["metric", "before", "after", "delta"] | @tsv),
      num("comment lines"; $a.static.comments; $b.static.comments),
      num("total lines"; $a.static.lines; $b.static.lines),
      num("comment ratio"; $a.static.commentRatio; $b.static.commentRatio),
      num("nix files"; $a.static.files; $b.static.files),
      num("max file lines"; $a.static.maxFileLines; $b.static.maxFileLines),
      num("p50 file lines"; $a.static.p50FileLines; $b.static.p50FileLines)
    ]
    + ([$b.hosts | keys[]] | map(. as $h | [
        num($h + " eval seconds"; $a.hosts[$h].wallSeconds; $b.hosts[$h].wallSeconds),
        num($h + " eval values"; $a.hosts[$h].values; $b.hosts[$h].values),
        num($h + " gc bytes"; $a.hosts[$h].gcTotalBytes; $b.hosts[$h].gcTotalBytes),
        drv($h + " drvPath"; $a.hosts[$h].drvPath; $b.hosts[$h].drvPath)
      ]) | add)
    | .[]
  ' | column -t -s $'\t'
  echo ""
  tail -n 2 "$HISTORY" | jq -rs '"\(.[0].sha[0:12]) (\(.[0].timestamp)) → \(.[1].sha[0:12]) (\(.[1].timestamp))"'
  echo "eval seconds are wall-clock and move with machine load; the values and"
  echo "gc-bytes counters are the load-independent measure of evaluation work."
}

cmd_parity() {
  require_history
  local rc=0 want got
  for host in "${HOSTS[@]}"; do
    want=$(tail -n 1 "$HISTORY" | jq -r --arg h "$host" '.hosts[$h].drvPath')
    got=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath" \
      --option eval-cache false)
    if [ "$want" = "$got" ]; then
      echo "✓ $host  $got"
    else
      echo "✗ $host  drvPath moved"
      echo "    recorded: $want"
      echo "    current:  $got"
      rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "Parity broken. Comments outside nix strings cannot change a derivation,"
    echo "so an unexpected break means an edit landed inside a string or heredoc."
  fi
  return "$rc"
}

case "${1:-bench}" in
  bench) cmd_bench ;;
  diff) cmd_diff ;;
  parity) cmd_parity ;;
  *)
    echo "usage: $0 {bench|diff|parity}" >&2
    exit 2
    ;;
esac
