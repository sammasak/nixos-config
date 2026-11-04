import json
import os
import pathlib
import re
import subprocess
import sys
import tomllib

COORDINATOR_FILES = {".claude/agents/coordinator.md"}


def nix(*args):
    return subprocess.run(["nix", *args], check=True, capture_output=True, text=True).stdout.strip()


def home_files(host):
    attr = f".#nixosConfigurations.{host}.config.home-manager.users.lukas.home.file"
    return set(json.loads(nix("eval", "--json", attr, "--apply", "builtins.attrNames")))


def check(condition, message):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)
    print(f"PASS: {message}")


def main():
    skills = pathlib.Path(nix("eval", "--raw", "--impure", "--expr",
                              "(builtins.getFlake (toString ./.)).inputs.skills.outPath"))
    role_path = skills / "agents/coordinator/ROLE.md"
    front = json.loads(subprocess.run(["yq", "--front-matter=extract", "-o=json", ".", str(role_path)],
                                      check=True, capture_output=True, text=True).stdout)
    role_skills = front["skills"]

    common = (skills / "task-modules/common.nix").read_text()
    check("mayApprove = lib.mkOption { type = t.bool;" in common and "approvalDecision = lib.mkOption { type = t.nullOr t.str;" in common
          and "panes = lib.mkOption { type = t.str;" in common,
          "the pinned skills input declares coordinator.mayApprove (bool), approvalDecision (nullable string) and panes (comma string) (skills#53, #54), the types the fixed options use")

    lenovo, acer = home_files("lenovo"), home_files("acer-swift")
    check(COORDINATOR_FILES <= lenovo, "lenovo links the Claude and Codex coordinator adapters")
    check(not any(f.startswith("claude-code-skills/") for f in lenovo | acer), "Home Manager writes nothing into the skills checkout")
    check(not COORDINATOR_FILES & acer, "acer, a worker, links no coordinator adapter")
    check(".claude/agents/quality.md" in acer, "acer keeps the other role adapters")
    for name in role_skills:
        check(f".agents/skills/{name}" in lenovo, f"lenovo's Codex has the coordinator skill {name}")
        check(f".agents/skills/{name}" not in acer, f"acer's Codex does not get the coordinator skill {name}")

    for host, files in (("lenovo", lenovo), ("acer-swift", acer)):
        check(not any(f.startswith(".codex/agents/") for f in files),
              f"{host} links nothing into ~/.codex/agents (Codex refuses a symlinked role file at spawn)")

    def codex_config(host):
        attr = f'.#nixosConfigurations.{host}.config.home-manager.users.lukas.home.file.".codex/config.toml".text'
        return tomllib.loads(nix("eval", "--raw", attr))

    lenovo_cfg, acer_cfg = codex_config("lenovo"), codex_config("acer-swift")
    for host, cfg in (("lenovo", lenovo_cfg), ("acer-swift", acer_cfg)):
        check("model" not in cfg, f"{host}'s Codex config pins no model (the account default applies)")
    check("coordinator" not in acer_cfg.get("agents", {}), "acer's Codex declares no coordinator agent")

    role_file = lenovo_cfg.get("agents", {}).get("coordinator", {}).get("config_file", "")
    check(role_file == str(skills / "agents/coordinator/codex.toml"),
          "lenovo declares agents.coordinator.config_file as the shipped codex.toml in the pinned input")
    # Codex re-reads config_file at spawn with O_NOFOLLOW (codex-rs/exec-server/src/regular_file.rs, rust-v0.162.1)
    fd = os.open(role_file, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        agent = tomllib.loads(f.read())
    check(True, "the role file opens with O_NOFOLLOW, as Codex reads it at spawn")
    check(agent["name"] == "coordinator", "the Codex agent is named coordinator")
    check("agents/coordinator/ROLE.md" in agent["developer_instructions"], "the Codex instructions point at the pinned ROLE.md")
    check(agent["description"].strip() != "", "the Codex agent has a description")


    def user_units(host, kind):
        attr = f".#nixosConfigurations.{host}.config.home-manager.users.lukas.systemd.user.{kind}"
        return json.loads(nix("eval", "--json", attr))

    lenovo_timers, acer_timers = user_units("lenovo", "timers"), user_units("acer-swift", "timers")
    lenovo_services = user_units("lenovo", "services")
    check("coordinator-wakeup" in lenovo_timers and "coordinator-wakeup" in lenovo_services,
          "lenovo has the coordinator-wakeup timer and service")
    check("coordinator-wakeup" not in acer_timers, "acer, a worker, has no coordinator-wakeup timer")
    timer = lenovo_timers["coordinator-wakeup"]["Timer"]
    check(timer["Unit"] == "coordinator-wakeup.service" and timer["OnUnitInactiveSec"] == "2min",
          "the timer re-arms 2min after the service went inactive (never while a session runs)")
    service = lenovo_services["coordinator-wakeup"]["Service"]
    exec_start = service["ExecStart"] if isinstance(service["ExecStart"], list) else [service["ExecStart"]]
    check(service["Type"] == "oneshot" and len(exec_start) == 1 and exec_start[0].endswith("/bin/coordinator-wakeup"),
          "the service is a oneshot running the coordinator-wakeup script")
    check(any(e.startswith("PATH=/run/current-system/sw/bin:") for e in service["Environment"]),
          "the service sees devenv and claude through the system and user profiles")
    script = nix("eval", "--raw", ".#nixosConfigurations.lenovo.config.home-manager.users.lukas.home.packages",
                 "--apply", 'ps: (builtins.head (builtins.filter (p: (p.name or "") == "coordinator-wakeup") ps)).text')
    check('devenv tasks run coord:changed --input-json \'{"consume":true}\'' in script, "the timer runs coord:changed in its consuming form")
    # the owner's skills config for the host rides on every devenv call as fixed --option flags (sam.herdr.coordinatorWakeup);
    # the exact flags are the contract: the delegation, the decision it cites, the Coordinator's pane
    OPTS = ("--option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string "
            "'https://github.com/sammasak/skills/issues/28#issuecomment-6629911996' --option coordinator.panes:string lenovo-21CB001PMX/wM:p1")
    check('devenv tasks run coord:changed --input-json \'{"consume":true}\' ' + OPTS + " >" in script,
          "the timer's coord:changed carries the host's fixed skills options: delegated approval citing the owner's decision comment, the Coordinator's pane")
    check("does not exist" in script and "older than the pinned skills input" in script and "pull --ff-only origin main" in script,
          "a checkout that lacks the options (older than the pin) is named in the journal and toasted, not retried silently")
    quiet = script.index('if [ ! -s "$pending" ]; then')
    check(quiet < script.index("claude -p") and "  exit 0\nfi\n" in script[quiet:script.index("claude -p")],
          "the script exits before any model call when nothing is actionable or pending")
    check("claude -p --agent coordinator --max-budget-usd" in script, "the session is headless, the coordinator agent, spend-capped")
    check(script.index("flock -w 20 9") < script.index("devenv tasks run coord:changed"), "the lock is taken before coord:changed runs, so two runs never race on the snapshot")
    check("--disallowedTools 'Bash(devenv:*)'" in script and "'Bash(herdr agent prompt:*)'" in script and "'Bash(gh:*)'" in script
          and "'Bash(git:*)'" in script and "'Bash(ssh:*)'" in script and "'Bash(sudo:*)'" in script and "Edit Write" in script,
          "the headless session cannot reach devenv directly, raw herdr prompts, gh, git, ssh, sudo or file edits")
    # the allow list is the contract the owner approved (skills#28): any change here is a deliberate change to this test
    tools = script.split("--allowedTools")[1].split("> \"$report\"")[0]
    allowed = re.findall(r"'([^']+)'", tools.split("--disallowedTools")[0])
    denied = [q or bare for q, bare in re.findall(r"'([^']+)'|\b(Edit|Write|NotebookEdit)\b", tools.split("--disallowedTools")[1])]
    check(allowed == ["Read(//home/lukas/claude-code-skills/**)", "Read(//home/lukas/.local/state/coordinator/**)",
                      "Bash(cd ~/claude-code-skills:*)", "Bash(cd /home/lukas/claude-code-skills:*)",
                      "Bash(coordinator-read:*)", "Bash(coordinator-act:*)", "Bash(coordinator-prompt:*)",
                      "Bash(herdr machine list:*)", "Bash(herdr machine status:*)", "Bash(herdr agent list:*)",
                      "Bash(herdr agent get:*)", "Bash(herdr agent read:*)", "Bash(herdr agent wait:*)"],
          f"the allow list is exactly the three wrappers, cd into the checkout, Herdr's read commands and the two Read scopes (got {allowed})")
    check(denied == ["Bash(devenv:*)", "Bash(herdr agent prompt:*)", "Bash(herdr agent send-keys:*)", "Bash(herdr agent start:*)",
                     "Bash(herdr --machine:*)", "Bash(herdr pane:*)", "Bash(gh:*)", "Bash(git:*)", "Bash(ssh:*)", "Bash(sudo:*)",
                     "Edit", "Write", "NotebookEdit"],
          f"the deny list is exactly devenv, raw Herdr writes and --machine, gh, git, ssh, sudo and the file-editing tools (got {denied})")
    check(not any(t.startswith(("Bash(cat", "Bash(jq", "Bash(tee", "Bash(sed", "Bash(bash", "Bash(sh", "Bash(python")) for t in allowed),
          "no shell read, write or interpreter primitive is allowed")
    check("coordinator-act <task>" in script and "coordinator-prompt [--machine <label>] <agent_id> /clear|/compact" in script
          and "the label gate stays the authority" in script and "This session only reports" not in script,
          "the wake prompt names the act and prompt wrappers and the label gate, and no longer says the session only reports")
    check("The owner delegated approval (coordinator.mayApprove, decision https://github.com/sammasak/skills/issues/28#issuecomment-6629911996)" in script
          and "never a PR, never one carrying needs-live, blocked or needs-decision) may get the approved label through coordinator-act gh:label, one issue per call" in script
          and "Never hand off to a Coordinator pane (coord:handoff and herdr:message refuse one; coordinator.panes names them), only to workers." in script,
          "the wake prompt states the owner's delegation (approve issues a worker can finish through coordinator-act gh:label, citing the decision) and that a Coordinator pane is never a handoff target")
    check("is not flagged needs_owner is free" in script and "Never two implementation handoffs for one item and never two review handoffs for the same PR head" in script
          and "a re-review of a new head or a fix-up back to the implementer is not a second implementation handoff" in script
          and "allowed_actions comment and the merge at 9 or more) for a free worker other than its implementer, then send it with herdr:message, authorized_by naming the URL and owner label" in script,
          "the prompt makes a review of an ungraded PR its own handoff for a free (idle or done) worker, drafted with coord:handoff (comment and merge allowed) and sent with herdr:message, keeping one implementation handoff per item and allowing re-reviews and fix-ups (skills#28: the 09:07Z idle wake sent nothing)")
    check(': > "$pending"; rm -f "$attempts"' in script and 'if [ "$rc" -eq 0 ]; then' in script
          and script.index("|| rc=$?") < script.index(': > "$pending"; rm -f "$attempts"', script.index('if [ "$rc" -eq 0 ]; then')),
          "pending changes and the attempt counter are cleared only after claude exited 0")
    check('[ "$rec" -nt "$state/.started" ]' in script, "a latest.json not rewritten by this run is not trusted")
    check('rm -f "$state/quiet.last"' in script and script.index('rm -f "$state/quiet.last"') < script.index("starting one Coordinator session"),
          "a session start forgets the last quiet reason, so the first quiet tick after a session is explained again")
    check('[ "$tries" -ge 2 ]' in script and 'cat "$pending" >> "$parked"' in script and script.index('[ "$tries" -ge 2 ]') < script.index("claude -p"),
          "after two failed sessions the pending lines are parked instead of buying a third")
    check("--permission-mode dontAsk" in script and "'Bash(coordinator-read:*)'" in script and "'Bash(devenv:*)'" in script
          and "'Bash(herdr --machine:*)'" in script and "Bash(devenv tasks run" not in script,
          "the session runs dontAsk; tasks only through coordinator-read, devenv itself and --machine denied")
    check("'Bash(cat:*)'" not in script and "'Bash(jq:*)'" not in script and " Read " not in script.split("--allowedTools")[1].split("--disallowedTools")[0]
          and "'Read(//home/lukas/claude-code-skills/**)'" in script and "'Read(//home/lukas/.local/state/coordinator/**)'" in script
          and "'Read(/home/lukas" not in script,
          "no shell read/write primitive; Read is scoped to the checkout and the coordinator state with // (filesystem-root) anchors, never a single slash")
    check("CLAUDE_CODE_OAUTH_TOKEN=$(cat " in script and "/.claude/.credentials.json" in script and 'log "credential source: $auth"' in script,
          "the session's credential is the OAuth token file the Fish session also uses, else credentials.json, and the source is logged")
    check("flock -w 20 9 ||" in script and "exit 75;" in script.split("flock -w 20 9 ||")[1].split("\n")[0],
          "a lock still held after 20 s ends the run non-zero and is toasted, never silently passed")
    for child, end in (("devenv tasks run coord:changed", "\n"), ("claude -p", "|| rc=$?"), ("herdr notification show", "\n")):
        check(" 9>&-" in script.split(child)[1].split(end)[0], f"fd 9 (the lock) is closed for the child '{child}'")
    check('[ -s "$parked" ] && {' in script and script.index('[ -s "$parked" ] && {') < script.index("claude -p"),
          "parked lines stop every later session until the owner clears pending.failed")
    wrapper_dirs = re.findall(r"/nix/store/[a-z0-9]+-coordinator-read/bin", script)
    check(wrapper_dirs != [], "coordinator-read is on the wake-up script's PATH")
    # realise the script (this also runs its shellcheck) so the wrapper can be read and the script exercised for real
    wakeup = nix("build", "--no-link", "--print-out-paths", "--impure", "--expr",
                 'builtins.head (builtins.filter (p: (p.name or "") == "coordinator-wakeup")'
                 ' (builtins.getFlake (toString ./.)).nixosConfigurations.lenovo.config.home-manager.users.lukas.home.packages)')
    wrapper = pathlib.Path(wrapper_dirs[0], "coordinator-read").read_text()
    check("coord:brief|coord:changed|coord:capacity|work:status|herdr:inventory|herdr:inspect|herdr:await|gh:work|gh:repos|git:recent|harness:session-summary) ;;" in wrapper
          and wrapper.count("--option") == 2 * OPTS.count("--option") and wrapper.count(OPTS) == 2 and '[ "$#" -le 2 ]' in wrapper
          and "input=$(jq -c '. + {consume:false}'" in wrapper and "consume:true" not in wrapper,
          "coordinator-read takes only one of the role's read tasks and an input object, never consumes with coord:changed, and the only --option flags are the host's fixed ones (both devenv calls)")
    check(" 9>&-" in wrapper.split("exec devenv")[1], "coordinator-read closes the lock fd before devenv")
    act_dirs = re.findall(r"/nix/store/[a-z0-9]+-coordinator-act/bin", script)
    prompt_dirs = re.findall(r"/nix/store/[a-z0-9]+-coordinator-prompt/bin", script)
    check(act_dirs != [] and prompt_dirs != [], "coordinator-act and coordinator-prompt are on the wake-up script's PATH")
    act = pathlib.Path(act_dirs[0], "coordinator-act").read_text()
    check("coord:handoff|herdr:message|gh:label|gh:comment) ;;" in act and act.count("--option") == OPTS.count("--option") and OPTS in act
          and "coord:spawn" not in act and '[ "$#" -eq 2 ]' in act and " 9>&-" in act.split("exec devenv")[1],
          "coordinator-act takes exactly one of coord:handoff, herdr:message, gh:label, gh:comment plus one input object (never coord:spawn), the only --option flags the host's fixed ones, lock fd closed")
    prompt_wrapper = pathlib.Path(prompt_dirs[0], "coordinator-prompt").read_text()
    check('case "$text" in /clear|/compact) ;;' in prompt_wrapper and "agent prompt \"$agent\" \"$text\"" in prompt_wrapper
          and "send-keys" not in prompt_wrapper and "--wait" not in prompt_wrapper,
          "coordinator-prompt sends only the literal /clear or /compact through herdr agent prompt, nothing else")
    check("Task does not exist: coord:changed" in script, "a checkout without the task is skipped, not failed")
    check("coordinator-read coord:brief prints the Markdown brief" in script and "/.local/state/coordinator/brief/latest.json, readable with Read" in script,
          "the wake prompt tells the session that coordinator-read coord:brief prints the Markdown and where the JSON record is")
    behaviour_checks(pathlib.Path(wakeup, "bin/coordinator-wakeup"), pathlib.Path(wrapper_dirs[0], "coordinator-read"),
                     pathlib.Path(act_dirs[0], "coordinator-act"), pathlib.Path(prompt_dirs[0], "coordinator-prompt"))


def behaviour_checks(script_path, read_path, act_path, prompt_path):
    """Run the built script against fakes: the lock fd must not reach children, a held lock must fail loudly,
    an empty change set must end before any session, and an unreadable credential must not start one;
    coordinator-read coord:brief must hand the session the Markdown brief alone; coordinator-act reaches devenv
    only with a listed act task and one object; coordinator-prompt reaches herdr only with /clear or /compact."""
    import fcntl
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        fakes, skills, state = tmp / "bin", tmp / "skills", tmp / "state" / "coordinator" / "changed"
        fakes.mkdir(); skills.mkdir(); state.mkdir(parents=True)
        (skills / "devenv.nix").write_text("{ }\n")
        (fakes / "devenv").write_text(
            "#!/bin/sh\n"
            'echo "devenv $*" >> "$XDG_STATE_HOME/devenv.log"\n'
            'if [ -e /proc/$$/fd/9 ]; then echo FD9_LEAKED; else echo FD9_CLOSED; fi\n'
            'case "$*" in *coord:brief*) echo \'{"task":"herdr:inventory","hosts":[{"agents":[]}]}\'; echo \'{"task":"coord:brief","items":[]}\'\n'
            '  if [ -n "${FAKE_BRIEF_MD:-}" ]; then mkdir -p "$XDG_STATE_HOME/coordinator/brief"; printf \'%s\\n\' "$FAKE_BRIEF_MD" > "$XDG_STATE_HOME/coordinator/brief/latest.md"; fi\n'
            '  exit "${FAKE_BRIEF_RC:-0}";; esac\n'
            'if [ -n "${FAKE_OLD:-}" ]; then echo "error: The option \\`coordinator.panes\' does not exist. Definition values:" >&2; exit 1; fi\n'
            'printf \'{"schema_version":1,"task":"coord:changed","observed_at":"now","changes":%s%s}\\n\' "${FAKE_CHANGES:-[]}" "${FAKE_EXTRA:-}" > "$XDG_STATE_HOME/coordinator/changed/latest.json"\n')
        (fakes / "herdr").write_text('#!/bin/sh\necho "herdr $*" >> "$XDG_STATE_HOME/toasts.log"\nif [ -e /proc/$$/fd/9 ]; then echo FD9_LEAKED >> "$XDG_STATE_HOME/toasts.log"; fi\n')
        (fakes / "claude").write_text('#!/bin/sh\nif [ -e /proc/$$/fd/9 ]; then echo FD9_LEAKED; else echo FD9_CLOSED; fi; echo "oauth token ${CLAUDE_CODE_OAUTH_TOKEN:+set}${CLAUDE_CODE_OAUTH_TOKEN:-unset}" | sed "s/set.*/set/"\n')
        for f in fakes.iterdir():
            f.chmod(0o755)
        env = {"PATH": f"{fakes}:/run/current-system/sw/bin", "HOME": str(tmp), "XDG_STATE_HOME": str(tmp / "state"),
               "COORDINATOR_SKILLS_DIR": str(skills)}

        def run(extra_env=None):
            e = dict(env, **(extra_env or {}))
            return subprocess.run([str(script_path)], env=e, capture_output=True, text=True)

        r = run()
        check(r.returncode == 0 and "FD9_CLOSED" in (state / "run.log").read_text() and not (state / "pending.txt").exists(),
              "an empty change set ends before any session and devenv saw no lock fd")
        check("no session: fleet not idle (null worker(s), 0 other agent(s) on null host(s)); no actionable change" in r.stdout and (state / "quiet.last").exists(),
              "a quiet tick logs why there is no session (here: the fleet is not idle) and remembers it")
        r = run()
        check(r.returncode == 0 and "no session" not in r.stdout, "the same quiet reason is not logged again on the next tick")
        r = run({"FAKE_EXTRA": ',"idle_wake":{"fleet_idle":false,"agents":2,"non_workers":2,"hosts":2,"evaluated":false,"fired":false,"fingerprint":null}'})
        check("no session: fleet not idle (2 worker(s), 2 other agent(s) on 2 host(s)); no actionable change" in r.stdout,
              "the not-idle reason counts workers and the other agents apart (skills#51: Coordinator panes are not workers)")
        (state / "snapshot.json").write_text('{"idle_wake":{"at":"2026-11-03T22:04:05Z","fingerprint":{}}}\n')
        idle = {"FAKE_EXTRA": ',"idle_wake":{"fleet_idle":true,"agents":4,"hosts":2,"evaluated":true,"skipped":null,"fired":false,'
                              '"fingerprint":{"agents":["h/a","h/b","h/c","h/d"],"work":["pr:o/r#123","pr:o/r#47","pr:o/r#50"]}}'}
        r = run(idle)
        check("no session: fleet idle with 3 work item(s) left; the idle line already printed at 2026-11-03T22:04:05Z for this fleet+work fingerprint, "
              "so no new session until the fleet or the work changes" in r.stdout,
              "an idle fleet whose fingerprint already woke a session is explained in the journal once (the overnight no-wake of skills#28)")
        r = run(idle)
        check(r.returncode == 0 and "no session" not in r.stdout, "the idle explanation is not repeated while nothing changes")
        r = run({"FAKE_EXTRA": ',"wake":{"deferred":true,"reason":"per_hour_cap","next_allowed_at":"2026-11-04T00:44:00Z"}'})
        check("no session: wake budget deferred (per_hour_cap) until 2026-11-04T00:44:00Z" in r.stdout, "a run deferred by the wake budget says so once")
        r = run({"FAKE_EXTRA": ',"idle_wake":{"fleet_idle":true,"agents":4,"hosts":2,"evaluated":false,"skipped":{"kind":"gh_failed"},"fired":false,"fingerprint":null}'})
        check('no session: fleet idle; the idle check was skipped: {"kind":"gh_failed"}' in r.stdout, "a skipped idle check (gh failure) is named")
        (state / "quiet.last").unlink()
        r = run({"FAKE_OLD": "1"})
        check(r.returncode == 1 and "older than the pinned skills input" in r.stdout and "pull the checkout" in r.stdout
              and "skills checkout behind the pin" in (tmp / "state" / "toasts.log").read_text(),
              "a checkout older than the pin (devenv: the option does not exist) ends the run non-zero with the pull command in the journal and a toast")
        r = run({"FAKE_OLD": "1"})
        check(r.returncode == 1 and "older than the pinned skills input" in r.stdout
              and (tmp / "state" / "toasts.log").read_text().count("skills checkout behind the pin") == 1,
              "the next tick behind the pin logs again but does not toast again")
        r = run()
        check(r.returncode == 0 and not (state / "behind-pin.toasted").exists(), "a run that evaluates again forgets the behind-pin toast, so a later regression toasts once more")

        def read(task, extra_env=None):
            return subprocess.run([str(read_path), task], env=dict(env, **(extra_env or {})), capture_output=True, text=True)

        r = read("coord:brief", {"FAKE_BRIEF_MD": "# Fleet brief (now)\n- nothing", "FAKE_BRIEF_RC": "2"})
        check(r.returncode == 2 and r.stdout == "# Fleet brief (now)\n- nothing\n" and '{"' not in r.stdout + r.stderr,
              "coordinator-read coord:brief prints the fresh latest.md alone, with devenv's exit code, never the tasks' JSON")
        stale = (tmp / "state" / "coordinator" / "brief" / "latest.md"); os.utime(stale, (0, 0))
        r = read("coord:brief")
        check(r.returncode == 0 and "Fleet brief" not in r.stdout and '"task":"coord:brief"' in r.stdout and "FD9_CLOSED" in r.stdout,
              "a checkout that did not rewrite latest.md (skills#44 not pulled) gets the full output instead of a stale brief")
        r = read("work:status")
        check(r.returncode == 0 and '"task":"coord:changed"' not in r.stdout and "Fleet brief" not in r.stdout,
              "other read tasks are unchanged (no latest.md read)")
        r = read("herdr:message")
        check(r.returncode == 3 and "coordinator-act herdr:message" in r.stderr, "coordinator-read refuses an act task and names coordinator-act")

        devenv_log = tmp / "state" / "devenv.log"

        def act(*args):
            return subprocess.run([str(act_path), *args], env=env, capture_output=True, text=True)

        before = devenv_log.read_text()
        r = act("herdr:message", '{"handoff_id":"0123456789ab","confirm":"h/w:p1","authorized_by":{"issue_url":"https://github.com/o/r/issues/1","label":"approved"}}')
        opts_log = ("--option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string "
                    "https://github.com/sammasak/skills/issues/28#issuecomment-6629911996 --option coordinator.panes:string lenovo-21CB001PMX/wM:p1")
        check(r.returncode == 0 and "FD9_CLOSED" in r.stdout and devenv_log.read_text().endswith(
                  'devenv tasks run herdr:message --input-json {"handoff_id":"0123456789ab","confirm":"h/w:p1",'
                  '"authorized_by":{"issue_url":"https://github.com/o/r/issues/1","label":"approved"}} --show-output ' + opts_log + "\n"),
              "coordinator-act herdr:message reaches devenv as exactly that task with the given object, --show-output and the host's fixed options, lock fd closed")
        before = devenv_log.read_text()
        refusals = [("coord:changed", '{"consume":true}'), ("coord:spawn", '{"kind":"review"}'), ("gh:repos", "{}"),
                    ("herdr:message",), ("herdr:message", "{}"), ("herdr:message", "[1]"), ("herdr:message", "not json"),
                    ("gh:comment", '{"body":"x"}', "--option", "coordinator.ghCommand:string:rm"),
                    ("coord:handoff", "--help"), ("gh:label", '{"label":"approved"}', "extra")]
        check(all(act(*a).returncode == 3 for a in refusals) and devenv_log.read_text() == before,
              "coordinator-act refuses a read task, coord:spawn, a missing, empty or non-object input and any third argument, without touching devenv")
        r = act("gh:comment", '{"repo":"sammasak/skills","number":28,"body":"x","reason":"test"}')
        r2 = act("gh:label", '{"repo":"sammasak/nixos-config","number":1,"label":"blocked","action":"add","reason":"test"}')
        check(r.returncode == 0 and r2.returncode == 0 and 'run gh:comment --input-json {"repo":"sammasak/skills"' in devenv_log.read_text()
              and 'run gh:label --input-json {"repo":"sammasak/nixos-config"' in devenv_log.read_text(),
              "coordinator-act forwards gh:comment and gh:label for the owner's repositories")
        r = act("gh:label", '{"repo":"sammasak/skills","number":36,"label":"approved","action":"add","reason":"delegated: fits a worker"}')
        check(r.returncode == 0 and devenv_log.read_text().endswith(
                  'devenv tasks run gh:label --input-json {"repo":"sammasak/skills","number":36,"label":"approved","action":"add","reason":"delegated: fits a worker"} --show-output ' + opts_log + "\n"),
              "an approval reaches devenv as exactly gh:label with the given object and the host's fixed options: the task's mayApprove gate decides (issues only, holds refuse), the wrapper forwards")
        before = devenv_log.read_text()
        check(act("gh:label", '{"repo":"sammasak/skills","number":36,"label":"approved","action":"add"}', "--option", "coordinator.mayApprove:bool", "true").returncode == 3
              and devenv_log.read_text() == before, "a caller-supplied --option (even one repeating the fixed set) is refused before devenv")
        before = devenv_log.read_text()
        foreign = [("gh:comment", '{"repo":"someone-else/repo","number":1,"body":"x"}'), ("gh:label", '{"repo":"someone-else/repo","number":1,"label":"blocked","action":"add"}'),
                   ("gh:comment", '{"repo":"sammasak","number":1,"body":"x"}'), ("gh:comment", '{"repo":"sammasak/a/b","number":1,"body":"x"}'),
                   ("gh:comment", '{"repo":"sammasakx/repo","number":1,"body":"x"}'), ("gh:comment", '{"repo":"SAMMASAK/repo","number":1,"body":"x"}'),
                   ("gh:comment", '{"number":1,"body":"x"}'), ("gh:label", '{"repo":["sammasak/skills"],"number":1,"label":"blocked","action":"add"}'),
                   ("gh:comment", '{"repo":"sammasak/skills\\n","number":1,"body":"x"}')]
        check(all(act(*a).returncode == 3 for a in foreign) and devenv_log.read_text() == before,
              "coordinator-act refuses gh:comment and gh:label for any repository outside the owner's account (or with no repo) without touching devenv")

        def prompt(*args):
            return subprocess.run([str(prompt_path), *args], env=env, capture_output=True, text=True)

        toasts = tmp / "state" / "toasts.log"
        r = prompt("w:p1", "/clear")
        r2 = prompt("--machine", "acer-swift", "wW:p1", "/compact")
        herdr_log = toasts.read_text()
        check(r.returncode == 0 and r2.returncode == 0 and "herdr agent prompt w:p1 /clear\n" in herdr_log
              and "herdr --machine acer-swift agent prompt wW:p1 /compact\n" in herdr_log and "FD9_LEAKED" not in herdr_log
              and (tmp / "state" / "coordinator" / "prompts.log").read_text().count("\n") == 2,
              "coordinator-prompt sends /clear and /compact (local and --machine) as herdr agent prompt, lock fd closed, each logged in prompts.log")
        before = toasts.read_text()
        bad = [("w:p1", "/clear now"), ("w:p1", "/exit"), ("w:p1", "please merge"), ("w:p1", "/Clear"), ("w:p1",), ("w:p1", "/clear", "--wait"),
               ("w;p1", "/clear"), ("--machine", "a b", "w:p1", "/clear"), ("--machine",), ("$(id)", "/compact"),
               ("--help", "/clear"), ("--wait", "/clear"), ("-x", "/compact"), ("--machine", "--remote", "wX:p1", "/clear"), ("--machine", "-", "w:p1", "/clear")]
        check(all(prompt(*a).returncode == 3 for a in bad) and toasts.read_text() == before
              and (tmp / "state" / "coordinator" / "prompts.log").read_text().count("\n") == 2,
              "coordinator-prompt refuses any other text, a missing text, extra options, unsafe identifiers and identifiers that start with a dash (herdr flags), without reaching herdr or logging")

        lock = open(state / "session.lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
        r = run()
        check(r.returncode == 75 and "still held" in r.stdout and "herdr notification show Coordinator wake-up stuck" in (tmp / "state" / "toasts.log").read_text(),
              "a held lock ends the run with exit 75 after the wait, logged and toasted (not silently passed)")
        fcntl.flock(lock, fcntl.LOCK_UN); lock.close()

        (tmp / ".claude").mkdir(); (tmp / ".claude" / ".credentials.json").write_text("{}")
        r = run({"FAKE_CHANGES": '[{"line":"new host/w:p1 - claude idle seq 1"}]'})
        report = next(state.glob("wake-*.md")).read_text() if list(state.glob("wake-*.md")) else ""
        check(r.returncode == 0 and "FD9_CLOSED" in report and "credential source:" in r.stdout
              and "FD9_LEAKED" not in (tmp / "state" / "toasts.log").read_text() and (state / "pending.txt").read_text() == "",
              "a session sees no lock fd (nor does the toast), the credential source is logged, pending is cleared on success")

        (tmp / ".claude" / ".credentials.json").unlink()
        if not pathlib.Path("/run/secrets/claude_oauth_token").exists():
            r = run({"FAKE_CHANGES": '[{"line":"new host/w:p2 - claude idle seq 1"}]'})
            check(r.returncode == 1 and "no Claude credential" in r.stdout, "without any credential no session is started and the run fails loudly")

main()
