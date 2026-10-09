#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo 'Expected devenv task input JSON.' >&2; exit 2; }
input_json=$1
before=$(jq -er '.before | strings | select(length > 0)' <<<"$input_json")
after=$(jq -er '.after | strings | select(length > 0)' <<<"$input_json")
[[ -f "$before/metadata.json" && -f "$before/results.json" ]] || { echo "Missing benchmark files in: $before" >&2; exit 2; }
[[ -f "$after/metadata.json" && -f "$after/results.json" ]] || { echo "Missing benchmark files in: $after" >&2; exit 2; }

before_command=$(jq -er '.command' "$before/metadata.json")
after_command=$(jq -er '.command' "$after/metadata.json")
[[ $before_command == "$after_command" ]] || { echo 'Refusing comparison: benchmark commands differ.' >&2; exit 1; }
for field in runs warmup; do
  before_value=$(jq -r ".$field" "$before/metadata.json")
  after_value=$(jq -r ".$field" "$after/metadata.json")
  [[ $before_value == "$after_value" ]] || { echo "Refusing comparison: $field differs." >&2; exit 1; }
done
before_host=$(jq -r '.host' "$before/metadata.json")
after_host=$(jq -r '.host' "$after/metadata.json")
[[ $before_host == "$after_host" ]] || { echo 'Refusing comparison: hosts differ.' >&2; exit 1; }

jq -nr \
  --arg beforeLabel "$(jq -r '.label' "$before/metadata.json")" \
  --arg afterLabel "$(jq -r '.label' "$after/metadata.json")" \
  --arg beforeSystem "$(jq -r '.currentSystem' "$before/metadata.json")" \
  --arg afterSystem "$(jq -r '.currentSystem' "$after/metadata.json")" \
  --arg beforeProfile "$(jq -r '.powerProfile' "$before/metadata.json")" \
  --arg afterProfile "$(jq -r '.powerProfile' "$after/metadata.json")" \
  --arg beforeAC "$(jq -r '.acOnline' "$before/metadata.json")" \
  --arg afterAC "$(jq -r '.acOnline' "$after/metadata.json")" \
  --slurpfile before "$before/results.json" \
  --slurpfile after "$after/results.json" '
  def median:
    sort as $values | ($values | length) as $length |
    if $length % 2 == 1 then $values[($length / 2 | floor)]
    else (($values[($length / 2 | floor) - 1] + $values[($length / 2 | floor)]) / 2) end;
  ($before[0].results[0].times | median) as $b |
  ($after[0].results[0].times | median) as $a |
  "benchmark: \($before[0].results[0].command)",
  "before (\($beforeLabel)): \($b) s median",
  "after  (\($afterLabel)): \($a) s median",
  (if $b == 0 then "change: unavailable" else "change: \(((($a - $b) / $b) * 10000 | round) / 100)% (positive is slower)" end),
  "system: \($beforeSystem) → \($afterSystem)",
  (if $beforeProfile == $afterProfile then "power profile: \($beforeProfile) (same)" else "WARNING: power profile changed: \($beforeProfile) → \($afterProfile)" end),
  (if $beforeAC == $afterAC then "AC online: \($beforeAC) (same)" else "WARNING: AC state changed: \($beforeAC) → \($afterAC)" end)
  ' 
