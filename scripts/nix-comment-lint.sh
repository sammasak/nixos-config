#!/usr/bin/env bash
# Ratchet on the Comment Policy in CLAUDE.md. Two checks, both fatal:
#
#   1. density  — a .nix file of MIN_NIX_LINES or more nix-code lines may not
#                 exceed MAX_PERCENT comment lines. Counted by
#                 scripts/nix-comment-metrics.awk, so `''` string bodies (shell,
#                 waybar CSS) are excluded from BOTH the numerator and the gate
#                 — gating on physical lines instead would fail a ten-line
#                 module that happens to embed thirty lines of shell.
#   2. patterns — comment shapes the policy names as never-allowed, over .nix
#                 and .sh alike. A commented-out assignment is dead code in
#                 shell too, and the trigger scripts moved there in cycle 2.
#
# The pattern check is textual `grep`, not the awk scanner, so it also sees
# comments inside `''` strings and inside .sh files. That is deliberate. The
# cost is that a `#` line in a waybar CSS block is judged by the same rules.
set -euo pipefail

cd "$(dirname "$0")/.."

MAX_PERCENT=25
MIN_NIX_LINES=30

fail=0
report() {
  fail=1
  printf '%s\n' "$1" >&2
}

mapfile -d '' NIXFILES < <(find . -name '*.nix' -not -path './.git/*' -print0)
mapfile -d '' SHFILES < <(find . -name '*.sh' -not -path './.git/*' -print0)

# ── 1. density ────────────────────────────────────────────────────────
for f in "${NIXFILES[@]}"; do
  # Command substitution, not `< <(...)`: the awk's `verify=1` unbalanced-string
  # guard exits 2, and a process substitution's status is unobservable, so the
  # guard would be decorative and a mis-parsed file would read as clean.
  row=$(gawk -v verify=1 -f scripts/nix-comment-metrics.awk "$f")
  if [ "$(wc -l <<<"$row")" -ne 1 ]; then
    report "$f: metrics awk produced $(wc -l <<<"$row") rows, expected 1"
    continue
  fi
  IFS=$'\t' read -r _ _ nixlines comments _ _ <<<"$row"
  [ "$nixlines" -ge "$MIN_NIX_LINES" ] || continue
  if [ $((comments * 100)) -gt $((MAX_PERCENT * nixlines)) ]; then
    report "$f: $comments comment lines over $nixlines nix-code lines exceeds ${MAX_PERCENT}% — the file is narrating itself"
  fi
done

# ── 2. forbidden shapes ───────────────────────────────────────────────
# One `file:line:text` stream for every comment line. -H because grep drops the
# filename prefix when handed a single file, and the report would lose it.
COMMENTS=$(grep -HnE '^[[:space:]]*#' "${NIXFILES[@]}" "${SHFILES[@]}" || true)

# `See vault: <path>.md` is the policy's sanctioned pointer and its filename
# legitimately carries a date or an incident-report word that the rules below
# ban. Collapse the PATH ONLY, so a pointer cannot launder a dated narrative
# that shares its line.
PROSE=$(printf '%s\n' "$COMMENTS" | sed -E 's#See vault:[[:space:]]*[^[:space:]]*#See vault:#g')

rule() {
  local name=$1 stream=$2 pattern=$3 exempt=${4:-}
  local hits
  hits=$(printf '%s\n' "$stream" | { grep -iE "$pattern" || true; })
  if [ -n "$exempt" ]; then
    hits=$(printf '%s\n' "$hits" | { grep -ivE "$exempt" || true; })
  fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then report "$name: $line"; fi
  done <<<"$hits"
}

rule decision-log "$PROSE" 'DECISION[ :(]'
rule incident-history "$PROSE" 'postmortem|post-mortem'
rule undo-instructions "$PROSE" 'to restore|to revert|re-enable (it|this|by)|revert with'
# The policy allows a dated *revisit trigger* ("revisit after 2026-10-01 if X
# still breaks") — that is a consequence, not history. Everything else dated is.
rule bare-date "$PROSE" '[0-9]{4}-[0-9]{2}-[0-9]{2}' 'revisit'
# A trailing `;`, `{`, `[` or `(` is what separates a commented-out binding from
# prose that merely mentions `foo = bar`.
rule commented-out-binding "$COMMENTS" "^[^:]*:[0-9]+:[[:space:]]*#[[:space:]]*[a-zA-Z_][a-zA-Z0-9._'-]*[[:space:]]*=.*[;{[(][[:space:]]*$"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Comment Policy violations above. The policy is in CLAUDE.md; long" >&2
  echo "rationale goes to the knowledge vault and the code keeps one pointer." >&2
  exit 1
fi

echo "comment lint: ${#NIXFILES[@]} .nix + ${#SHFILES[@]} .sh files clean (density <=${MAX_PERCENT}%, no forbidden shapes)"
