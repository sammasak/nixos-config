#!/usr/bin/env bash
# Ratchet on the Comment Policy in CLAUDE.md. Two checks, both fatal:
#
#   1. density  — a .nix file of MIN_LINES or more may not exceed MAX_PERCENT
#                 comment lines. Counted by scripts/nix-comment-metrics.awk, so
#                 `''` string bodies (shell, waybar CSS) are excluded from both
#                 sides of the fraction and cannot skew a file either way.
#   2. patterns — comment shapes the policy names as never-allowed.
#
# The pattern check is textual `grep`, not the awk scanner, so it also sees
# comments inside `''` strings. That is deliberate: a commented-out assignment
# is dead code in shell too. The cost is that a `#` line in a waybar CSS block
# is judged by the same rules.
set -euo pipefail

cd "$(dirname "$0")/.."

MAX_PERCENT=25
MIN_LINES=30

fail=0
report() {
  fail=1
  printf '%s\n' "$1" >&2
}

mapfile -d '' NIXFILES < <(find . -name '*.nix' -not -path './.git/*' -print0)

for f in "${NIXFILES[@]}"; do
  IFS=$'\t' read -r _ lines nixlines comments _ _ \
    < <(gawk -v verify=1 -f scripts/nix-comment-metrics.awk "$f")
  [ "$lines" -ge "$MIN_LINES" ] || continue
  [ "$nixlines" -gt 0 ] || continue
  if [ $((comments * 100)) -gt $((MAX_PERCENT * nixlines)) ]; then
    report "$f: $comments comment lines over $nixlines nix-code lines exceeds ${MAX_PERCENT}% — the file is narrating itself"
  fi
done

# `See vault: <path>.md` is the policy's sanctioned pointer, and vault filenames
# legitimately carry dates and the word postmortem. Exempt from the two prose
# rules that would otherwise fire on the path itself.
grep_rule() {
  local rule=$1 pattern=$2 exempt=${3:-}
  local hits
  hits=$(grep -nE "$pattern" "${NIXFILES[@]}" || true)
  if [ -n "$exempt" ]; then
    hits=$(printf '%s\n' "$hits" | { grep -v "$exempt" || true; })
  fi
  [ -n "$hits" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && report "$rule: $line"
  done <<<"$hits"
}

grep_rule "decision-log" '^[[:space:]]*#.*DECISION \('
grep_rule "incident-history" '^[[:space:]]*#.*postmortem' 'See vault:'
grep_rule "undo-instructions" '^[[:space:]]*#.*To restore'
grep_rule "bare-date" '^[[:space:]]*#.*[0-9]{4}-[0-9]{2}-[0-9]{2}' 'See vault:'
grep_rule "commented-out-binding" "^[[:space:]]*#[[:space:]]*[a-zA-Z_][a-zA-Z0-9._'-]*[[:space:]]*=.*[;{][[:space:]]*$"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Comment Policy violations above. The policy is in CLAUDE.md; long" >&2
  echo "rationale goes to the knowledge vault and the code keeps one pointer." >&2
  exit 1
fi

echo "comment lint: ${#NIXFILES[@]} .nix files clean (density <=${MAX_PERCENT}%, no forbidden shapes)"
