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
  nvimCheck = gate "nixos-nvim-check" (with pkgs; [ nix python3 jq gnugrep coreutils ]) ''
    p=$(python3 scripts/gate_probe.py nvim-check)
    NV=$(jq -r .nvim <<<"$p")
    cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
    mkdir -p "$cfg/nvim"
    ln -s "$PWD/dotfiles/nvim/lua" "$cfg/nvim/lua"
    ln -s "$PWD/dotfiles/nvim/lazy-lock.json" "$cfg/nvim/lazy-lock.json"
    jq -j .init <<<"$p" > "$cfg/nvim/init.lua"
    jq -j .nix <<<"$p" > "$cfg/nvim/nix.lua"
    out=$(XDG_CONFIG_HOME="$cfg" "$NV/bin/nvim" --headless +qa 2>&1 || true)
    if printf '%s' "$out" | grep -qiE 'error|stack traceback|E[0-9]{3,}:'; then
      printf '%s\n' "$out"; echo "nvim-check: startup errored" >&2; exit 1
    fi
  '';

  # Also builds every x86 host (deploy-rs' deploy-activate check holds their toplevels) and, with
  # --all-systems, evaluates the aarch64 Pis: the one place a host build is checked.
  flakeCheck = gate "nixos-flake-check" [ pkgs.nix ] ''
    nix flake check --all-systems --no-write-lock-file
  '';

  # The values the tests below assert on, from one evaluation (scripts/gate-probe.nix); a test task run on
  # its own builds only its section.
  probe = gate "nixos-gate-probe" [ pkgs.nix ] ''
    nix build --impure --no-link --print-out-paths --expr '(import ./scripts/gate-probe.nix { }).json'
  '';

  claudeSettingsTest = gate "claude-settings-test" (with pkgs; [ nix python3 jq ]) ''
    p=$(python3 scripts/gate_probe.py claude-settings)
    CLAUDE_BIN=$(jq -r .package <<<"$p")/bin/claude \
      python3 scripts/test-native-otel-subprocess-env.py "$(jq -r '."home-files"' <<<"$p")/.claude/settings.json"
  '';

  nativeOtelRelayTest = gate "native-otel-relay-test" (with pkgs; [ nginx nix python3 jq ]) ''
    helper=$(python3 scripts/gate_probe.py native-otel-relay | jq -r .helper)
    ${pkgs.python3}/bin/python scripts/test-native-otel-relay.py "$helper" "${pkgs.nginx}/bin/nginx"
  '';

  nativeOtelFishTest = gate "native-otel-fish-test" (with pkgs; [ fish nix python3 ]) ''
    nixpkgs_source=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
    ${pkgs.python3}/bin/python scripts/test-native-otel-fish.py "$nixpkgs_source"
  '';

  coordinatorWiringTest = gate "coordinator-wiring-test" (with pkgs; [ nix python3 yq-go ]) ''
    ${pkgs.python3}/bin/python scripts/test-coordinator-wiring.py
  '';

  workerPermissionsTest = gate "worker-permissions-test" (with pkgs; [ nix python3 coreutils util-linux ]) ''
    ${pkgs.python3}/bin/python scripts/test-worker-permissions.py
  '';

  workersEvalTest = gate "workers-eval-test" (with pkgs; [ nix python3 fish bash ]) ''
    ${pkgs.python3}/bin/python scripts/test-workers-eval.py
  '';

  # #42 DoD: no heavyweight RE tooling on naked-pi, no k3s there, no rf-lab module on any other host (eval only)
  rfLabBoundaryTest = gate "rf-lab-boundary-test" (with pkgs; [ nix python3 ]) ''
    ${pkgs.python3}/bin/python scripts/test-rf-lab-boundary.py
  '';

  # msi and acer through the runtime-host role: headless and unthemed, maintenance off the boot path (eval only)
  runtimeHostTest = gate "runtime-host-test" (with pkgs; [ nix python3 ]) ''
    ${pkgs.python3}/bin/python scripts/test-runtime-host-role.py
  '';

  ollamaPortforwardTest = gate "ollama-portforward-test" (with pkgs; [ nix python3 procps ]) ''
    ${pkgs.python3}/bin/python scripts/test-ollama-portforward.py
  '';

  knownHostsTest = gate "known-hosts-test" (with pkgs; [ nix python3 openssh ssh-to-age ]) ''
    ${pkgs.python3}/bin/python scripts/test-ssh-known-hosts.py
  '';

  buildBoundsTest = gate "build-bounds-test" (with pkgs; [ nix python3 ]) ''
    ${pkgs.python3}/bin/python scripts/test-lenovo-build-bounds.py
  '';

  # the generated devenv.local.nix against the pinned skills input and its fake gh: approved accepted under the
  # delegation, refused with it off; devenv itself comes from the system profile, as on the coordinator host
  delegationTest = gate "delegation-test" (with pkgs; [ nix python3 ]) ''
    PATH="$PATH:/run/current-system/sw/bin" ${pkgs.python3}/bin/python scripts/test-coordinator-delegation.py
  '';

  # nixos-config#92: nativeOtel = false (the runbook's rollback) removes every telemetry surface
  otelRollbackTest = gate "otel-rollback-test" (with pkgs; [ nix python3 git gnutar ]) ''
    ${pkgs.python3}/bin/python scripts/test-native-otel-rollback.py
  '';


  run = lib.concatMapStringsSep "\n" lib.getExe;
  lints = [ lintComments lintShell ];
  qa = gate "nixos-qa" [ ] ''
    ${run (lints ++ [ secretsVerify flakeCheck ])}
    GATE_PROBE=$(${lib.getExe probe})
    export GATE_PROBE
    ${run [
      nvimCheck nativeOtelRelayTest nativeOtelFishTest claudeSettingsTest coordinatorWiringTest workerPermissionsTest workersEvalTest
      ollamaPortforwardTest knownHostsTest buildBoundsTest delegationTest otelRollbackTest rfLabBoundaryTest runtimeHostTest rfBeaconsTest
    ]}
  '';

  # Runs the gate on the PUSHED commit in a throwaway worktree, so neither
  # unstaged edits nor a different checked-out branch can make it pass.
  # prek exposes only the first ref of a multi-ref push. A push that changes only
  # documentation since origin/main gets the lints; no merge-base means the full gate.
  qaPush = gate "nixos-qa-push" (with pkgs; [ git coreutils gnugrep ]) ''
    rev=''${PRE_COMMIT_TO_REF:-HEAD}
    case $rev in 0000000000000000000000000000000000000000) exit 0 ;; esac
    tree=$(mktemp -d)
    trap 'git worktree remove --force "$tree"' EXIT
    git worktree add --quiet --detach "$tree" "$rev"
    cd "$tree"
    # --no-renames: a file moved into docs/ still counts on its old side. The list is taken whole first:
    # grep -q quitting early would SIGPIPE git diff, and pipefail would turn that into "docs only".
    if base=$(git merge-base HEAD origin/main) && changed=$(git diff --no-renames --name-only "$base" HEAD) \
      && ! grep -qvE '^docs/|\.md$' <<<"$changed"; then
      echo "nixos-qa: $(git rev-parse --short HEAD) changes only documentation since origin/main, lints only"
      ${run lints}
      exit
    fi
    echo "nixos-qa on pushed commit $(git rev-parse --short HEAD)"
    ${lib.getExe qa}
  '';

  # Operator side of the naked-pi RF kit. Each SSHes the Pi (the `naked-pi` ssh
  # alias), runs one bounded wrapper there, and keeps analysis on this host.
  # Mostly passive; deauth is limited to our own AP's enrolled stations
  # (rf:ap-kick, rf:ap-kick-hil) — never injection or a third-party network.
  rfBeacons = gate "rf-beacons" (with pkgs; [ openssh coreutils gawk gnugrep wireshark-cli ]) ''
    exec >&2  # devenv captures task stdout; stream the table instead
    dwell=''${RF_DWELL:-1.2}
    dest="$HOME/rf-lab-captures"; mkdir -p "$dest"
    echo "Passive 2.4 GHz beacon sweep on naked-pi (~$(awk "BEGIN{printf \"%.0f\", 13*$dwell}")s)..."
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "sudo rf-sweep $dwell")
    scp -q "naked-pi:$out" "$dest/"
    f="$dest/$(basename "$out")"
    hdr=$(printf '%-18s %3s %5s %5s  %s' BSSID CH dBm beac SSID)
    # the table, SSIDs escaped (untrusted radio bytes): scripts/rf-beacons-table.sh, tested by rf:beacons-test
    body=$(bash scripts/rf-beacons-table.sh "$f")
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

  # Streams to stderr because devenv captures task stdout.
  naked = name: preamble: cmd: gate name [ pkgs.openssh ] ''
    exec >&2
    ${preamble}
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "sudo ${cmd}"
  '';

  rfBtScan = naked "rf-btscan" ''
    secs=''${RF_SECONDS:-15}
    echo "Passive BT/BLE discovery for ''${secs}s (visible devices only)..."
  '' "rf-btscan $secs";

  rfSim = naked "rf-sim" ''
    loss=''${RF_LOSS:-0}; outage=''${RF_OUTAGE:-1}; kick=''${RF_KICK:-0}
    echo "Virtual-radio two-netns Wi-Fi lab on naked-pi (mac80211_hwsim; no physical RF; loss=''${loss}% outage=''${outage}s kick=''${kick})..."
  '' "rf-sim $loss $outage $kick";

  rfApOutage = naked "rf-ap-outage" ''
    secs=''${RF_SECONDS:-10}
    echo "Bounded outage of naked-pi's own lab AP (''${secs}s)..."
  '' "rf-ap-outage $secs";

  rfApKickHil = gate "rf-ap-kick-hil" [ pkgs.openssh ] ''
    exec >&2
    mode=dry-run; arg=""
    [ "''${RF_HIL_COMMIT:-0}" = "1" ] && { mode=commit; arg="--commit"; }
    echo "Two-radio hardware-in-the-loop rf-ap-kick on naked-pi (mode=''${mode}; refuses unless mgmt is Ethernet)..."
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
      naked-pi "sudo rf-ap-kick-hil $arg"
  '';

  rfApStatus = naked "rf-ap-status" "" "rf-ap-status";

  rfBtStatus2 = naked "rf-bt-status" "" "rf-bt-status";

  rfBtDisconnect = naked "rf-bt-disconnect" ''
    mac=''${RF_MAC:?set RF_MAC=<enrolled-paired-MAC> (RF_COMMIT=1 to actually disconnect)}
    flag=""; [ "''${RF_COMMIT:-}" = 1 ] && flag="--commit"
    echo "rf-bt-disconnect $mac ''${flag:-(dry-run)} via our own controller..."
  '' "rf-bt-disconnect $mac $flag";

  rfBtOutage = naked "rf-bt-outage" ''
    secs=''${RF_SECONDS:-10}
    echo "rf-bt-adapter-outage ''${secs}s on naked-pi's own controller..."
  '' "rf-bt-adapter-outage $secs";

  rfApKick = naked "rf-ap-kick" ''
    mac=''${RF_MAC:?set RF_MAC=<enrolled-MAC> (RF_COMMIT=1 to actually evict)}
    flag=""; [ "''${RF_COMMIT:-}" = 1 ] && flag="--commit"
    echo "rf-ap-kick $mac ''${flag:-(dry-run)} on naked-pi's own AP..."
  '' "rf-ap-kick $mac $flag";

  rfList = gate "rf-list" (with pkgs; [ openssh coreutils ]) ''
    exec >&2  # devenv captures task stdout; stream the listing instead
    echo "== naked-pi /var/lib/rf-lab/captures:"
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi 'ls -la /var/lib/rf-lab/captures 2>/dev/null || echo "(none)"'
    echo "== local $HOME/rf-lab-captures:"
    ls -la "$HOME/rf-lab-captures" 2>/dev/null || echo "(none)"
  '';

  # Offline pre-deploy gate: evaluate naked-pi and assert the management-safety
  # invariants hold before anyone pushes a config to the headless box.
  rfPreflight = gate "rf-preflight" (with pkgs; [ nix jq coreutils ]) ''
    exec >&2
    echo "Evaluating naked-pi + checking management-safety invariants..."
    facts=$(nix eval --json ".#nixosConfigurations.naked-pi.config" --apply '
      c: {
        sshPassword = c.services.openssh.settings.PasswordAuthentication;
        rootLogin = c.services.openssh.settings.PermitRootLogin;
        sshOpenFirewall = c.services.openssh.openFirewall;
        homeWifi = c.networking.networkmanager.ensureProfiles.profiles ? home-wifi;
        watchdog = c.systemd.timers ? rf-net-watchdog;
        rootLock = c.system.activationScripts ? lockEmptyRootPassword;
        wifiUnmanaged = c.networking.networkmanager.unmanaged;
      }')
    echo "$facts" | jq .
    fail=0
    check() { if [ "$1" = "$2" ]; then echo "  ok  $3"; else echo "  FAIL $3 (got $1, want $2)"; fail=1; fi; }
    check "$(echo "$facts" | jq -r .sshPassword)" false "SSH password auth disabled"
    check "$(echo "$facts" | jq -r .rootLogin)" no "SSH root login disabled"
    check "$(echo "$facts" | jq -r .sshOpenFirewall)" false "SSH not globally open (scoped to LAN)"
    check "$(echo "$facts" | jq -r .homeWifi)" true "home-wifi management fallback present"
    check "$(echo "$facts" | jq -r .watchdog)" true "net-watchdog timer present"
    check "$(echo "$facts" | jq -r .rootLock)" true "empty-root-password lock present"
    if [ "$fail" = 0 ]; then echo "PREFLIGHT PASS — safe to deploy over Ethernet"; else echo "PREFLIGHT FAIL"; exit 1; fi
  '';

  # Offline analysis of a capture (no device involved): management-frame
  # breakdown and, crucially, any deauth/disassoc frames with their reason codes
  # — how you recognise a disconnect in a trace without transmitting anything.
  rfAnalyze = gate "rf-analyze" (with pkgs; [ coreutils gawk wireshark-cli ]) ''
    exec >&2
    # shellcheck disable=SC2012
    f=''${RF_PCAP:-$(ls -t "$HOME"/rf-lab-captures/*.pcap 2>/dev/null | head -1)}
    if [ -z "''${f:-}" ] || [ ! -e "$f" ]; then echo "no pcap (set RF_PCAP=path)"; exit 1; fi
    echo "Analyzing $f"
    echo "== management-frame subtypes:"
    tshark -r "$f" -Y 'wlan.fc.type==0' -T fields -e wlan.fc.type_subtype 2>/dev/null \
      | sort | uniq -c | sort -rn | gawk '
          BEGIN{n["0x0000"]="assoc-req";n["0x0001"]="assoc-resp";n["0x0004"]="probe-req";
                n["0x0005"]="probe-resp";n["0x0008"]="beacon";n["0x000a"]="disassoc";
                n["0x000b"]="auth";n["0x000c"]="deauth"}
          {name=(n[$2]?n[$2]:"subtype "$2); printf "  %6d  %s\n",$1,name}'
    echo "== deauth/disassoc frames (reason codes):"
    tshark -r "$f" -Y 'wlan.fc.type_subtype==0x0c || wlan.fc.type_subtype==0x0a' \
      -T fields -e wlan.sa -e wlan.da -e wlan.fixed.reason_code 2>/dev/null \
      | sort | uniq -c | sort -rn | gawk '{printf "  %4d  src=%s dst=%s reason=%s\n",$1,$2,$3,$4} END{if(NR==0)print "  (none in this trace)"}'
    echo "== top source addresses:"
    tshark -r "$f" -T fields -e wlan.sa 2>/dev/null | sort | uniq -c | sort -rn | head -8 \
      | gawk '{printf "  %6d  %s\n",$1,$2}'
  '';

  # Offline classification test: assert rf:analyze's decode recognises each
  # crafted fixture (beacon count, deauth/disassoc reason codes). No device.
  # the Rust beacon table of rf-proto (#42 slice 6) on a local capture; reads the file only. Its parity with
  # rf:beacons' tshark table is checks.rf-beacons-parity (flake check, so nixos:qa)
  rfBeaconTable = gate "rf-beacon-table" (with pkgs; [ nix coreutils ]) ''
    exec >&2
    # shellcheck disable=SC2012
    f=''${RF_PCAP:-$(ls -t "$HOME"/rf-lab-captures/*.pcap* 2>/dev/null | head -1)}
    [ -n "$f" ] && [ -r "$f" ] || { echo "no capture: set RF_PCAP=<file.pcap> (or run rf:beacons first)"; exit 1; }
    b=$(nix build --no-link --print-out-paths .#rf-beacons-rs)
    printf '%-18s %3s %5s %5s  %s\n' BSSID CH dBm beac SSID
    "$b/bin/rf-beacons-rs" "$f" "$b/share/rf-beacons-rs/oui-sample.csv" --text
  '';

  rfBeaconsTest = gate "rf-beacons-test" (with pkgs; [ bash wireshark-cli gawk coreutils gnugrep ]) ''
    bash scripts/rf-beacons-test.sh
  '';

  rfAnalyzeTest = gate "rf-analyze-test" (with pkgs; [ bash wireshark-cli coreutils gnugrep ]) ''
    bash scripts/rf-analyze-test.sh
  '';

  embeddedDiscover = gate "embedded-discover" [ pkgs.openssh ] ''
    exec >&2  # devenv captures task stdout; stream results instead
    port=''${EMBEDDED_PORT:+--port ''${EMBEDDED_PORT}}
    # shellcheck disable=SC2086
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "espflash board-info $port"
  '';

  # Flashes the ELF from `cargo build` (espflash flash reads an ELF, not a raw
  # .bin). Dry-run by default like rf:ap-kick, since flashing overwrites device
  # state; EMBEDDED_COMMIT=1 performs it. EMBEDDED_PORT overrides espflash's
  # auto-detect when more than one serial port is present (non-interactive SSH
  # cannot answer espflash's port prompt).
  embeddedFlash = gate "embedded-flash" (with pkgs; [ openssh coreutils ]) ''
    exec >&2  # devenv captures task stdout; stream results instead
    fw=''${FW_ELF:?set FW_ELF=/path/to/firmware (the ELF from cargo build, not a raw .bin)}
    [ -f "$fw" ] || { echo "no such file: $fw" >&2; exit 1; }
    port=''${EMBEDDED_PORT:+--port ''${EMBEDDED_PORT}}
    if [ "''${EMBEDDED_COMMIT:-}" != 1 ]; then
      echo "dry-run: would copy $fw to naked-pi and run: espflash flash $port <remote-elf>" >&2
      echo "set EMBEDDED_COMMIT=1 to flash for real" >&2
      exit 0
    fi
    remote=$(ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "mktemp /tmp/embedded-fw.XXXXXX")
    # shellcheck disable=SC2064
    trap "ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi 'rm -f $remote'" EXIT
    scp -o BatchMode=yes -o ConnectTimeout=10 "$fw" "naked-pi:$remote"
    # shellcheck disable=SC2086
    ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi "espflash flash $port $remote"
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
    "nixos:flake-check" = task "nix flake check over all systems: builds every x86 host, evaluates the Pis" flakeCheck;
    "nixos:claude-settings-test" = task "Generated Claude settings: default mode, bypass on request, no OTLP leak" claudeSettingsTest;
    "nixos:ollama-portforward-test" = task "lenovo ollama-portforward: a wedged forward is restarted, an HTTP error is not" ollamaPortforwardTest;
    "nixos:coordinator-test" = task "Coordinator adapters on lenovo only; Codex agent via config_file, no model pin" coordinatorWiringTest;
    "nixos:worker-permissions-test" = task "#145/#157: Herdr workers start in bypassPermissions and switch models on a safeguards flag; claude and the Coordinator unchanged" workerPermissionsTest;
    "nixos:workers-eval-test" = task "The developer-environment module rejects each wrong configuration at eval; agent argv survives the guest shell" workersEvalTest;
    "nixos:known-hosts-test" = task "Verified SSH host keys pinned fleet-wide, clients and deploy-rs fail closed" knownHostsTest;
    "nixos:delegation-test" = task "lenovo's generated devenv.local.nix delegates approval to an interactive Coordinator (real devenv, fake gh)" delegationTest;
    "nixos:build-bounds-test" = task "nix-daemon builds are bounded (cores, jobs, MemoryHigh/Max) on lenovo and the environment hosts" buildBoundsTest;
    "nixos:otel-rollback-test" = task "nativeOtel = false on lenovo removes every native telemetry surface (Claude env, Codex [otel], Fish preludes, relay, secret)" otelRollbackTest;
    "nixos:rf-lab-boundary-test" = task "#42: naked-pi carries no heavyweight RE tooling and no k3s; no other host imports rf-lab" rfLabBoundaryTest;
    "nixos:runtime-host-test" = task "msi and acer carry the runtime-host role: headless and unthemed, maintenance waits for a synced clock" runtimeHostTest;
    "nixos:qa" = task "Every gate above, in order" qa;

    "rf:beacons" = task "naked-pi: passive 2.4 GHz beacon sweep -> AP table" rfBeacons;
    "rf:capture" = task "naked-pi: bounded monitor capture (RF_CHANNEL, RF_SECONDS, RF_BSSID)" rfCapture;
    "rf:btscan" = task "naked-pi: passive Bluetooth/BLE discovery (RF_SECONDS)" rfBtScan;
    "rf:list" = task "naked-pi: list captures on the Pi and locally" rfList;
    "rf:analyze" = task "offline pcap analysis: mgmt frames + deauth/disassoc reason codes (RF_PCAP)" rfAnalyze;
    "rf:beacons-test" = task "offline: rf:beacons' AP table on the crafted fixtures: hidden SSIDs, escaped control bytes (#42)" rfBeaconsTest;
    "rf:beacon-table" = task "offline: the Rust (rf-proto) beacon table of a local pcap (RF_PCAP, default newest)" rfBeaconTable;
    "rf:analyze-test" = task "offline: assert rf:analyze classifies the crafted pcap fixtures" rfAnalyzeTest;
    "rf:sim" = task "naked-pi: fully-virtual hwsim Wi-Fi lab (assoc + iperf3 + disconnect/recover)" rfSim;
    "rf:ap-outage" = task "naked-pi: bounded outage of the lab's own AP (RF_SECONDS)" rfApOutage;
    "embedded:discover" = task "naked-pi: espflash board-info (chip, revision, flash, MAC)" embeddedDiscover;
    "embedded:flash" = task "naked-pi: flash FW_ELF to the board (dry-run; EMBEDDED_COMMIT=1, EMBEDDED_PORT)" embeddedFlash;
    "rf:preflight" = task "naked-pi: offline pre-deploy safety-invariant gate" rfPreflight;
    "rf:ap-status" = task "naked-pi: list stations associated to the lab AP" rfApStatus;
    "rf:ap-kick" = task "naked-pi: evict an enrolled station from our own AP (RF_MAC, RF_COMMIT)" rfApKick;
    "rf:ap-kick-hil" = task "naked-pi: two-radio hardware-in-the-loop rf-ap-kick (Ethernet-gated; RF_HIL_COMMIT)" rfApKickHil;
    "rf:bt-status" = task "naked-pi: Bluetooth controller + paired-device status" rfBtStatus2;
    "rf:bt-disconnect" = task "naked-pi: disconnect an enrolled paired BT device (RF_MAC, RF_COMMIT)" rfBtDisconnect;
    "rf:bt-outage" = task "naked-pi: bounded local BT adapter power-off/on (RF_SECONDS)" rfBtOutage;
  };

  git-hooks.hooks = {
    nixos-lint-comments = hook "Comment Policy lint" "pre-commit" lintComments;
    nixos-lint-shell = hook "shellcheck" "pre-commit" lintShell;
    nixos-qa-push = hook "Full QA on the pushed commit" "pre-push" qaPush;
  };
}
