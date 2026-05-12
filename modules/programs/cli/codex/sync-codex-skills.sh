#!/usr/bin/env bash
set -euo pipefail

codex_skills_dir="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
shared_skills_dir="${SHARED_SKILLS_DIR:-$HOME/.agents/skills}"
repo_skills_dir="${REPO_SKILLS_DIR:-$HOME/claude-code-skills/skills}"
workflows_dir="${WORKFLOWS_DIR:-$HOME/workspace/workflows}"
manifest_file="$codex_skills_dir/.codex-generated.manifest"

mkdir -p "$codex_skills_dir"

new_manifest="$(mktemp)"
tmp_body="$(mktemp)"
trap 'rm -f "$new_manifest" "$tmp_body"' EXIT

declare -A workflow_names=()

strip_frontmatter() {
  local source_path="$1"
  awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
    !in_frontmatter { print }
  ' "$source_path"
}

prepare_body() {
  local source_path="$1"
  strip_frontmatter "$source_path" > "$tmp_body"
  if head -1 "$tmp_body" | grep -q '^<!-- export:skill -->$'; then
    tail -n +2 "$tmp_body" > "${tmp_body}.next"
    mv "${tmp_body}.next" "$tmp_body"
  fi
}

extract_description() {
  awk '
    /^[[:space:]]*$/ {
      if (collecting) {
        print description
        printed = 1
        exit
      }
      next
    }
    /^<!--/ { next }
    /^#/ {
      if (collecting) {
        print description
        printed = 1
        exit
      }
      next
    }
    {
      sub(/^[[:space:]]+/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      if (!collecting) {
        description = $0
        collecting = 1
        next
      }
      description = description " " $0
    }
    END {
      if (collecting && !printed) {
        print description
      }
    }
  ' "$tmp_body"
}

write_wrapper() {
  local skill_name="$1"
  local source_path="$2"
  local target_dir="$3"
  local description

  prepare_body "$source_path"
  description="$(extract_description)"
  if [ -z "$description" ]; then
    description="Codex wrapper for ${skill_name}."
  fi

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  {
    printf -- "---\nname: %s\ndescription: >-\n  %s\n---\n\n" "$skill_name" "$description"
    cat <<EOF
# Codex Compatibility Notes

Canonical source: \`$source_path\`

- The upstream instructions below are the source of truth for this workflow or skill.
- If the upstream text mentions Claude-specific tooling, the Task tool, or automatic subagent dispatch, translate that to Codex equivalents and only delegate when the user explicitly requested delegation.
- For browser automation, use the current \`mcp__playwright__browser_*\` tools even if the upstream text names an older Playwright tool prefix.
- Inside \`~/workspace\`, \`CLAUDE.md\` is the router and \`CONTEXT.md\` is the canonical room payload.

## Upstream Content

EOF
    cat "$tmp_body"
  } > "$target_dir/SKILL.md"

  printf '%s\n' "$skill_name" >> "$new_manifest"
}

if [ -f "$manifest_file" ]; then
  while IFS= read -r skill_name; do
    [ -z "$skill_name" ] && continue
    target_dir="$codex_skills_dir/$skill_name"
    if [ -d "$target_dir" ] && [ ! -L "$target_dir" ]; then
      rm -rf "$target_dir"
    fi
  done < "$manifest_file"
fi

if [ -d "$workflows_dir" ]; then
  while IFS= read -r workflow_dir; do
    skill_name="$(basename "$workflow_dir")"
    [ "$skill_name" = "hooks" ] && continue
    context_path="$workflow_dir/CONTEXT.md"
    [ -f "$context_path" ] || continue

    workflow_names["$skill_name"]=1
    write_wrapper "$skill_name" "$context_path" "$codex_skills_dir/$skill_name"
  done < <(find "$workflows_dir" -mindepth 1 -maxdepth 1 -type d | sort)
fi

if [ -d "$repo_skills_dir" ]; then
  while IFS= read -r skill_dir; do
    skill_name="$(basename "$skill_dir")"
    source_path="$skill_dir/SKILL.md"
    [ -f "$source_path" ] || continue
    [ -e "$shared_skills_dir/$skill_name" ] && continue
    [ -n "${workflow_names[$skill_name]:-}" ] && continue

    write_wrapper "$skill_name" "$source_path" "$codex_skills_dir/$skill_name"
  done < <(find "$repo_skills_dir" -mindepth 1 -maxdepth 1 -type d | sort)
fi

sort -u "$new_manifest" -o "$new_manifest"
mv "$new_manifest" "$manifest_file"

printf 'Synced %s Codex-local skills into %s\n' "$(wc -l < "$manifest_file")" "$codex_skills_dir"
