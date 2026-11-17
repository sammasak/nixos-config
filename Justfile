set shell := ["bash", "-euo", "pipefail", "-c"]

# nh selects by nixosConfigurations attribute, and lenovo's attribute is not its
# hostname, so the default cannot just be the hostname. `uname -n` rather than
# `hostname`: the latter arrives via nettools, which nothing here declares.
host := if `uname -n` == "lenovo-21CB001PMX" { "lenovo" } else { `uname -n` }
# The flake-pinned deploy-rs, so the recipes work outside the devenv shell.
deploy-rs := "nix run --inputs-from . deploy-rs --"
# The memory cap for heavy local work on lenovo: 7G, no swap.
memcap := "-p MemoryMax=7G -p MemorySwapMax=0"

# ── Build & Deploy ────────────────────────────────────────────────────

# --install-bootloader re-runs bootctl install every switch, syncing the ESP's
# systemd-boot binary to the running generation. nh's inline diff is dropped
# here; preview first with `just diff`. --sudo evaluates and builds as the user,
# whose SSH key fetches the private git+ssh inputs; only activation runs as root.
switch HOST=host:
    nixos-rebuild switch --sudo --flake .#{{HOST}} --install-bootloader

# Update one flake input (default: the Claude skills repo); pair with `just switch`
bump input='skills':
    nix flake update {{input}}

# Build this host's configuration without activating it
build HOST=host:
    nh os build . -H {{HOST}}

# Build and print the package diff against the running system
diff HOST=host:
    nh os build . -H {{HOST}} --diff always

# Report-only nix-audit comparison of HOST's running system and its candidate
# (built, not activated). Always exits 0; never call it from switch, deploy or CI.
audit-candidate HOST=host TARGET=(if HOST == host { "local" } else { HOST }):
    scripts/nix-audit-candidate.sh {{HOST}} {{TARGET}}

# Run from lenovo; logs in as `deploy` (key-only, passwordless sudo, so no
# prompt; homelab/deploy-target.nix). Rollback settings come from the node
# (flake-modules/deploy.nix); the host list is the table in
# flake-modules/hosts.nix, which the pattern repeats. --skip-checks:
# otherwise deploy-rs runs the full flake check first, building every x86 host
# on lenovo, which runs it out of memory. The pre-push gate runs that check on
# pushed non-docs commits, but `.#HOST` is the working tree, so the recipe
# refuses a dirty tree or a HEAD not on origin/main (a detached checkout of it
# passes).
# Break-glass: DEPLOY_UNGATED=1 just deploy HOST deploys it anyway, with a
# warning. A scope, not `capped`: it keeps the caller's environment,
# terminal and Ctrl-C. The cap covers the deploy-rs client and its evaluation;
# builds run in nix-daemon under its own limits. lenovo is a loopback
# self-push. msi: only Mon-Fri ~09:00-21:00. The Pis build their own closure:
# black-pi takes hours on a cache miss, so run it in zellij. The check after
# deploy-rs runs whatever deploy-rs returned, and the recipe keeps deploy-rs's
# exit code if it failed: it catches a host left degraded, a unit in a restart
# loop or the host not on the system profile's generation, which deploy-rs's own
# rollback does not judge (a unit that fails after activation reported success;
# scripts/post-deploy-check.sh, tests/post-deploy-check-vm.nix, scripts/test-deploy-recipes.py). It also lists
# condition-skipped units without failing. It rolls nothing back, and a host
# degraded for an unrelated reason fails every deploy until fixed.
[arg("HOST", pattern="lenovo|acer-swift|msi-ms7758|asus-b460m|black-pi|naked-pi")]
[doc("Push HOST with deploy-rs (magic rollback), skipping the flake check, under the memory cap, then check the host is running it")]
deploy HOST:
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then ungated="uncommitted changes"; \
      elif ! git merge-base --is-ancestor HEAD origin/main; then ungated="HEAD is not on origin/main (local ref)"; \
      else ungated=""; fi; \
      if [ -n "$ungated" ] && [ "${DEPLOY_UNGATED:-}" != 1 ]; then \
        echo "deploy: refused, $ungated: no gate checked this tree; commit and merge (then git fetch), or DEPLOY_UNGATED=1 to break glass" >&2; exit 1; fi; \
      [ -z "$ungated" ] || echo "WARNING: DEPLOY_UNGATED: deploying a tree no gate checked ($ungated)" >&2
    start=$SECONDS; sha=$(git rev-parse --short HEAD); log=$(mktemp); recorded=0; \
      rec() { recorded=1; scripts/platform-record.sh deploy node={{HOST}} result="$1" seconds=$((SECONDS - start)) \
        rolled_back="${2:-0}" units_restarted="${3:-0}" failed_units="${4:-unknown}" sha="$sha"; }; \
      trap '[ "$recorded" = 1 ] || rec interrupted; rm -f "$log"' EXIT; \
      scripts/system-checks.sh {{HOST}} {{memcap}} || { c=$?; rec checks-failed; exit "$c"; }; \
      rc=0; systemd-run --user --scope -q {{memcap}} {{deploy-rs}} .#{{HOST}} --skip-checks 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}; \
      rolled=0; if grep -q 'rolled back to previous generation' "$log"; then rolled=1; fi; \
      units=$(sed -n 's/.*restarting the following units: //p' "$log" | tr ',' '\n' | grep -c . || true); \
      check=255; target=$(nix eval --raw .#deploy.nodes.{{HOST}}.hostname) || target=""; \
      if [ -n "$target" ]; then check=0; timeout --foreground 300 ssh -o StrictHostKeyChecking=yes "deploy@$target" \
        'bash -s && [ "$(readlink /run/current-system)" = "$(dirname "$(readlink -f /nix/var/nix/profiles/system/init)")" ]' \
        < scripts/post-deploy-check.sh || check=$?; fi; \
      failed=unknown; if [ "$check" != 124 ] && [ "$check" != 255 ]; then failed=$(timeout 60 ssh -o StrictHostKeyChecking=yes "deploy@$target" \
        'systemctl --failed --no-legend --plain | wc -l' 2>/dev/null) || failed=unknown; fi; \
      case $check in \
        0) result=ok ;; \
        124|255) result=check-unreachable; echo "post-deploy check did not run on {{HOST}} (exit $check): timed out, unreachable, or no hostname" >&2 ;; \
        *) result=check-failed; echo "post-deploy check failed on {{HOST}} (exit $check): degraded, a unit in a restart loop, or not on the profile's generation; nothing was rolled back, see the lines above" >&2 ;; \
      esac; \
      [ "$rc" -eq 0 ] || result=deploy-failed; \
      rec "$result" "$rolled" "$units" "$failed"; \
      [ "$rc" -eq 0 ] || exit "$rc"; exit "$check"

# What `just deploy HOST` would do, without activating it: deploy-rs's
# --dry-activate runs `switch-to-configuration dry-activate` from the store
# path (no profile change, no confirmation wait, so none of magic rollback's
# paths), then the closure diff against the running system. One flag on the
# exact deploy path: same node list, ssh options and build placement; `just
# diff` only sees lenovo. deploy-rs ignores the dry activation's exit status
# ("Completed dry-activate!" proves nothing), so the recipe runs the same
# switch-to-configuration dry-activate once more over ssh, quiet unless it fails,
# and exits non-zero if it does (scripts/test-deploy-recipes.py). Not side effect
# free: the full build runs where a deploy builds (acer and the Pis on
# themselves, lenovo in nix-daemon outside the cap), the closure stays on the
# target without a GC root, and root runs the pre-switch checks and the dry
# activation scripts twice, through the same deploy-user sudo as a deploy. Not a
# guarantee: nothing is started, so a unit that would fail is not shown, and
# units an activation script restarts are only partly predicted.
[arg("HOST", pattern="lenovo|acer-swift|msi-ms7758|asus-b460m|black-pi|naked-pi")]
[doc("Show the units a deploy of HOST would stop, restart, reload or start, and its closure diff")]
dry-activate HOST:
    scripts/system-checks.sh {{HOST}} {{memcap}}
    systemd-run --user --scope -q {{memcap}} {{deploy-rs}} .#{{HOST}} --skip-checks --dry-activate
    top=$(systemd-run --user --scope -q {{memcap}} nix eval --raw .#nixosConfigurations.{{HOST}}.config.system.build.toplevel.outPath); \
      target=$(nix eval --raw .#deploy.nodes.{{HOST}}.hostname); \
      rc=0; out=$(ssh -o StrictHostKeyChecking=yes "deploy@$target" sudo "$top/bin/switch-to-configuration" dry-activate 2>&1) || rc=$?; \
      diff=0; ssh -o StrictHostKeyChecking=yes "deploy@$target" nix store diff-closures /run/current-system "$top" || diff=$?; \
      [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; echo "dry-activate: the dry activation of {{HOST}} failed (exit $rc), output above" >&2; exit 1; }; \
      [ "$diff" -eq 0 ] || { echo "dry-activate: the closure diff on {{HOST}} failed (exit $diff)" >&2; exit 1; }

# deploy and dry-activate run this first: a toplevel fetched from a store cache skips its build inputs, so without it
# no line shows that HOST's system.checks ran for this closure. Only the checks are realised, on the build host.
[arg("HOST", pattern="lenovo|acer-swift|msi-ms7758|asus-b460m|black-pi|naked-pi")]
[doc("Realise HOST's system.checks where its deploy builds, and print per check: built, or substituted and the signatures it carries")]
checks HOST:
    scripts/system-checks.sh {{HOST}} {{memcap}}

# Boot the runtime-host role in QEMU (tests/runtime-host-role-vm.nix); BREAK=1
# runs the copy with Home Manager's activation broken, which must fail. The plain
# test is also a flake check the gate boots; this recipe is for BREAK=1 and reruns.
# A host-sized build: msi only, not lenovo (memory).
[doc("Build and run the runtime-host role VM test (msi only); BREAK=1 must fail")]
role-vm-test BREAK="":
    [ "$(uname -n)" = msi-ms7758 ] || { echo "role-vm-test: run it on msi-ms7758, not $(uname -n)" >&2; exit 1; }
    nix build -L --no-link .#runtime-host-role-vm{{ if BREAK == "" { "" } else { ".broken" } }}

# ── Configuration Verification ────────────────────────────────────────

# QA gates live in devenv.nix as tasks; the git hooks run the same ones.
verify:
    devenv tasks run nixos:flake-check

lint-comments:
    devenv tasks run nixos:lint-comments

lint-shell:
    devenv tasks run nixos:lint-shell

secrets-verify:
    devenv tasks run nixos:secrets-verify

nvim-check:
    devenv tasks run nixos:nvim-check

check:
    devenv tasks run nixos:qa

# ── Metrics ───────────────────────────────────────────────────────────

# One evaluation run in a transient user unit under a 7G memory cap, no swap.
capped := "systemd-run --user --wait --collect --pipe -q " + memcap + " --working-directory=" + quote(justfile_directory())

# Measure eval time + static readability metrics, append to metrics/history.jsonl
bench:
    bash scripts/bench.sh bench

# Delta table between the last two metrics/history.jsonl entries
bench-diff:
    bash scripts/bench.sh diff

# Run this after a refactor that is meant to change nothing. Deliberately NOT part
# of `check` or `verify`: a change that legitimately moves the derivation should
# not fail the build gates. Runs under `capped`: needs a user systemd manager and
# does not inherit the caller's environment (no SSH agent, no NIX_CONFIG). The tree
# side sees tracked files incl. uncommitted edits, not untracked ones. Non-zero if
# any host toplevel or deploy node moved, was added or was removed, or any deploy
# setting outside nodes moved.
[doc("Compare every host's toplevel, deploy node and deploy settings at BASE (default: merge base with origin/main) with the working tree")]
parity BASE="":
    {{capped}} bash scripts/bench.sh parity {{quote(BASE)}}

# ── Editor ────────────────────────────────────────────────────────────

# Mirror dotfiles/nvim to the standalone public repo the work machine clones
export-nvim REMOTE="git@github.com:sammasak/nvim-config.git":
    bash scripts/export-nvim.sh {{REMOTE}}
