# The gates, by binding (search `^  <name> =`): each check is a `gate` (writeShellApplication) in the let below.
# `lints` (also pre-commit's hooks), `tests` (nixos:qa runs them in order after the probe), `sideBySide` (the flake
# check and the slowest tests, in parallel on asus), `qa` (nixos:qa: every gate), `qaPush` (pre-push: qa on the pushed
# commit in a temporary worktree, recording a green tree); then `tasks` (one nixos:* task per gate, its description
# what `devenv tasks list` shows) and `git-hooks.hooks`. A new test is three hunks: its `gate` binding, its entry in
# `tests` or `sideBySide`, and its `tasks` entry.
{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  gate =
    name: runtimeInputs: text:
    pkgs.writeShellApplication { inherit name runtimeInputs text; };

  lintComments =
    gate "nixos-lint-comments"
      (with pkgs; [
        bash
        git
        gawk
        gnugrep
        gnused
        findutils
        coreutils
      ])
      ''
        bash scripts/nix-comment-lint.sh
        fx=scripts/fixtures/comment-lint
        # refused by that rule, not by a missing fixture or a dead awk (exit 2)
        rc=0
        out=$(bash scripts/nix-comment-lint.sh "$fx/rollback-instruction.nix.fixture" 2>&1) || rc=$?
        if [ "$rc" -ne 1 ] || ! grep -q '^rollback-instructions: ' <<<"$out"; then
          printf '%s\n' "$out" >&2
          echo "comment lint: $fx/rollback-instruction.nix.fixture was not refused by rollback-instructions (exit $rc)" >&2
          exit 1
        fi
        bash scripts/nix-comment-lint.sh "$fx/rollback-pointer.nix.fixture" >/dev/null
        rc=0
        out=$(bash scripts/nix-comment-lint.sh "$fx/dangling-pointer.nix.fixture" 2>&1) || rc=$?
        if [ "$rc" -ne 1 ] || ! grep -q '^path-pointer: .*/power-windows[.]nix ' <<<"$out"; then
          printf '%s\n' "$out" >&2
          echo "comment lint: $fx/dangling-pointer.nix.fixture was not refused by path-pointer (exit $rc)" >&2
          exit 1
        fi
      '';

  # the flake's own formatter (nixfmt-tree, flake-modules/overlays.nix) in CI mode: it fails on any file it would
  # change, so formatting fails here first, not in a late step or review. It rewrites what it would change, so a
  # manual run leaves the fix in the checkout; the hook runs it in a temporary worktree.
  fmtCheck = gate "nixos-fmt-check" [ pkgs.nix ] ''
    nix fmt --no-write-lock-file -- --ci
  '';

  lintShell = gate "nixos-lint-shell" [ pkgs.shellcheck ] ''
    shellcheck scripts/*.sh
  '';

  # deploy-rs is pinned in devenv.yaml/devenv.lock and in flake.lock; a differing rev fails with each one printed
  deployRsPins = gate "nixos-deploy-rs-pins" [ pkgs.python3 ] ''
    python3 scripts/deploy-rs-pins.py
    python3 scripts/deploy-rs-pins.py --seeds
  '';

  # Skips (exit 0) on hosts without the age key; only lenovo enforces it.
  secretsVerify =
    gate "nixos-secrets-verify"
      (with pkgs; [
        bash
        sops
        age
        gawk
        gnugrep
        gnused
        coreutils
      ])
      ''
        bash scripts/secrets-verify.sh
      '';

  # Isolated config from the generated files, not ~/.config/nvim: +qa against
  # the live dir would exercise the deployed (possibly stale) generation and
  # mask errors, since +qa exits 0 even on an init throw.
  nvimCheck =
    gate "nixos-nvim-check"
      (with pkgs; [
        nix
        python3
        jq
        gnugrep
        coreutils
      ])
      ''
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

  # What `nix flake check --all-systems` checks, one output per nix process: in one process it holds every
  # host and is killed under a 4G cap. Builds every x86 host (its deploy-activate check holds the toplevel)
  # and evaluates the aarch64 Pis: the one place a host build is checked. An output kind not listed here
  # fails the step, so a new kind cannot go unchecked.
  # GC_FREE_SPACE_DIVISOR=16 (Boehm default 3) collects more often: acer-swift deploy check 2809 MiB, not
  # 3174 MiB, under the 4G cap, for about +40% evaluation time on that process (#359).
  # what a gate step built off its own node would compile against: CUDA or the NVIDIA driver (#502); one pattern for the
  # flake check and scripts/gate_defer.py (GATE_HEAVY)
  gateHeavy = "-cuda[0-9._]*-|cuda_|nvidia-x11";
  flakeCheck =
    gate "nixos-flake-check"
      (with pkgs; [
        nix
        jq
        gawk
        gnugrep
        gnused
        coreutils
      ])
      ''
        export GC_FREE_SPACE_DIVISOR=16
        names() { nix eval --json --no-write-lock-file ".#$1" --apply builtins.attrNames | jq -r '.[]'; }
        # one line per output with its seconds, so a slow step shows where it spends them (#502)
        took() { echo "nixos-flake-check: $1 took $((SECONDS - $2)) s" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}" >&2; }
        drv() {
          local t=$SECONDS
          echo "nixos-flake-check: $1" >&2
          nix eval --raw --no-write-lock-file ".#$1.drvPath" >/dev/null
          took "eval $1" "$t"
        }
        # Every output is evaluated, as before; only a build is ever left out. A check whose build would compile against
        # CUDA or the NVIDIA driver is built only on the host it deploys to (deploy-activate-<node>, deploy-schema-<node>,
        # both of which pull the node's closure) and deferred to that host's gate elsewhere: the dry-run that found it
        # already asked the substituters. A heavy check of no node is built only on a host whose own system has CUDA,
        # and fails the step elsewhere rather than go unbuilt. Deferrals are listed at the end, in NIXOS_QA_TIMES and as
        # deferred gate-step records. CUDA shows in the to-build derivations' inputs (cuda_cudart, nvidia-x11), not in a
        # name: asus's CUDA Ollama is plain ollama-0.x (#502).
        # args: this host, the check's name, the derivations a build would compile, their inputs, 1 if this host's system
        # has CUDA
        heavy='${gateHeavy}'
        decide() {
          local node=
          case $2 in deploy-activate-* | deploy-schema-*) node=''${2#deploy-*-} ;; esac
          if [ -z "$3" ] || ! grep -qE -e "$heavy" <<<"$4"; then
            echo build
          elif [ -n "$node" ]; then
            if [[ $1 == "$node"* ]]; then echo build; else echo foreign; fi
          elif [ "$5" = 1 ]; then
            echo build
          else
            echo nodeless
          fi
        }
        me=$(uname -n)
        cudahost=0
        if nix-store -qR /run/current-system 2>/dev/null | grep -qE -e "$heavy"; then cudahost=1; fi
        deferred=()
        here=$(nix eval --raw --impure --expr builtins.currentSystem)
        # VM checks (NixOS tests, the ones with a driver) boot QEMU, up to 4 GiB: the gate refuses to run on lenovo
        # shellcheck disable=SC2016 # the single-quoted ''${n} is Nix's, not the shell's
        vms=$(nix eval --json --no-write-lock-file ".#checks.$here" \
          --apply 'cs: builtins.filter (n: cs.''${n} ? driver) (builtins.attrNames cs)' | jq -r '.[]')
        if [ -n "$vms" ] && [ "$(${pkgs.coreutils}/bin/uname -n)" = lenovo-21CB001PMX ]; then
          echo "nixos-flake-check: refused on lenovo: $(tr '\n' ' ' <<<"$vms")boot a QEMU VM (memory); run the gate on msi or acer" >&2
          exit 1
        fi
        kinds=$(nix flake show --json --all-systems --no-write-lock-file | jq -c 'keys')
        [ "$kinds" = '["checks","deploy","formatter","nixosConfigurations","overlays","packages","templates"]' ] \
          || { echo "nixos-flake-check: flake outputs are $kinds: add the new kind to this step" >&2; exit 1; }
        nix eval --no-write-lock-file .#overlays --apply 'builtins.mapAttrs (_: o: assert builtins.isFunction o; true)' >/dev/null
        nix eval --no-write-lock-file .#templates \
          --apply 'builtins.mapAttrs (_: t: assert builtins.pathExists t.path && builtins.isString t.description; true)' >/dev/null
        hosts=$(names nixosConfigurations)
        for h in $hosts; do drv "nixosConfigurations.$h.config.system.build.toplevel"; done
        for s in $(names formatter); do drv "formatter.$s"; done
        for kind in packages checks; do
          systems=$(names "$kind")
          for s in $systems; do
            outputs=$(names "$kind.$s")
            for o in $outputs; do
              if [ "$kind.$s" = "checks.$here" ]; then
                c=checks.$s.$o
                t=$SECONDS
                d=$(nix eval --raw --no-write-lock-file ".#$c.drvPath")
                took "eval $c" "$t"
                ev=$((SECONDS - t))
                # a failed dry-run fails the step: read as "nothing to build" it would hide the check (nix 2.34 also
                # exits 0 on "don't know how to build")
                if ! dry=$(nix build --dry-run --no-link "$d^*" 2>&1) || grep -q "know how to build" <<<"$dry"; then
                  printf '%s\n' "$dry" >&2
                  echo "nixos-flake-check: the dry-run of $c failed" >&2
                  exit 1
                fi
                todo=$(awk '/will be built:/ { f = 1; next } /will be fetched|^[^ ]/ { f = 0 } f { print $1 }' <<<"$dry")
                inputs=""
                # shellcheck disable=SC2086 # one store path per word
                if [ -n "$todo" ]; then inputs=$(nix-store -q --references $todo); fi
                n=$(grep -c . <<<"$todo" || true)
                m=$(awk '/will be fetched/ { f = 1; next } /^[^ ]/ { f = 0 } f && $1 ~ /^[/]nix[/]store[/]/ { c++ } END { print c + 0 }' <<<"$dry")
                t=$SECONDS
                case $(decide "$me" "$o" "$todo" "$inputs" "$cudahost") in
                  build)
                    echo "nixos-flake-check: build $c (compiles $n) $d" >&2
                    # one record per check built here, for "where a gate's time goes" (Shipping): build and eval seconds,
                    # the derivations it compiled and fetched, and its result: compiled here (built), only substituted
                    # (fetched), already in the store (present), a failed build (fail), or nothing built at all (dry).
                    # owner is this host, so an owning host's own deploy check is the other half of a deferral
                    if [ -n "''${NIXOS_FLAKE_CHECK_DRY:-}" ]; then
                      r=dry
                    elif ! nix build --no-link "$d^*"; then
                      ${lib.getExe record} gate-step gate=nixos-qa step=nixos-flake-check check="$c" owner="$me" seconds=$((SECONDS - t)) eval_seconds=$ev compiled="$n" fetched="$m" result=fail head="''${NIXOS_QA_HEAD:-}" drv="$d"
                      exit 1
                    elif [ "$n" -gt 0 ]; then
                      r=built
                    elif [ "$m" -gt 0 ]; then
                      r=fetched
                    else
                      r=present
                    fi
                    took "build $c" "$t"
                    ${lib.getExe record} gate-step gate=nixos-qa step=nixos-flake-check check="$c" owner="$me" seconds=$((SECONDS - t)) eval_seconds=$ev compiled="$n" fetched="$m" result=$r head="''${NIXOS_QA_HEAD:-}" drv="$d"
                    ;;
                  foreign)
                    owner=''${o#deploy-*-}
                    deferred+=("$owner:$c")
                    echo "nixos-flake-check: deferred $c to $owner (compiles $n) $d: it would compile against $(grep -E -e "$heavy" <<<"$inputs" | sed 's|^/nix/store/[a-z0-9]*-||' | tr '\n' ' ')" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}" >&2
                    ${lib.getExe record} gate-step gate=nixos-qa step=nixos-flake-check check="$c" owner="$owner" seconds=0 result=deferred head="''${NIXOS_QA_HEAD:-}" drv="$d"
                    ;;
                  nodeless)
                    echo "nixos-flake-check: $c would compile against CUDA on $me, whose system has none, and names no deploy node to defer to: name it deploy-*-<node> or run this gate on a CUDA host" >&2
                    exit 1
                    ;;
                esac
              else
                drv "$kind.$s.$o"
              fi
            done
          done
        done
        if [ ''${#deferred[@]} -gt 0 ]; then
          echo "nixos-flake-check: not built here, deferred to their own host's gate: ''${deferred[*]}" >&2
          printf '%s\n' "''${deferred[@]}" >>"''${NIXOS_QA_DEFERRED:-/dev/null}"
        fi
      '';

  # The values the tests below assert on, from one evaluation (scripts/gate-probe.nix); a test task run on
  # its own builds only its section. GC_FREE_SPACE_DIVISOR as for flakeCheck: the probe holds acer too.
  probe = gate "nixos-gate-probe" [ pkgs.nix ] ''
    export GC_FREE_SPACE_DIVISOR=16
    nix build --impure --no-link --print-out-paths --expr '(import ./scripts/gate-probe.nix { }).json'
  '';

  claudeSettingsTest =
    gate "claude-settings-test"
      (with pkgs; [
        nix
        python3
        jq
      ])
      ''
        p=$(python3 scripts/gate_probe.py claude-settings)
        CLAUDE_BIN=$(jq -r .package <<<"$p")/bin/claude \
          python3 scripts/test-native-otel-subprocess-env.py "$(jq -r '."home-files"' <<<"$p")/.claude/settings.json"
      '';

  nativeOtelRelayTest =
    gate "native-otel-relay-test"
      (with pkgs; [
        nginx
        nix
        python3
        jq
      ])
      ''
        helper=$(python3 scripts/gate_probe.py native-otel-relay | jq -r .helper)
        ${pkgs.python3}/bin/python scripts/test-native-otel-relay.py "$helper" "${pkgs.nginx}/bin/nginx"
      '';

  nativeOtelFishTest =
    gate "native-otel-fish-test"
      (with pkgs; [
        fish
        nix
        python3
      ])
      ''
        nixpkgs_source=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
        ${pkgs.python3}/bin/python scripts/test-native-otel-fish.py "$nixpkgs_source"
      '';

  coordinatorWiringTest =
    gate "coordinator-wiring-test"
      (with pkgs; [
        nix
        python3
        yq-go
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-coordinator-wiring.py
      '';

  # the report timers' job without Nix: the fortnight rule on a pinned date, devenv stubbed
  coordinatorReportTest =
    gate "coordinator-report-test"
      (with pkgs; [
        python3
        bash
        coreutils
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-coordinator-report.py
      '';

  workerPermissionsTest =
    gate "worker-permissions-test"
      (with pkgs; [
        nix
        python3
        coreutils
        util-linux
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-worker-permissions.py
      '';

  workersEvalTest =
    gate "workers-eval-test"
      (with pkgs; [
        nix
        python3
        fish
        bash
        caddy
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-workers-eval.py
      '';

  trashSweepTest =
    gate "trash-sweep-test"
      (with pkgs; [
        bash
        coreutils
        findutils
        gawk
        gnugrep
        gnused
        util-linux
      ])
      ''
        bash scripts/test-trash-sweep.sh
      '';

  guestRecordsTest = gate "guest-records-test" (with pkgs; [ python3 ]) ''
    ${pkgs.python3}/bin/python scripts/test-guest-records.py
  '';

  # sam.claude.bulkReader: shunt hooks only when on and pinned, appended after the fleet's; guests via a guest module
  bulkReaderTest =
    gate "bulk-reader-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-bulk-reader-hooks.py
      '';

  harnessTelemetryTest =
    gate "harness-telemetry-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-harness-telemetry.py
      '';

  journalCollectorTest =
    gate "journal-collector-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-journal-collector.py
      '';

  fleetEndpointsTest =
    gate "fleet-endpoints-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-fleet-endpoints.py
      '';

  fleetContractTest =
    gate "fleet-contract-test"
      (with pkgs; [
        git
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-fleet-contract.py
      '';

  # In nixos:qa's tests (about 110 s on asus, its on-demand gate-step record, 18 Nov) and on demand. Not named test-*:
  # a docs-only push that edits a host table it reads would run it, and docs-only pushes run on lenovo, which it refuses.
  seventhHostTest =
    gate "seventh-host-test"
      (with pkgs; [
        git
        nix
        python3
      ])
      ''
        # eleven host evals: the memory flake-check spares lenovo, and the same heavy-work lane as nixos:qa (once)
        if [ "$(${pkgs.coreutils}/bin/uname -n)" = lenovo-21CB001PMX ]; then
          echo "seventh-host-test: refused on lenovo: eleven host evaluations (memory); run it on msi, asus or acer" >&2
          exit 1
        fi
        if [ -z "''${NIXOS_QA_LOCKED:-}" ]; then NIXOS_QA_LOCKED=1 exec ${lib.getExe heavyLock} "$0" "$@"; fi
        t=$SECONDS
        if ${pkgs.python3}/bin/python scripts/seventh-host-check.py; then r=pass; else r=fail; fi
        echo "seventh-host-test took $((SECONDS - t)) s"
        # inside nixos:qa its tests loop writes the step's record
        [ -n "''${NIXOS_QA_HEAD:-}" ] || ${lib.getExe record} gate-step gate=on-demand step=seventh-host-test seconds=$((SECONDS - t)) result=$r sha="$(git rev-parse HEAD)"
        [ "$r" = pass ]
      '';

  # acer's Alloy, config and ExecStart from the gate probe, not devenv's packages
  alloyOtlpTest =
    gate "alloy-otlp-test"
      (with pkgs; [
        nix
        python3
        jq
        curl
        gnugrep
        gnused
        gawk
        diffutils
        coreutils
      ])
      ''
        bash scripts/test-alloy-otlp-sanitizer.sh
        ${pkgs.python3}/bin/python scripts/test-alloy-otlp-log-loki.py
      '';

  typedInterfacesTest = gate "typed-interfaces-test" (with pkgs; [ python3 ]) ''
    ${pkgs.python3}/bin/python scripts/test-typed-interfaces.py
  '';
  systemChecksTest =
    gate "system-checks-test"
      (with pkgs; [
        python3
        bash
        jq
        coreutils
        gnugrep
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-system-checks.py
      '';
  deployRecipesTest =
    gate "deploy-recipes-test"
      (with pkgs; [
        python3
        bash
        just
        gawk
        coreutils
        gnugrep
        gnused
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-deploy-recipes.py
      '';
  platformRecordsTest =
    gate "platform-records-test"
      (with pkgs; [
        python3
        jq
        coreutils
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-platform-records.py
      '';
  scorecard = pkgs.callPackage ./pkgs/scorecard/package.nix { };
  # the packaged scorecard, so the gate builds it (its ruff and mypy check phase) and tests what platform:scorecard runs
  scorecardTest = gate "scorecard-test" [ pkgs.python3 ] ''
    ${pkgs.python3}/bin/python scripts/test-scorecard.py ${lib.getExe scorecard}
  '';
  measurementTest = gate "measurement-test" [ pkgs.python3 ] ''
    ${pkgs.python3}/bin/python scripts/test-measurement.py docs/measurement.md metrics/targets.json
  '';
  shippingMetricsTest = gate "shipping-metrics-test" [ pkgs.python3 ] ''
    ${pkgs.python3}/bin/python scripts/test-shipping-metrics.py
  '';
  navMetricsTest = gate "nav-metrics-test" [ pkgs.python3 ] ''
    ${pkgs.python3}/bin/python scripts/test-nav-metrics.py
  '';
  appBumpDryRunTest = gate "app-bump-dry-run-test" [ pkgs.python3 ] ''
    ${pkgs.python3}/bin/python scripts/test-app-bump-dry-run.py
    ${pkgs.python3}/bin/python scripts/test-app-bump.py
  '';
  triggerRollbackTest =
    gate "trigger-rollback-test"
      (with pkgs; [
        python3
        bash
        coreutils
        git
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-trigger-rollback.py
      '';
  waitMetricsTest =
    gate "wait-metrics-test"
      (with pkgs; [
        python3
        bash
        curl
        coreutils
        gnugrep
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-wait-metrics.py
      '';
  # acer's Caddyfile through acer's Caddy, from the gate probe
  caddyEdgeTest =
    gate "caddy-edge-test"
      (with pkgs; [
        nix
        openssl
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-caddy-edge.py
      '';

  # acer's ak wrapper, from the gate probe
  authentikAkTest =
    gate "authentik-ak-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-authentik-ak.py
      '';

  # ~/.claude.json activation
  switchSafetyTest =
    gate "switch-safety-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-switch-safety.py
      '';

  ollamaPortforwardTest =
    gate "ollama-portforward-test"
      (with pkgs; [
        nix
        python3
        procps
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-ollama-portforward.py
      '';

  ollamaPullPinnedTest =
    gate "ollama-pull-pinned-test"
      (with pkgs; [
        python3
        ollama
        curl
        jq
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-ollama-pull-pinned.py
      '';

  ollamaGpuTest =
    gate "ollama-gpu-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        GATE_HEAVY='${gateHeavy}' PLATFORM_RECORD=${lib.getExe record} ${pkgs.python3}/bin/python scripts/test-ollama-gpu.py
      '';

  # the llm-bench harness and #492's G1 bench against the fake Ollama; no nix: the rules and the exporter are flake checks
  llmBenchTest =
    gate "llm-bench-test"
      (with pkgs; [
        python3
        bash
        curl
        jq
        git
        coreutils
      ])
      ''
        ${pkgs.python3}/bin/python -I scripts/test-llm-bench.py
      '';

  alertBridgeTest =
    gate "alert-bridge-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-alert-bridge.py
      '';

  dualBootTest =
    gate "dual-boot-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-dual-boot.py
      '';

  knownHostsTest =
    gate "known-hosts-test"
      (with pkgs; [
        nix
        python3
        openssh
        ssh-to-age
        just
        gawk
        coreutils
        gnugrep
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-ssh-known-hosts.py
      '';

  systemdCalendarTest =
    gate "systemd-calendar-test"
      (with pkgs; [
        python3
        systemd
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-systemd-calendar.py
      '';

  systemdVerifyTest =
    gate "systemd-verify-test"
      (with pkgs; [
        python3
        systemd
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-systemd-verify.py
      '';

  powerScheduleTest =
    gate "power-schedule-test"
      (with pkgs; [
        nix
        python3
        bash
        coreutils
        systemd
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-power-schedule.py
        ${pkgs.python3}/bin/python scripts/test-night-quiet.py
      '';

  readabilityTest =
    gate "readability-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-readability.py
      '';

  adguardDnsTest =
    gate "adguard-dns-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-adguard-dns.py
      '';

  buildBoundsTest =
    gate "build-bounds-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-lenovo-build-bounds.py
      '';

  # the generated devenv.local.nix against the pinned skills input and its fake gh: approved accepted under the
  # delegation, refused with it off; devenv itself comes from the system profile, as on the coordinator host
  delegationTest =
    gate "delegation-test"
      (with pkgs; [
        nix
        python3
      ])
      ''
        PATH="$PATH:/run/current-system/sw/bin" ${pkgs.python3}/bin/python scripts/test-coordinator-delegation.py
      '';

  qaPushTest =
    gate "qa-push-test"
      (with pkgs; [
        nix
        python3
        git
        coreutils
        gnugrep
        bash
        util-linux
        procps
        gawk
      ])
      ''
        ${pkgs.python3}/bin/python scripts/test-qa-push.py
        ${pkgs.python3}/bin/python scripts/test-prepush-one-ref.py
        ${pkgs.python3}/bin/python scripts/test-gate-steps.py
        ${pkgs.python3}/bin/python scripts/test-heavy-lock.py ${lib.getExe heavyLock}
        ${pkgs.python3}/bin/python scripts/test-deferred-checks.py
      '';

  run = lib.concatMapStringsSep "\n" lib.getExe;
  lints = [
    lintComments
    lintShell
    deployRsPins
  ];
  heavyLock = pkgs.callPackage ./pkgs/heavy-lock/package.nix { };
  qaGreen = gate "qa-green" (with pkgs; [
    git
    coreutils
  ]) (builtins.readFile ./scripts/qa-green.sh);
  record = pkgs.callPackage ./pkgs/platform-record/package.nix { };
  # seconds per step, to see where a slow gate spends its time (#334); prek hides a passing hook's
  # output, so the push gate also appends them to NIXOS_QA_TIMES. Each step, failed ones included, also goes to the
  # Platform health dashboard (pkgs/platform-record)
  timed = lib.concatMapStringsSep "\n" (g: ''
    t=$SECONDS
    if ${lib.getExe g}; then r=pass; else r=fail; fi
    echo "nixos-qa: ${g.name} took $((SECONDS - t)) s" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}"
    ${lib.getExe record} gate-step gate=nixos-qa step=${g.name} seconds=$((SECONDS - t)) result=$r sha="$sha"
    [ "$r" = pass ]
  '');
  tests = [
    nvimCheck
    nativeOtelRelayTest
    nativeOtelFishTest
    claudeSettingsTest
    coordinatorReportTest
    bulkReaderTest
    harnessTelemetryTest
    ollamaPortforwardTest
    ollamaPullPinnedTest
    ollamaGpuTest
    llmBenchTest
    alertBridgeTest
    dualBootTest
    knownHostsTest
    adguardDnsTest
    powerScheduleTest
    readabilityTest
    buildBoundsTest
    delegationTest
    journalCollectorTest
    fleetEndpointsTest
    fleetContractTest
    seventhHostTest
    caddyEdgeTest
    typedInterfacesTest
    systemChecksTest
    deployRecipesTest
    systemdCalendarTest
    systemdVerifyTest
    platformRecordsTest
    measurementTest
    scorecardTest
    trashSweepTest
    guestRecordsTest
    shippingMetricsTest
    navMetricsTest
    appBumpDryRunTest
    triggerRollbackTest
    waitMetricsTest
    authentikAkTest
    switchSafetyTest
    rfBeaconsTest
    qaPushTest
  ];
  # A docs-only push still runs the tests whose scripts/test-* reads a changed doc (#502): each found by its file name in
  # the gates' own text, after the probe they read. A reader no gate runs fails the push rather than pass unchecked.
  docTests =
    gate "nixos-doc-tests"
      (with pkgs; [
        coreutils
        gnugrep
      ])
      ''
        GATE_PROBE=$(${lib.getExe probe})
        export GATE_PROBE
        for f in "$@"; do
          found=
          for g in ${lib.concatMapStringsSep " " lib.getExe (sideBySide ++ tests)}; do
            if grep -qF "$f" "$g"; then
              found=1
              t=$SECONDS
              "$g"
              echo "nixos-qa: $(basename "$g") for $f took $((SECONDS - t)) s"
            fi
          done
          [ -n "$found" ] || { echo "nixos-doc-tests: no gate runs $f" >&2; exit 1; }
        done
      '';
  sideBySide = [
    flakeCheck
    coordinatorWiringTest
    workerPermissionsTest
    workersEvalTest
    alloyOtlpTest
  ];
  # the run's own record is written on every exit, so a failed or interrupted gate still shows
  # what this shell's gates were built from. The pre-push hook and a long-lived shell run the gates evaluated at
  # devenv entry: after a merge that changed these files they would check the new tree with the old test list. devenv
  # also loads devenv.local.nix and devenv.local.yaml when present (its bootstrapLib.nix, config.rs), so whether each
  # exists counts as well as its content
  builtFrom =
    let
      hash = p: if builtins.pathExists p then builtins.hashFile "sha256" p else "absent";
    in
    lib.concatMapStringsSep " " (p: "${baseNameOf (toString p)}=${hash p}") [
      ./devenv.nix
      ./devenv.yaml
      ./devenv.lock
      ./devenv.local.nix
      ./devenv.local.yaml
    ];
  # usage: devenv-fresh [ENTERED]: the tracked files in $PWD, the untracked local overrides in ENTERED, the checkout
  # the devenv was entered in (default $PWD; the pre-push hook checks the pushed commit in a worktree that has none)
  devenvFresh = gate "nixos-devenv-fresh" [ pkgs.coreutils ] ''
    entered=''${1:-$PWD}
    stale=""
    for pair in ${builtFrom}; do
      f=''${pair%%=*} want=''${pair#*=}
      case $f in devenv.local.*) f=$entered/$f ;; esac
      if [ "$want" = absent ]; then
        [ ! -e "$f" ] || stale="$stale $f"
        continue
      fi
      have=$(sha256sum "$f" 2>/dev/null) || have=missing
      [ "''${have%% *}" = "$want" ] || stale="$stale $f"
    done
    if [ -n "$stale" ]; then
      echo "nixos-qa: refused: this gate was built from another$stale than $PWD has (the devenv was entered before they changed): re-enter it (devenv shell -- true) and run again" >&2
      exit 1
    fi
  '';
  qa =
    gate "nixos-qa"
      (with pkgs; [
        coreutils
        gawk
        git
        jq
        python3
      ])
      ''
        # a gate built from other devenv files than this tree's would run a stale test list: refused, before the lock
        ${lib.getExe devenvFresh}
        # one heavy job per host (pkgs/heavy-lock): the gate takes the heavy-work lane itself, once
        if [ -z "''${NIXOS_QA_LOCKED:-}" ]; then NIXOS_QA_LOCKED=1 exec ${lib.getExe heavyLock} "$0" "$@"; fi
        sha=$(git rev-parse --short HEAD 2>/dev/null || echo none)
        NIXOS_QA_HEAD=$(git rev-parse HEAD 2>/dev/null || echo none)
        # a record with a kind or field metrics/records.json does not list fails the gate, not just the dashboard
        export NIXOS_QA_HEAD PLATFORM_RECORD_STRICT=1
        mode=manual
        [ -z "''${NIXOS_QA_TIMES:-}" ] || mode=push
        # a manual run's green counts for the pre-push hook when the checkout was clean throughout (scripts/qa-green.sh)
        began=
        [ "$mode" != manual ] || began=$(${lib.getExe qaGreen} begin 2>/dev/null) || began=
        # whether head= names what was checked: the hook's worktree is the pushed commit; a manual run may be dirty
        checkout=clean
        [ "$mode" != manual ] || checkout=''${began##* }
        checkout=''${checkout:-unknown}
        start=$SECONDS
        # checks nixos-flake-check left to their own host's gate: in the summary and the gate's record, never silent
        NIXOS_QA_DEFERRED=$(mktemp)
        export NIXOS_QA_DEFERRED
        on_exit() {
          local rc=$? result=fail n
          [ "$rc" != 0 ] || result=pass
          n=$(grep -c . "$NIXOS_QA_DEFERRED" || true)
          deferred=$(paste -sd, "$NIXOS_QA_DEFERRED")
          if [ "$n" -gt 0 ]; then
            echo "nixos-qa: $result, but $n check(s) were not built here, deferred to their own host's gate: $(tr '\n' ' ' <"$NIXOS_QA_DEFERRED")" \
              | tee -a "''${NIXOS_QA_TIMES:-/dev/null}"
            # one line a coordinator reads: the head, then owner:check for each check its owning host must build
            echo "nixos-qa: deferred-checks head=$NIXOS_QA_HEAD checkout=$checkout $(tr '\n' ' ' <"$NIXOS_QA_DEFERRED")" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}"
          fi
          ${lib.getExe record} gate gate=nixos-qa seconds=$((SECONDS - start)) result=$result sha="$sha" mode=$mode deferred="$n" head="$NIXOS_QA_HEAD" checkout="$checkout" deferred_checks="$deferred" wait_seconds="''${HEAVY_LOCK_WAIT_SECONDS:-unknown}"
          if [ -n "$began" ]; then
            # shellcheck disable=SC2086 # the state is three words
            ${lib.getExe qaGreen} record "$0" "$result" "$mode" $began || true
          fi
        }
        trap on_exit EXIT
        # always-loaded instructions: this repo's CLAUDE.md and the global one Home Manager links (names only, no path)
        ${lib.getExe record} instructions file=repo-CLAUDE.md bytes="$(wc -c <CLAUDE.md)"
        if [ -f "$HOME/.claude/CLAUDE.md" ]; then
          ${lib.getExe record} instructions file=global-CLAUDE.md bytes="$(wc -c <"$HOME/.claude/CLAUDE.md")"
        fi
        ${timed (
          lints
          ++ [
            fmtCheck
            secretsVerify
          ]
        )}
        t=$SECONDS
        GATE_PROBE=$(${lib.getExe probe})
        export GATE_PROBE
        echo "nixos-qa: ${probe.name} took $((SECONDS - t)) s" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}"
        ${lib.getExe record} gate-step gate=nixos-qa step=${probe.name} seconds=$((SECONDS - t)) result=pass sha="$sha"
        python3 scripts/gate_probe.py coverage | jq -r 'to_entries[] | "\(.key) \(.value.assertions) \(.value.checks)"' \
          | while read -r node assertions checks; do
            ${lib.getExe record} coverage node="$node" assertions="$assertions" system_checks="$checks"
          done
        # The flake check and the four slowest tests side by side where measured safe, each into its own log,
        # printed whole and recorded per step after all ended (#502); in this order, one after the other, elsewhere
        side_by_side() {
          local dir n e r secs bad=() order=()
          dir=$(mktemp -d)
          echo "nixos-qa: side by side, each step's log in $dir"
          while [ $# -gt 0 ]; do
            n=$1 e=$2
            shift 2
            order+=("$n")
            (
              t=$SECONDS
              if "$e" >"$dir/$n.log" 2>&1; then r=pass; else r=fail; fi
              echo "$r $((SECONDS - t))" >"$dir/$n.res"
            ) &
          done
          wait
          for n in "''${order[@]}"; do
            # no .res: the step's subshell died (OOM, a signal) before writing one; its log is printed all the same
            # seconds=0, not "?": the dashboard unwraps it as a number
            if [ -f "$dir/$n.res" ]; then read -r r secs <"$dir/$n.res"; else
              r=fail secs=0
              echo "== $n: no result written (killed?)"
            fi
            echo "== $n: $r"
            cat "$dir/$n.log"
            echo "nixos-qa: $n took $secs s" | tee -a "''${NIXOS_QA_TIMES:-/dev/null}"
            ${lib.getExe record} gate-step gate=nixos-qa step="$n" seconds="$secs" result="$r" sha="$sha"
            [ "$r" = pass ] || bad+=("$n")
          done
          [ ''${#bad[@]} -eq 0 ] || { echo "nixos-qa: failed side by side: ''${bad[*]}" >&2; return 1; }
        }
        # asus only: the only host with a measured side-by-side run (24 GiB free); msi joins once its peak is measured.
        # Free memory is the smaller of the host's MemAvailable and this gate's own cgroup headroom, read once at the start:
        # a capped unit on asus saw 24 GiB available and was killed (#502)
        free_gib() {
          local avail cg max cur
          avail=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo)
          cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
          max=$(cat "$cg/memory.max" 2>/dev/null || echo max)
          if [ "$max" != max ] && cur=$(cat "$cg/memory.current" 2>/dev/null) && [ $((max - cur)) -lt "$avail" ]; then
            avail=$((max - cur))
          fi
          echo $((avail / 1073741824))
        }
        together=
        if [ "$(uname -n)" = asus-b460m ] && [ "$(free_gib)" -ge 10 ]; then together=1; fi
        if [ -n "$together" ]; then
          side_by_side ${lib.concatMapStringsSep " " (g: "${g.name} ${lib.getExe g}") sideBySide}
        else
          ${timed sideBySide}
        fi
        ${timed tests}
      '';

  # Runs the gate on the PUSHED commit in a throwaway worktree, so neither
  # unstaged edits nor a different checked-out branch can make it pass.
  # prek runs it for the first ref that brings new commits only (the shim refuses a push that brings them to
  # two refs), and not at all for a push that brings none. A push that changes only
  # documentation (docs/ or a top-level *.md) since origin/main gets the lints, plus the tests that read a changed doc
  # (a scripts/test-* names it: CLAUDE.md, docs/ssh-host-keys.md); no merge-base means the full gate, and so does a
  # nested *.md, which can be deployed config. On top of a green tree, a doc a test reads still means the full gate.
  # A docs-only push on top of a main merged on GitHub skips that combined tree's first full gate.
  # A green full gate records the tree in the clone's git dir with the gate executable and the system generation
  # (tests run its tools); that tree, or it plus documentation, gets the lints. Nothing else is keyed: a flaky green,
  # an age key or the caller's PATH are not re-sampled until the record is deleted (nixos-qa-green).
  qaPush =
    gate "nixos-qa-push"
      (with pkgs; [
        git
        coreutils
        gnugrep
      ])
      ''
        rev=''${PRE_COMMIT_TO_REF:-HEAD}
        # where the devenv was entered: its local overrides are untracked, so the pushed worktree has none
        entered=$PWD
        case $rev in 0000000000000000000000000000000000000000) exit 0 ;; esac
        tree=$(mktemp -d)
        trap 'git worktree remove --force "$tree"' EXIT
        git worktree add --quiet --detach "$tree" "$rev"
        cd "$tree"
        # In a linked worktree git hands the hook its GIT_DIR: HEAD, the lints' git ls-files and git under qa
        # would all follow that checkout, not this tree. The siblings are unset for a tool that exports them.
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        # the hook runs the gate evaluated at devenv entry: the pushed tree's devenv files must be what it was built from,
        # or even the lints-only and green paths below would judge it with an old list
        ${lib.getExe devenvFresh} "$entered"
        # --no-renames: a file moved into docs/ still counts on its old side. The list is taken whole first:
        # grep -q quitting early would SIGPIPE git diff, and pipefail would turn that into "docs only".
        docs_only() {
          local changed
          changed=$(git diff --no-renames --name-only "$1" HEAD --) \
            && ! grep -qvE '^docs/|^[^/]+\.md$' <<<"$changed" && ! grep -rqF -f - --include='test-*' scripts <<<"$changed"
        }
        # Two pushes trimming at once can lose a line: a step time, or a record, which only costs a full gate.
        trim() { if tail -n "$2" "$1" > "$1.$$" 2>/dev/null; then mv "$1.$$" "$1"; else rm -f "$1.$$"; fi; }
        # the tests that read a changed doc, when every change since $1 is documentation
        readers() {
          local changed
          changed=$(git diff --no-renames --name-only "$1" HEAD --) \
            && ! grep -qvE '^docs/|^[^/]+\.md$' <<<"$changed" && grep -rlF -f - --include='test-*' scripts <<<"$changed"
        }
        if base=$(git merge-base HEAD origin/main) && docs_only "$base"; then
          echo "nixos-qa: $(git rev-parse --short HEAD) changes only documentation since origin/main, lints only"
          ${run lints}
          exit
        fi
        if [ -n "$base" ] && r=$(readers "$base"); then
          mapfile -t read_by <<<"$r"
          echo "nixos-qa: $(git rev-parse --short HEAD) changes only documentation since origin/main, read by ''${read_by[*]}: the lints and those tests"
          ${run lints}
          ${lib.getExe docTests} "''${read_by[@]}"
          exit
        fi
        gitdir=$(git rev-parse --path-format=absolute --git-common-dir)
        green=$gitdir/nixos-qa-green
        gate="${lib.getExe qa} $(readlink -f /run/current-system)"
        this=$(git rev-parse 'HEAD^{tree}')
        # The hex check keeps a damaged line from reaching git diff as an option; an unreadable record runs the full gate.
        while read -r passed with; do
          if [ "$with" = "$gate" ] && [[ $passed =~ ^[0-9a-f]{40,64}$ ]] \
            && { [ "$passed" = "$this" ] || docs_only "$passed" 2>/dev/null; }; then
            echo "nixos-qa: $(git rev-parse --short HEAD) is tree ''${passed:0:12} green under this gate and generation, or that plus documentation: lints only"
            { ${run lints}; } </dev/null
            exit
          fi
        done < <(tail -n 50 "$green" 2>/dev/null || true)
        NIXOS_QA_TIMES=$gitdir/nixos-qa-times
        export NIXOS_QA_TIMES
        trim "$NIXOS_QA_TIMES" 2000
        echo "$(date -Is) nixos-qa on pushed commit $(git rev-parse --short HEAD)" | tee -a "$NIXOS_QA_TIMES"
        ${lib.getExe qa}
        # A switch during the run leaves a green that no key describes.
        if [ "$gate" = "${lib.getExe qa} $(readlink -f /run/current-system)" ]; then
          { echo "$this $gate" >> "$green" && trim "$green" 50; } || echo "nixos-qa: green tree not recorded in $green" >&2
        fi
      '';

  # Operator side of the naked-pi RF kit. Each SSHes the Pi (the `naked-pi` ssh
  # alias), runs one bounded wrapper there, and keeps analysis on this host.
  # Mostly passive; deauth is limited to our own AP's enrolled stations
  # (rf:ap-kick, rf:ap-kick-hil) — never injection or a third-party network.
  rfBeacons =
    gate "rf-beacons"
      (with pkgs; [
        openssh
        coreutils
        gawk
        gnugrep
        wireshark-cli
      ])
      ''
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

  rfCapture =
    gate "rf-capture"
      (with pkgs; [
        openssh
        coreutils
      ])
      ''
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
  naked =
    name: preamble: cmd:
    gate name [ pkgs.openssh ] ''
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

  rfList =
    gate "rf-list"
      (with pkgs; [
        openssh
        coreutils
      ])
      ''
        exec >&2  # devenv captures task stdout; stream the listing instead
        echo "== naked-pi /var/lib/rf-lab/captures:"
        ssh -o BatchMode=yes -o ConnectTimeout=10 naked-pi 'ls -la /var/lib/rf-lab/captures 2>/dev/null || echo "(none)"'
        echo "== local $HOME/rf-lab-captures:"
        ls -la "$HOME/rf-lab-captures" 2>/dev/null || echo "(none)"
      '';

  # Offline pre-deploy gate: the management-safety invariants are modules/roles/rf-lab.nix assertions, so evaluating naked-pi checks them.
  rfPreflight = gate "rf-preflight" (with pkgs; [ nix ]) ''
    exec >&2
    nix eval --raw ".#nixosConfigurations.naked-pi.config.system.build.toplevel.drvPath" >/dev/null
    echo "PREFLIGHT PASS: safe to deploy over Ethernet"
  '';

  # Offline analysis of a capture (no device involved): management-frame
  # breakdown and, crucially, any deauth/disassoc frames with their reason codes
  # — how you recognise a disconnect in a trace without transmitting anything.
  rfAnalyze =
    gate "rf-analyze"
      (with pkgs; [
        coreutils
        gawk
        wireshark-cli
      ])
      ''
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

  # The Rust beacon table of rf-proto (#42 slice 6) on a local capture; reads the file only. Its parity with
  # rf:beacons' tshark table is checks.rf-beacons-parity (flake check, so nixos:qa)
  rfBeaconTable =
    gate "rf-beacon-table"
      (with pkgs; [
        nix
        coreutils
      ])
      ''
        exec >&2
        # shellcheck disable=SC2012
        f=''${RF_PCAP:-$(ls -t "$HOME"/rf-lab-captures/*.pcap* 2>/dev/null | head -1)}
        [ -n "$f" ] && [ -r "$f" ] || { echo "no capture: set RF_PCAP=<file.pcap> (or run rf:beacons first)"; exit 1; }
        b=$(nix build --no-link --print-out-paths .#rf-beacons-rs)
        printf '%-18s %3s %5s %5s  %s\n' BSSID CH dBm beac SSID
        "$b/bin/rf-beacons-rs" "$f" "$b/share/rf-beacons-rs/oui-sample.csv" --text
      '';

  rfBeaconsTest =
    gate "rf-beacons-test"
      (with pkgs; [
        bash
        wireshark-cli
        gawk
        coreutils
        gnugrep
      ])
      ''
        bash scripts/rf-beacons-test.sh
      '';

  # Offline classification test: assert rf:analyze's decode recognises each
  # crafted fixture (beacon count, deauth/disassoc reason codes). No device.
  rfAnalyzeTest =
    gate "rf-analyze-test"
      (with pkgs; [
        bash
        wireshark-cli
        coreutils
        gnugrep
      ])
      ''
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
  embeddedFlash =
    gate "embedded-flash"
      (with pkgs; [
        openssh
        coreutils
      ])
      ''
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

  task = description: app: {
    inherit description;
    exec = lib.getExe app;
  };

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
  imports = [
    "${inputs.platform}/modules/commit-conventions.nix"
    "${inputs.platform}/modules/git-hooks-worktree.nix"
  ];

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
    "nixos:lint-comments" =
      task "Comment Policy lint (density, forbidden shapes, path pointers that resolve to no tracked file)" lintComments;
    "nixos:lint-shell" = task "shellcheck scripts/*.sh" lintShell;
    "nixos:deploy-rs-pins" =
      task "deploy-rs's rev agrees in devenv.yaml, devenv.lock and flake.lock (seeded: each drift fails with both revs)" deployRsPins;
    "nixos:fmt-check" =
      task "nix fmt -- --ci: the flake's formatter fails on any file it would change (and rewrites it)" fmtCheck;
    "nixos:secrets-verify" =
      task "Decrypt-check wifi credentials (skips without an age key)" secretsVerify;
    "nixos:nvim-check" = task "Build lenovo's nvim and start the generated config headless" nvimCheck;
    "nixos:flake-check" =
      task "The flake check over all systems, one output per nix process: builds every x86 host, evaluates the Pis" flakeCheck;
    "nixos:claude-settings-test" =
      task "Generated Claude settings: default mode, bypass on request, no OTLP leak" claudeSettingsTest;
    "nixos:ollama-portforward-test" =
      task "lenovo ollama-portforward: a wedged forward is restarted, an HTTP error is not" ollamaPortforwardTest;
    "nixos:ollama-pull-pinned-test" =
      task "ollama-pull-pinned: a tag at its pin is left alone, a moved tag is removed again and fails the loader" ollamaPullPinnedTest;
    "nixos:ollama-gpu-test" =
      task "A CUDA Ollama build without hardware.graphics is rejected (it would run on the CPU)" ollamaGpuTest;
    "nixos:llm-bench-test" =
      task "llm-bench (#493): #492's G1 bench and the capacity run against the fake Ollama, the G1 import and rule, quantile floors, the MSI import, no prompt in an aggregate" llmBenchTest;
    "nixos:alert-bridge-test" =
      task "lenovo alone runs alert-bridge: sandboxed, publishing to the native ntfy on loopback, the built binary starts" alertBridgeTest;
    "nixos:dual-boot-test" =
      task "msi and asus GRUB from windows-dual-boot.nix: the Windows entry chainloads bootmgfw.efi, the ESP is a vfat mount, the seeded ESP breaks fail" dualBootTest;
    "nixos:coordinator-test" =
      task "Coordinator adapters on lenovo only; Codex agent via config_file, no model pin" coordinatorWiringTest;
    "nixos:coordinator-report-test" =
      task "The coordinator-report job: an even ISO week renders the two weeklies before it, an odd week exits 0 without devenv" coordinatorReportTest;
    "nixos:worker-permissions-test" =
      task "#145/#157/#487: Herdr workers in the nspawn guests start in bypassPermissions, a restored pane too, and switch models on a safeguards flag; every host accepts cross-session messages; plain claude and the Coordinator (dontAsk) keep their modes" workerPermissionsTest;
    "nixos:workers-eval-test" =
      task "The developer-environment module rejects each wrong configuration at eval; agent argv survives the guest shell" workersEvalTest;
    "nixos:bulk-reader-test" =
      task "sam.claude.bulkReader: shunt hooks only when on and the skills pin has them, after the existing Bash hooks; guests via a guest module" bulkReaderTest;
    "nixos:harness-telemetry-test" =
      task "sam.claude.telemetry: Claude exports through the local relay with session and repository attributes; emit-work-ref.sh only when on and pinned" harnessTelemetryTest;
    "nixos:known-hosts-test" =
      task "Verified SSH host keys pinned fleet-wide, clients and deploy-rs fail closed, each declared sops secret encrypted to its host and present in its file" knownHostsTest;
    "nixos:systemd-calendar-test" =
      task "The systemd-calendar check passes parsing NixOS and Home Manager timer specs and fails, naming the timer (and user), on a bad one (fixture trees)" systemdCalendarTest;
    "nixos:systemd-verify-test" =
      task "The systemd-verify check passes a clean tree and fails, printing the line, on an unknown key, unknown section, unparseable value, non-absolute path, removed option or refused unit, in system or Home Manager units (fixture trees)" systemdVerifyTest;
    "nixos:power-schedule-test" =
      task "The fleet's night from the fleet facts: lenovo wakes each window host, each powers itself off, the quiet hosts throttle from the clock (decision tested over the edges and midnight), the seeded breaks fail" powerScheduleTest;
    "nixos:readability-test" =
      task "Docs state the hosts.nix fleet size and README lists every host; every sam.*/homelab.* option leaf has a description (fleet.nix's owed); seeded breaks fail" readabilityTest;
    "nixos:adguard-dns-test" =
      task "lenovo's AdGuard: not from /etc/hosts, every fleet name its fleet address, the loopback seeds fail" adguardDnsTest;
    "nixos:delegation-test" =
      task "lenovo's generated devenv.local.nix delegates approval to an interactive Coordinator (real devenv, fake gh)" delegationTest;
    "nixos:build-bounds-test" =
      task "nix-daemon builds are bounded (cores, jobs, MemoryHigh/Max) on lenovo and the environment hosts; lenovo's user slice has a ceiling" buildBoundsTest;
    "nixos:qa-push-test" =
      task "The pre-push hook without Nix: a green tree is recorded per gate and generation, by the hook or a clean manual nixos:qa, lints only for it plus docs, a linked worktree is judged on the pushed commit; the shim refuses new commits to two refs; nixos:qa takes the heavy-work lock once (an ancestor's counts); a deferred check is recorded owner:check per head, and built by its owner; deferred-checks.py says which still wait for their owner" qaPushTest;
    "nixos:journal-collector-test" =
      task "homelab.journalCollector on msi only: journald to Loki, no secret, a local readiness probe" journalCollectorTest;
    "nixos:fleet-endpoints-test" =
      task "Every paging unit pages sam.fleet.pageUrl, also without runtime-host's sam.workers.ntfyUrl; an empty URL, ntfy off its fleet host and a redefined fleet fact fail" fleetEndpointsTest;
    "nixos:fleet-contract-test" =
      task "No file but fleet.nix names the ntfy or Loki port; every host's firewall admits each sam.fleet listener from its callers alone and opens nothing else, no service the probe reads binds off its listener's port; lenovo's machines and jump hosts are hosts.nix's runtime hosts (seeded: an open port, an upstream openFirewall, a stray rule, a trusted interface, a host removed)" fleetContractTest;
    "nixos:seventh-host-test" =
      task "Also on demand (then it records its own gate-step): a seventh host seeded from fixture data (its hosts.nix and fleet.nix entries, hosts/seventh) into a temporary tree: it evaluates, every list derived from the fleet names it, only the hosts rendering one move; the places it still needs edited by hand are listed exactly (seeded: each derived list hard-coded without it)" seventhHostTest;
    "nixos:alloy-otlp-test" =
      task "acer's alloy-otlp unit, as evaluated, on its own Alloy: log prompts, identities and trace ids never reach Loki (metric exemplars stop at acer's queue: Prometheus stores none)" alloyOtlpTest;
    "nixos:trash-sweep-test" =
      task "The environments' .trash sweep, its core.nix text run: a week-old entry goes, a fresh one and a live dir stay, a .trash that is a link, a file or another mount is refused; each timer run records its counts, never a name" trashSweepTest;
    "nixos:guest-records-test" =
      task "The host ships guest platform records on a fake Loki: each line once, also after a rewrite; host labels only; label keys, unknown kinds, oversize and too-old lines dropped; 500 per run; a link or FIFO on the spool's path refused; trashOne ships before its rename" guestRecordsTest;
    "nixos:platform-records-test" =
      task "Platform health records: dashboard kinds match the helper and its callers, labels job/kind/host only, a down Loki or unknown kind never fails the caller" platformRecordsTest;
    "nixos:measurement-test" =
      task "Measurement doc and targets: every metric in both with the same fields, a live one with a query, target and a panel reading the same kinds and series, at most six per area or a named exception, a max age per record kind" measurementTest;
    "nixos:scorecard-test" =
      task "The packaged platform scorecard on a fake Prometheus and Loki: pass and fail against the threshold, no query, a failed, empty or non-number reading unknown, a quiet record kind stale, an unreachable or unready backend exits 2; the real targets with no answers: nothing passes" scorecardTest;
    "nixos:shipping-metrics-test" =
      task "Shipping collector on a fake GitHub and Loki: issues split actionable/parked/archived, a failed source leaves no series and keeps its stale timestamp, an undeclared name is refused" shippingMetricsTest;
    "nixos:trigger-rollback-test" =
      task "The rebuild trigger's rollback on stubs: back to the previous generation live, in the system profile and the boot default, without nixos-rebuild; a failed step is audited (seeded: the old nixos-rebuild boot --rollback line fails)" triggerRollbackTest;
    "nixos:wait-metrics-test" =
      task "The dashboards check's exporter wait: a late exporter is waited for; none listening, no expected series or an exited exporter fails as 'exporter did not start' within its bound" waitMetricsTest;
    "nixos:nav-metrics-test" =
      task "Navigation collector on fixture transcripts: counts, misses and repeat reads by role, no prompt, command or path in the textfile, a thin role writes its sample size alone, a failed section is a series" navMetricsTest;
    "nixos:app-bump-dry-run-test" =
      task "App pin bump dry run on a fake GitHub: a replay is an empty diff, red, pending and unchecked heads are skipped for an older green one, narHash pending, an unallowlisted repo and a non-40-hex rev refused naming the field; the bump on stubs: only the registry entry moves, on a branch from origin/main, then commit, push and PR, refused on lenovo" appBumpDryRunTest;
    "nixos:typed-interfaces-test" =
      task "no types.attrs option and no `or` fallback on a sam.* option read; seeded snippets of both are caught" typedInterfacesTest;
    "nixos:system-checks-test" =
      task "just checks against stub nix/ssh: lists built or substituted, and refuses an empty list, a non-input, an unreachable host, a failed build and a still-invalid check" systemChecksTest;
    "nixos:deploy-recipes-test" =
      task "just deploy and dry-activate against stub nix/ssh/systemctl: a looping unit fails the post-deploy check, a failed dry activation or closure diff fails dry-activate though deploy-rs reports success" deployRecipesTest;
    "nixos:caddy-edge-test" =
      task "acer's Caddy edge, as caddy adapt reads it: admin off, every name routed, forward auth before chat and grafana, otlp allowlisted, llm-gateway /v1 only" caddyEdgeTest;
    "nixos:authentik-ak-test" =
      task "acer's ak: lifecycle/ak as authentik in the server unit's sandbox and environment, the env file by path" authentikAkTest;
    "nixos:switch-safety-test" = task "A switch survives a bad ~/.claude.json" switchSafetyTest;
    "nixos:qa" = task "Every gate above, in order" qa;
    "platform:scorecard" = {
      description = "Every metric in metrics/targets.json read from Prometheus and Loki: reading, target and pass, fail, stale or unknown per area; exits 2 when a backend is unreachable (SCORECARD_PROMETHEUS_URL, SCORECARD_LOKI_URL override sam.fleet's)";
      exec = "${lib.getExe scorecard} \"$DEVENV_ROOT/metrics/targets.json\"";
    };

    "rf:beacons" = task "naked-pi: passive 2.4 GHz beacon sweep -> AP table" rfBeacons;
    "rf:capture" =
      task "naked-pi: bounded monitor capture (RF_CHANNEL, RF_SECONDS, RF_BSSID)" rfCapture;
    "rf:btscan" = task "naked-pi: passive Bluetooth/BLE discovery (RF_SECONDS)" rfBtScan;
    "rf:list" = task "naked-pi: list captures on the Pi and locally" rfList;
    "rf:analyze" =
      task "offline pcap analysis: mgmt frames + deauth/disassoc reason codes (RF_PCAP)" rfAnalyze;
    "rf:beacons-test" =
      task "offline: rf:beacons' AP table on the crafted fixtures: hidden SSIDs, escaped control bytes (#42)" rfBeaconsTest;
    "rf:beacon-table" =
      task "offline: the Rust (rf-proto) beacon table of a local pcap (RF_PCAP, default newest)" rfBeaconTable;
    "rf:analyze-test" =
      task "offline: assert rf:analyze classifies the crafted pcap fixtures" rfAnalyzeTest;
    "rf:sim" =
      task "naked-pi: fully-virtual hwsim Wi-Fi lab (assoc + iperf3 + disconnect/recover)" rfSim;
    "rf:ap-outage" = task "naked-pi: bounded outage of the lab's own AP (RF_SECONDS)" rfApOutage;
    "embedded:discover" =
      task "naked-pi: espflash board-info (chip, revision, flash, MAC)" embeddedDiscover;
    "embedded:flash" =
      task "naked-pi: flash FW_ELF to the board (dry-run; EMBEDDED_COMMIT=1, EMBEDDED_PORT)" embeddedFlash;
    "rf:preflight" = task "naked-pi: offline pre-deploy safety-invariant gate" rfPreflight;
    "rf:ap-status" = task "naked-pi: list stations associated to the lab AP" rfApStatus;
    "rf:ap-kick" =
      task "naked-pi: evict an enrolled station from our own AP (RF_MAC, RF_COMMIT)" rfApKick;
    "rf:ap-kick-hil" =
      task "naked-pi: two-radio hardware-in-the-loop rf-ap-kick (Ethernet-gated; RF_HIL_COMMIT)" rfApKickHil;
    "rf:bt-status" = task "naked-pi: Bluetooth controller + paired-device status" rfBtStatus2;
    "rf:bt-disconnect" =
      task "naked-pi: disconnect an enrolled paired BT device (RF_MAC, RF_COMMIT)" rfBtDisconnect;
    "rf:bt-outage" = task "naked-pi: bounded local BT adapter power-off/on (RF_SECONDS)" rfBtOutage;
  };

  git-hooks.hooks = {
    nixos-lint-comments = hook "Comment Policy lint" "pre-commit" lintComments;
    nixos-lint-shell = hook "shellcheck" "pre-commit" lintShell;
    nixos-deploy-rs-pins = hook "deploy-rs pins agree" "pre-commit" deployRsPins;
    nixos-qa-push = hook "Full QA on the pushed commit" "pre-push" qaPush;
  };
}
