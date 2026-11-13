set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"

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
# (flake-modules/70-deploy.nix), whose list the pattern repeats. --skip-checks:
# otherwise deploy-rs runs the full flake check first, building every x86 host
# on lenovo (the 2026-11-11 OOM). The pre-push gate runs that check on pushed
# non-docs commits, but `.#HOST` is the working tree: a dirty or unpushed tree
# deploys unchecked, so the recipe warns (never refuses: break-glass deploys
# are legitimate). A scope, not `capped`: it keeps the caller's environment,
# terminal and Ctrl-C. The cap covers the deploy-rs client and its evaluation;
# builds run in nix-daemon under its own limits. lenovo is a loopback
# self-push. msi: only Mon-Fri ~09:00-21:00. The Pis build their own closure:
# black-pi takes hours on a cache miss, so run it in zellij.
[arg("HOST", pattern="lenovo|acer-swift|msi-ms7758|black-pi|naked-pi")]
[doc("Push HOST with deploy-rs (magic rollback), skipping the flake check, under the memory cap")]
deploy HOST:
    [ -z "$(git status --porcelain --untracked-files=no)" ] || echo "WARNING: uncommitted changes; deploying a tree no gate checked" >&2
    git merge-base --is-ancestor HEAD origin/main || echo "WARNING: HEAD is not on origin/main (local ref); its flake check may never have run" >&2
    systemd-run --user --scope -q {{memcap}} {{deploy-rs}} .#{{HOST}} --skip-checks

# What `just deploy HOST` would do, without activating it: deploy-rs's
# --dry-activate runs `switch-to-configuration dry-activate` from the store
# path (no profile change, no confirmation wait, so none of magic rollback's
# paths), then the closure diff against the running system. One flag on the
# exact deploy path: same node list, ssh options and build placement; `just
# diff` only sees lenovo. Read the output: deploy-rs ignores the dry activation's
# exit status, so exit 0 and "Completed dry-activate!" prove nothing. Not side
# effect free: the full build runs where a deploy builds (acer and the Pis on
# themselves, lenovo in nix-daemon outside the cap), the closure stays on the
# target without a GC root, and root runs the pre-switch checks and the dry
# activation scripts, through the same deploy-user sudo as a deploy. Not a
# guarantee: nothing is started, so a unit that would fail is not shown, and
# units an activation script restarts are only partly predicted.
[arg("HOST", pattern="lenovo|acer-swift|msi-ms7758|black-pi|naked-pi")]
[doc("Show the units a deploy of HOST would stop, restart, reload or start, and its closure diff")]
dry-activate HOST:
    systemd-run --user --scope -q {{memcap}} {{deploy-rs}} .#{{HOST}} --skip-checks --dry-activate
    top=$(systemd-run --user --scope -q {{memcap}} nix eval --raw .#nixosConfigurations.{{HOST}}.config.system.build.toplevel.outPath) && \
      ssh -o StrictHostKeyChecking=yes "deploy@$(nix eval --raw .#deploy.nodes.{{HOST}}.hostname)" nix store diff-closures /run/current-system "$top"

# Boot the runtime-host role in QEMU (tests/runtime-host-role-vm.nix); BREAK=1
# runs the copy with Home Manager's activation broken, which must fail. A
# host-sized build: msi only, not lenovo (memory) nor acer (the only general worker).
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
# any host toplevel or deploy node moved, was added or was removed.
[doc("Compare every host's toplevel and deploy node at BASE (default: merge base with origin/main) with the working tree")]
parity BASE="":
    {{capped}} bash scripts/bench.sh parity {{quote(BASE)}}

# ── Editor ────────────────────────────────────────────────────────────

# Mirror dotfiles/nvim to the standalone public repo the work machine clones
export-nvim REMOTE="git@github.com:sammasak/nvim-config.git":
    bash scripts/export-nvim.sh {{REMOTE}}

# ── Registry ──────────────────────────────────────────────────────────

# Log in to the image registry (zot)
registry-login:
    nix shell nixpkgs#skopeo -c skopeo login {{registry}}

# ── Image Supply Chain Security ───────────────────────────────────────

[doc("Scan image for CRITICAL CVEs before publishing; non-zero if any are found")]
scan IMAGE:
    nix shell nixpkgs#trivy -c trivy image --exit-code 1 --severity CRITICAL {{IMAGE}}

[doc("Sign image with Cosign after publishing; needs SOPS-encrypted secrets/cosign.key")]
sign IMAGE:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPKEY=$(mktemp)
    trap "rm -f $TMPKEY" EXIT
    cd secrets && sops --decrypt cosign.key > "$TMPKEY"
    nix shell nixpkgs#cosign -c cosign sign --key "$TMPKEY" --yes {{IMAGE}}

# Generate SBOM and attach as OCI attestation
sbom IMAGE:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPKEY=$(mktemp)
    TMPSBOM=$(mktemp --suffix=.spdx.json)
    trap "rm -f $TMPKEY $TMPSBOM" EXIT
    cd secrets && sops --decrypt cosign.key > "$TMPKEY"
    nix shell nixpkgs#syft -c syft {{IMAGE}} -o spdx-json > "$TMPSBOM"
    nix shell nixpkgs#cosign -c cosign attest --key "$TMPKEY" --predicate "$TMPSBOM" --type spdx --yes {{IMAGE}}
