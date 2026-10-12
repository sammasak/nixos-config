{ pkgs, lib, inputs, ... }:

let
  gate = name: runtimeInputs: text: pkgs.writeShellApplication { inherit name runtimeInputs text; };

  lintComments = gate "nixos-lint-comments" (with pkgs; [ bash git gawk gnugrep gnused findutils coreutils ]) ''
    bash scripts/nix-comment-lint.sh
  '';

  lintShell = gate "nixos-lint-shell" [ pkgs.shellcheck ] ''
    shellcheck scripts/*.sh
  '';

  # Skips (exit 0) on hosts without the age key; only lenovo enforces it.
  secretsVerify = gate "nixos-secrets-verify" (with pkgs; [ bash sops age gawk gnugrep gnused coreutils ]) ''
    bash scripts/secrets-verify.sh
  '';

  # Isolated config from the generated files, not ~/.config/nvim: +qa against
  # the live dir would exercise the deployed (possibly stale) generation and
  # mask errors, since +qa exits 0 even on an init throw.
  nvimCheck = gate "nixos-nvim-check" (with pkgs; [ nix gnugrep coreutils ]) ''
    hm='.#nixosConfigurations.lenovo.config.home-manager.users.lukas'
    NV=$(nix build "$hm.programs.neovim.finalPackage" --no-link --print-out-paths)
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
  '';

  flakeCheck = gate "nixos-flake-check" [ pkgs.nix ] ''
    nix flake check --all-systems --no-write-lock-file
  '';

  verifyHosts = gate "nixos-verify" (with pkgs; [ bash nix coreutils ]) ''
    bash scripts/verify-all-hosts.sh
  '';

  qa = gate "nixos-qa" [ ] (lib.concatMapStringsSep "\n" lib.getExe [
    lintComments lintShell secretsVerify nvimCheck flakeCheck verifyHosts
  ]);

  # Runs the full gate on the PUSHED commit in a throwaway worktree, so neither
  # unstaged edits nor a different checked-out branch can make it pass.
  # prek exposes only the first ref of a multi-ref push.
  qaPush = gate "nixos-qa-push" [ pkgs.git pkgs.coreutils ] ''
    rev=''${PRE_COMMIT_TO_REF:-HEAD}
    case $rev in 0000000000000000000000000000000000000000) exit 0 ;; esac
    tree=$(mktemp -d)
    trap 'git worktree remove --force "$tree"' EXIT
    git worktree add --quiet --detach "$tree" "$rev"
    cd "$tree"
    echo "nixos-qa on pushed commit $(git rev-parse --short HEAD)"
    ${lib.getExe qa}
  '';

  task = description: app: { inherit description; exec = lib.getExe app; };

  hook = name: stage: app: {
    enable = true;
    inherit name;
    entry = lib.getExe app;
    language = "system";
    stages = [ stage ];
    pass_filenames = false;
    always_run = true;
  };
in
{
  imports = [ "${inputs.platform}/modules/commit-conventions.nix" ];

  packages = with pkgs; [
    just
    shellcheck
    sops
    age
    jq
    nh
    inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  platform.commit-conventions.enable = true;

  tasks = {
    "nixos:lint-comments" = task "Comment Policy lint (density + forbidden shapes)" lintComments;
    "nixos:lint-shell" = task "shellcheck scripts/*.sh" lintShell;
    "nixos:secrets-verify" = task "Decrypt-check wifi credentials (skips without an age key)" secretsVerify;
    "nixos:nvim-check" = task "Build lenovo's nvim and start the generated config headless" nvimCheck;
    "nixos:flake-check" = task "nix flake check over all systems" flakeCheck;
    "nixos:verify" = task "Build every x86 host, evaluate black-pi" verifyHosts;
    "nixos:qa" = task "Every gate above, in order" qa;
  };

  git-hooks.hooks = {
    nixos-lint-comments = hook "Comment Policy lint" "pre-commit" lintComments;
    nixos-lint-shell = hook "shellcheck" "pre-commit" lintShell;
    nixos-qa-push = hook "Full QA on the pushed commit" "pre-push" qaPush;
  };
}
