# exec-pool on the queue's host as this user, whose peer login there is the submitter's (modules/homelab/exec-pool.nix).
# ssh hands that host's login shell (fish) one command line to re-split: each argument goes single-quoted, which fish
# and bash both read literally when it holds no ' or \ (refused), and the prompt goes on stdin as --prompt-file -.
# The exit is exec-pool's, or ssh's 255 when the connection failed (the outcome is unknown).
{
  lib,
  pkgs,
  poolHost,
}:
pkgs.writeShellApplication {
  name = "exec-pool";
  text = ''
    remote=(/run/current-system/sw/bin/exec-pool)
    prompt=""; piped=false; from=/dev/null
    quote() {
      case "$1" in *\'* | *\\*) echo "exec-pool: an argument holding ' or \\ cannot pass over ssh: $1" >&2; exit 2 ;; esac
      remote+=("'$1'")
    }
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --prompt ] && [ "$#" -ge 2 ]; then
        prompt=$2; piped=true; remote+=("'--prompt-file'" "'-'"); shift 2
      elif [ "$1" = --prompt-file ] && [ "$#" -ge 2 ]; then
        # a path is read here, not on the queue's host
        from=$2; [ "$from" = - ] && from=/dev/stdin; remote+=("'--prompt-file'" "'-'"); shift 2
      elif [[ "$1" == --* ]] && [ "$#" -ge 2 ]; then
        quote "$1"; quote "$2"; shift 2
      else
        quote "$1"; shift
      fi
    done
    ssh=(ssh -T -o BatchMode=yes -o ConnectTimeout=10 ${lib.escapeShellArg poolHost})
    if $piped; then
      printf '%s' "$prompt" | "''${ssh[@]}" "''${remote[@]}"
    else
      exec "''${ssh[@]}" "''${remote[@]}" < "$from"
    fi
  '';
}
