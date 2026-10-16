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

  # Operator side of the naked-pi passive RF kit. Each SSHes the Pi (the
  # `naked-pi` ssh alias), runs one bounded observation wrapper there, and keeps
  # analysis on this host. Observation only: no task can transmit, deauth or jam.
  rfBeacons = gate "rf-beacons" (with pkgs; [ openssh coreutils gawk gnugrep wireshark-cli ]) ''
    exec >&2  # devenv captures task stdout; stream the table instead
    dwell=''${RF_DWELL:-1.2}
    dest="$HOME/rf-lab-captures"; mkdir -p "$dest"
    echo "Passive 2.4 GHz beacon sweep on naked-pi (~$(awk "BEGIN{printf \"%.0f\", 13*$dwell}")s)..."
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "sudo rf-sweep $dwell")
    scp -q "naked-pi:$out" "$dest/"
    f="$dest/$(basename "$out")"
    hdr=$(printf '%-18s %3s %5s %5s  %s' BSSID CH dBm beac SSID)
    body=$(tshark -r "$f" -Y 'wlan.fc.type_subtype==0x08' -T fields \
             -e wlan.bssid -e wlan.ssid -e wlan_radio.channel -e wlan_radio.signal_dbm 2>/dev/null \
           | gawk -F'\t' '
               function h2a(s,  r,i){r="";for(i=1;i<=length(s);i+=2)r=r sprintf("%c",strtonum("0x" substr(s,i,2)));return r}
               {b=$1; if(b=="")next; n[b]++; ch[b]=$3; s=h2a($2); if(s=="")s="<hidden>"; name[b]=s;
                if(sig[b]==""||($4+0)>(sig[b]+0))sig[b]=$4}
               END{for(b in n) printf "%-18s %3s %5s %5s  %s\n",b,ch[b],sig[b],n[b],name[b]}' \
           | sort -k2 -n)
    printf '%s\n%s\n' "$hdr" "$body"
    echo "($(printf '%s\n' "$body" | grep -c . || true) APs; pcap: $f)"
  '';

  rfCapture = gate "rf-capture" (with pkgs; [ openssh coreutils ]) ''
    exec >&2  # devenv captures task stdout; stream progress instead
    ch=''${RF_CHANNEL:?set RF_CHANNEL=1..13 (e.g. RF_CHANNEL=6 devenv tasks run rf:capture)}
    secs=''${RF_SECONDS:-30}
    bssid=''${RF_BSSID:-}
    filt=""; [ -n "$bssid" ] && filt="wlan addr3 $bssid"
    dest="$HOME/rf-lab-captures"; mkdir -p "$dest"
    echo "Capturing ch $ch for ''${secs}s''${bssid:+ (AP $bssid)}..."
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "sudo rf-capture $ch $secs '$filt'")
    scp -q "naked-pi:$out" "$dest/"
    f="$dest/$(basename "$out")"
    echo "pcap: $f"
    echo "open: nix shell nixpkgs#wireshark -c wireshark $f"
  '';

  rfBtScan = gate "rf-btscan" [ pkgs.openssh ] ''
    exec >&2  # devenv captures task stdout; stream results instead
    secs=''${RF_SECONDS:-15}
    echo "Passive BT/BLE discovery for ''${secs}s (visible devices only)..."
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "sudo rf-btscan $secs"
  '';

  rfList = gate "rf-list" (with pkgs; [ openssh coreutils ]) ''
    exec >&2  # devenv captures task stdout; stream the listing instead
    echo "== naked-pi /var/lib/rf-lab/captures:"
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi 'ls -la /var/lib/rf-lab/captures 2>/dev/null || echo "(none)"'
    echo "== local $HOME/rf-lab-captures:"
    ls -la "$HOME/rf-lab-captures" 2>/dev/null || echo "(none)"
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
    "nixos:verify" = task "Build every x86 host, evaluate the Pis" verifyHosts;
    "nixos:qa" = task "Every gate above, in order" qa;

    "rf:beacons" = task "naked-pi: passive 2.4 GHz beacon sweep -> AP table" rfBeacons;
    "rf:capture" = task "naked-pi: bounded monitor capture (RF_CHANNEL, RF_SECONDS, RF_BSSID)" rfCapture;
    "rf:btscan" = task "naked-pi: passive Bluetooth/BLE discovery (RF_SECONDS)" rfBtScan;
    "rf:list" = task "naked-pi: list captures on the Pi and locally" rfList;
  };

  git-hooks.hooks = {
    nixos-lint-comments = hook "Comment Policy lint" "pre-commit" lintComments;
    nixos-lint-shell = hook "shellcheck" "pre-commit" lintShell;
    nixos-qa-push = hook "Full QA on the pushed commit" "pre-push" qaPush;
  };
}
