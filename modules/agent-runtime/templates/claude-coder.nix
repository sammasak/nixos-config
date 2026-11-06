# The #169 coding-agent template: the real Claude Code binary on a disposable pinned Rust repository
# (sammasak/rf-proto at the flake's rev, zero dependencies, so its tests build offline). Network off
# and no credential by default: the runner fails closed without one. A live run uses the owner's Claude
# Code subscription token (the SOPS `claude_oauth_token`, `start --credential FILE`) and an egress
# allowlist for the API host, both owner-gated (docs/agent-runtime-coder.md). The template grants no
# GitHub capability.
{ config, pkgs, ... }:
let
  src = config.sam.agentRuntime.pinnedSources;
  t = config.sam.agentRuntime.templates.claude-coder;
  repo = t.repositories.rf-proto.path;
  claude = pkgs.claude-code;
  # the tools the agent may use without asking; anything else is refused in -p mode
  allowedTools = "Read,Edit,Write,Glob,Grep,Bash(cargo test:*),Bash(cargo build:*),Bash(git diff:*),Bash(git status:*)";
  run = pkgs.writeShellApplication {
    name = "claude-coder-run";
    runtimeInputs = [ claude pkgs.cargo pkgs.rustc pkgs.gcc pkgs.git pkgs.jq pkgs.coreutils ];
    text = ''
      out=''${AGENT_RUNTIME_OUTPUT:?not in an agent-runtime instance}
      turn=600
      if [ "''${1:-}" = --turn-seconds ]; then turn=$2; shift 2; fi
      task=''${1:?usage: claude-coder-run [--turn-seconds N] TASK}
      cred=/run/agent-runtime/credentials/token
      export CARGO_HOME=${t.filesystem.cache.path}/cargo CARGO_TARGET_DIR=${t.filesystem.cache.path}/target CARGO_NET_OFFLINE=true
      # no autoupdate, telemetry or error reporting: the only traffic a live run needs is the API itself;
      # no other auth path than the delivered subscription token. Not CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1: its
      # tool sandbox drops placeholder files (.env*, package.json, ...) into the repository, so into the patch;
      # 2.1.300 withholds CLAUDE_CODE_OAUTH_TOKEN from tools without it (docs/agent-runtime-coder.md)
      export DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
      seal() { (cd "$out" && sha256sum -- * 2>/dev/null | grep -v ' SHA256SUMS$' >SHA256SUMS || true); }
      result() { jq -n "$@" >"$out/result.json"; seal; }
      cd ${repo}
      # fail closed: without a delivered subscription token the model is never called
      if [ ! -s "$cred" ]; then
        result '{agent: "claude-code", auth: "missing", claudeExit: null, testsExit: null, exit: 77}'
        echo "claude-coder-run: no Claude Code token at $cred; refusing to run the agent" >&2
        exit 77
      fi
      # every pinned egress host must accept TCP 443 within seconds, or the run stops at once with a clear
      # error instead of claude retrying until the turn bound (#169: a live run hung 600 s with no egress)
      while read -r ip name _; do
        case $ip in 127.* | ::1 | "") continue ;; esac   # loopback (nspawn's own entries), not egress
        # shellcheck disable=SC2016  # $1 expands in the inner bash, by design
        if ! timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$name" 2>/dev/null; then
          jq -n --arg h "$name" --arg ip "$ip" '{agent: "claude-code", auth: "oauth-token", egress: "unreachable", host: $h, ip: $ip, claudeExit: null, testsExit: null, exit: 75}' >"$out/result.json"
          seal
          echo "claude-coder-run: egress to $name ($ip):443 did not connect within 8 s; not starting the agent" >&2
          exit 75
        fi
      done < <(grep -v '^[[:space:]]*#' /etc/hosts)
      rc=0
      # the token goes to the claude process's environment only (no file the agent writes); the credential
      # file itself is denied to the Read tool
      CLAUDE_CODE_OAUTH_TOKEN=$(<"$cred") timeout -k 10 "$turn" claude -p "$task" --output-format json \
        --permission-mode acceptEdits --allowedTools "${allowedTools}" --max-turns 30 \
        --settings '{"permissions":{"deny":["Read(//run/agent-runtime/credentials/**)"]}}' \
        >"$out/claude.json" 2>"$out/claude.err" || rc=$?
      trc=0
      cargo test --offline --locked >"$out/cargo-test.log" 2>&1 || trc=$?
      jq -n --argjson rc "$rc" --argjson trc "$trc" --slurpfile c <(jq -c . "$out/claude.json" 2>/dev/null || echo null) \
        '{agent: "claude-code", auth: "oauth-token", claudeExit: $rc, timedOut: ($rc == 124),
          claude: ($c[0] | if . then {is_error, terminal_reason, num_turns, total_cost_usd} else null end),
          testsExit: $trc, exit: (if $rc != 0 then $rc else $trc end)}' >"$out/result.json"
      seal
      if [ "$rc" -ne 0 ]; then exit "$rc"; fi
      exit "$trc"
    '';
  };
in
{
  sam.agentRuntime.templates.claude-coder = {
    role = {
      name = "rust-worker";
      harness = "claude-code";
    };
    repositories.rf-proto = {
      github = "sammasak/rf-proto";
      ref = {
        type = "commit";
        value = src.rf-proto.rev;
      };
      lock = src.rf-proto;
      path = "/workspace/rf-proto";
      writable = true;
    };
    skillsSource = src.skills;
    skills.rust-engineering = { };
    packages = [ run claude pkgs.cargo pkgs.rustc pkgs.gcc pkgs.git pkgs.jq pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk ];
    filesystem = {
      workspaceBudget = { sizeMiB = 64; inodes = 4000; };
      home = { sizeMiB = 256; inodes = 4000; };
      tmp = { sizeMiB = 512; inodes = 20000; };
      cache = { sizeMiB = 1024; inodes = 20000; };
      output = { sizeMiB = 64; inodes = 100; };
    };
    resources = {
      cpus = 2;
      memoryMiB = 2048;
      tasksMax = 512;
      timeoutMinutes = 30;
    };
    # network.allow stays null (no egress) and capabilities empty (no GitHub token, ever)
  };
}
