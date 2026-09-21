set shell := ["bash", "-euo", "pipefail", "-c"]

registry := "registry.sammasak.dev"

# nh selects by nixosConfigurations attribute, and lenovo's attribute is not its
# hostname, so the default cannot just be the hostname. `uname -n` rather than
# `hostname`: the latter arrives via nettools, which nothing here declares.
host := if `uname -n` == "lenovo-21CB001PMX" { "lenovo" } else { `uname -n` }

# ── Build & Deploy ────────────────────────────────────────────────────

# --install-bootloader re-runs bootctl install every switch, syncing the ESP's
# systemd-boot binary to the running generation. nh's inline diff is dropped
# here; preview first with `just diff`.
switch HOST=host:
    sudo nixos-rebuild switch --flake .#{{HOST}} --install-bootloader

# Build this host's configuration without activating it
build HOST=host:
    nh os build . -H {{HOST}}

# Build and print the package diff against the running system
diff HOST=host:
    nh os build . -H {{HOST}} --diff always

# Loopback self-push, proving the deploy-rs/sudo/magic-rollback path before it
# is ever trusted against acer-swift, which has no BMC to recover a bad push.
deploy-lenovo:
    deploy .#lenovo --auto-rollback --magic-rollback --activation-timeout 180 --confirm-timeout 30

# Pushes as lukas over SSH; acer's trusted-users=[root] accepts the closure via
# the deploy-rs signing key, not via SSH identity.
deploy-acer:
    deploy .#acer-swift --auto-rollback --magic-rollback --activation-timeout 180 --confirm-timeout 30

# ── Configuration Verification ────────────────────────────────────────

# Verify all host configurations build successfully
verify:
    bash scripts/verify-all-hosts.sh

# Enforce the CLAUDE.md Comment Policy: density ceiling + forbidden shapes
lint-comments:
    bash scripts/nix-comment-lint.sh

# The .sh files under modules/ are shellchecked by their writeShellApplication
# derivation; these are the ones nothing else would ever check.
[doc("Shellcheck the repo's own scripts (the ones no derivation builds)")]
lint-shell:
    nix shell nixpkgs#shellcheck -c shellcheck scripts/*.sh

[doc("Decrypt the wifi secret and assert SSID+PSK are sane, never printing them; skips without an age key")]
secrets-verify:
    nix shell nixpkgs#sops -c bash scripts/secrets-verify.sh

# Run flake checks (includes all configurations), both lints and the secrets gate
check: lint-comments lint-shell secrets-verify nvim-check
    nix flake check --all-systems --no-write-lock-file

# facter.json is gitignored, so this is the only gate that re-validates facter's
# actual contribution rather than the (always-safe) null path; there is no CI,
# so re-run by hand on lenovo after a hardware/BIOS change.
[doc("lenovo-only: regenerate facter.json in place, confirm the kernel-module union still covers the hand list")]
facter-check:
    #!/usr/bin/env bash
    set -euo pipefail
    cp hosts/lenovo-21CB001PMX/facter.json /tmp/facter-check.bak.json 2>/dev/null || true
    sudo "$(nix build '.#nixosConfigurations.lenovo.pkgs.nixos-facter' --no-link --print-out-paths)/bin/nixos-facter" \
      -o hosts/lenovo-21CB001PMX/facter.json
    nix eval '.#nixosConfigurations.lenovo.config.boot.initrd.availableKernelModules' --json \
      | nix shell nixpkgs#jq -c -- jq -e 'contains(["xhci_pci","thunderbolt","nvme","usb_storage","sd_mod"])' \
      > /dev/null && echo "OK: superset holds" \
      || echo "REGRESSION: hand list is no longer a subset of the facter-augmented union"
    [ -f /tmp/facter-check.bak.json ] && mv /tmp/facter-check.bak.json hosts/lenovo-21CB001PMX/facter.json || true

# ── Metrics ───────────────────────────────────────────────────────────

# Measure eval time + static readability metrics, append to metrics/history.jsonl
bench:
    bash scripts/bench.sh bench

# Delta table between the last two metrics/history.jsonl entries
bench-diff:
    bash scripts/bench.sh diff

# Run this after a refactor that is meant to change nothing. Deliberately NOT part
# of `check` or `verify`: a change that legitimately moves the derivation should
# not fail the build gates.
[doc("Compare both toplevel drvPaths against the last bench entry; non-zero if they moved")]
parity:
    bash scripts/bench.sh parity

# ── Editor ────────────────────────────────────────────────────────────

# Mirror dotfiles/nvim to the standalone public repo the work machine clones
export-nvim REMOTE="git@github.com:sammasak/nvim-config.git":
    bash scripts/export-nvim.sh {{REMOTE}}

# Build lenovo's nvim and confirm the config-as-written starts headless clean
nvim-check:
    #!/usr/bin/env bash
    set -euo pipefail
    hm='.#nixosConfigurations.lenovo.config.home-manager.users.lukas'
    NV=$(nix build "$hm.programs.neovim.finalPackage" --no-link --print-out-paths)
    # Isolated config from the generated files, not ~/.config/nvim: a plain +qa
    # against the live dir would exercise the deployed (possibly un-switched,
    # stale) generation and mask errors, since +qa exits 0 even on an init throw.
    cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
    mkdir -p "$cfg/nvim"
    ln -s "$PWD/dotfiles/nvim/lua" "$cfg/nvim/lua"
    ln -s "$PWD/dotfiles/nvim/lazy-lock.json" "$cfg/nvim/lazy-lock.json"
    nix eval --raw "$hm.xdg.configFile.\"nvim/init.lua\".text" > "$cfg/nvim/init.lua"
    nix eval --raw "$hm.xdg.configFile.\"nvim/nix.lua\".text" > "$cfg/nvim/nix.lua"
    out=$(XDG_CONFIG_HOME="$cfg" "$NV/bin/nvim" --headless +qa 2>&1 || true)
    if printf '%s' "$out" | grep -qiE 'error|stack traceback|E[0-9]{3,}:'; then
      printf '%s\n' "$out"; echo "nvim-check: startup errored" >&2; exit 1
    fi

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
