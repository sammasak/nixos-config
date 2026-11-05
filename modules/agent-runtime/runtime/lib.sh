# Prepended to each tool by runtime.nix. Every failure ends stderr with one JSON
# line and the class fixes the exit code; a command that fails outside an explicit
# check is reported as `state` rather than dying silently.
set -E
exit_code() {
  case $1 in
    usage) echo 2 ;; plan) echo 3 ;; github) echo 4 ;; credential) echo 5 ;;
    store) echo 6 ;; budget) echo 7 ;; source) echo 8 ;; export) echo 9 ;;
    admission) echo 10 ;; ambiguous) echo 11 ;; conflict) echo 12 ;; unsupported) echo 13 ;; *) echo 1 ;;
  esac
}
# redact_stream SECRET: replace every literal occurrence of SECRET on stdin with <redacted> (fixed
# string, so a secret with regex/sed metacharacters is handled). Diagnostic use only, never artifacts.
redact_stream() {
  # ENVIRON, not -v: awk -v would interpret backslash escapes in the secret and miss it
  REDACT_SECRET=$1 awk 'BEGIN { s = ENVIRON["REDACT_SECRET"]; n = length(s) } { while (n > 0 && (p = index($0, s)) > 0) $0 = substr($0, 1, p - 1) "<redacted>" substr($0, p + n); print }'
}
# redact_file SECRET FILE: as redact_stream, applied in place to a file.
redact_file() {
  redact_stream "$1" <"$2" >"$2.redacted" && mv "$2.redacted" "$2"
}
fail() {
  trap - ERR
  jq -nc --arg class "$1" --arg message "$2" '{error: {class: $class, message: $message}}' >&2
  exit "$(exit_code "$1")"
}
trap 'fail state "unexpected failure: $BASH_COMMAND"' ERR
usage() { fail usage "usage: $USAGE"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
nix_cmd() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
# run_capture CLASS MESSAGE CMD...: stdout into $captured; a failure becomes CLASS
# with the token-redacted tail of stderr
run_capture() {
  local class=$1 message=$2 err detail rc=0
  shift 2
  err=$(mktemp)
  # shellcheck disable=SC2034  # read by the caller
  captured=$("$@" 2>"$err") || rc=$?
  detail=$(<"$err")
  rm -f "$err"
  [ -z "${GH_TOKEN:-}" ] || detail=${detail//"$GH_TOKEN"/<redacted>}
  detail=${detail//$'\n'/ }
  [ ${#detail} -le 400 ] || detail=${detail: -400}
  [ "$rc" -eq 0 ] || fail "$class" "$message: $detail"
}
# A scratch git repository for byte-exact tree objects: no user or system config,
# no ignore rules from outside the tree, no attribute or line-ending processing.
git_scratch() {
  export GIT_DIR=$1/.git GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0=/dev/null
  export GIT_CONFIG_KEY_1=core.autocrlf GIT_CONFIG_VALUE_1=false
  git init -q "$1"
  printf '* -text -eol -filter -ident\n' >"$GIT_DIR/info/attributes"
}
# tree_of VAR DIR [BASE]: the tree object of DIR. Without BASE every path counts.
# With BASE (a tree id) every path of BASE is taken from DIR whatever the ignore
# rules say, and only new paths are filtered, by BASE's own root .gitignore: a
# checkout cannot hide state by editing its ignore file.
tree_of() {
  local -n tree_out=$1
  local tree_dir=$2 base_tree=${3:-} excl
  rm -f "$GIT_DIR/index"
  if [ -z "$base_tree" ]; then
    GIT_WORK_TREE=$tree_dir git -C "$tree_dir" add -A -f
  else
    excl=$(mktemp)
    git cat-file -p "$base_tree:.gitignore" >"$excl" 2>/dev/null || : >"$excl"
    {
      GIT_WORK_TREE=$tree_dir git -C "$tree_dir" ls-files -o -z --exclude-from="$excl"
      git ls-tree -r --name-only -z "$base_tree"
    } | GIT_WORK_TREE=$tree_dir git -C "$tree_dir" update-index --add --remove -z --stdin
    rm -f "$excl"
  fi
  # shellcheck disable=SC2034  # the nameref target
  tree_out=$(git write-tree)
}
