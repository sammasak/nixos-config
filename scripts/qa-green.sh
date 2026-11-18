#!/usr/bin/env bash
# A manual nixos:qa's green, written where and as qaPush writes its own (devenv.nix: a line "tree gate generation" in
# the common git dir's nixos-qa-green), so pushing that tree afterwards runs the lints only. Recorded only for what the
# gate saw: a clean checkout (nothing staged, modified or untracked) whose HEAD tree, cleanliness and system
# generation are the same at the end as at the start, run as its store path (the key qaPush looks up).
#   qa-green.sh begin                           prints the state at the start: tree, generation, clean|dirty
#   qa-green.sh record GATE RESULT MODE STATE  records GATE's green for that state when RESULT is pass and MODE is
#                                              manual (qaPush records its own run), or says why it does not
# Tracked files only: what .gitignore hides (.devenv, result links) is not compared; a git flake does not see it.
# QA_SYSTEM overrides /run/current-system and QA_GATE_PREFIX /nix/store/, for scripts/test-qa-push.py.
set -euo pipefail

sys=${QA_SYSTEM:-/run/current-system}
state() {
  local clean=clean
  # git status cannot vouch for files it is told to skip (skip-worktree, assume-unchanged) or a sparse checkout
  if [ -n "$(git status --porcelain --untracked-files=all)" ] || git ls-files -v | grep -q '^[a-zS]' \
    || [ "$(git config --bool core.sparseCheckout || true)" = true ] || [ -n "${GIT_DIR:-}${GIT_WORK_TREE:-}" ]; then
    clean=dirty
  fi
  echo "$(git rev-parse 'HEAD^{tree}') $(readlink -f "$sys") $clean"
}

case ${1:-} in
  begin) state ;;
  record)
    [ "$#" -ge 5 ] || { echo "usage: qa-green.sh record GATE RESULT MODE STATE" >&2; exit 2; }
    gate=$2 result=$3 mode=$4
    shift 4
    begin="$*"
    now=$(state)
    read -r tree gen clean <<<"$begin"
    why=
    if [ "$result" != pass ]; then
      why="the gate did not pass ($result)"
    elif [ "$mode" != manual ]; then
      why="this is the hook's run ($mode), which records itself"
    elif [[ $gate != "${QA_GATE_PREFIX:-/nix/store/}"* ]]; then
      why="it ran as $gate, not as its store path"
    elif [ "$clean" != clean ]; then
      why="the checkout had changes no commit holds"
    elif [ "$now" != "$begin" ]; then
      why="the checkout, its HEAD or the system generation changed during the run ($begin, now $now)"
    fi
    if [ -n "$why" ]; then
      echo "nixos-qa: green not recorded for the pre-push hook: $why" >&2
      exit 0
    fi
    green=$(git rev-parse --path-format=absolute --git-common-dir)/nixos-qa-green
    if { echo "$tree $gate $gen" >>"$green" && tail -n 50 "$green" >"$green.$$" && mv "$green.$$" "$green"; } 2>/dev/null; then
      echo "nixos-qa: tree ${tree:0:12} recorded green: a push of it runs the lints only"
    else
      rm -f "$green.$$"
      echo "nixos-qa: green tree not recorded in $green" >&2
    fi
    ;;
  *)
    echo "usage: qa-green.sh begin | record GATE RESULT MODE STATE" >&2
    exit 2
    ;;
esac
