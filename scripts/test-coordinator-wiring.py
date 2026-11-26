import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import tomllib

import gate_probe

COORDINATOR_FILES = {".claude/agents/coordinator.md"}


def commands(text):
    """A rendered script without its comment lines: a flag named in a comment is not one the script passes."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def check(condition, message):
    if not condition:
        print(f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): {message}")
        sys.exit(1)
    print(f"PASS: {message}")


def pool_check(pool):
    """lenovo's exec-pool runs acer's over ssh: a fake ssh records the command line, which acer's login shell (fish) and
    bash must both split back into the caller's arguments, the prompt on stdin as --prompt-file -."""
    fake = pathlib.Path(tempfile.mkdtemp())
    (fake / "ssh").write_text("#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({'argv': sys.argv[1:], 'stdin': sys.stdin.read()}))\nsys.exit(75)\n")
    (fake / "ssh").chmod(0o755)
    env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}")
    run = lambda *a: subprocess.run([pool, *a], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    prompt = "it's a \"test\"\n$HOME `id` \\ ; (x) # y"
    args = ["submit", "--agent", "claude", "--repo", "https://github.com/a/b", "--rev", "0" * 40, "--workdir", "a b/$c",
            "--key", "coord:a/b#1@" + "0" * 40, "--prompt", prompt, "--model", "opus"]
    r = run(*args)
    seen = json.loads(r.stdout)
    want = ["/run/current-system/sw/bin/exec-pool", *args[:11], "--prompt-file", "-", "--model", "opus"]
    check(r.returncode == 75 and seen["argv"][:6] == ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "acer-swift"] and seen["stdin"] == prompt,
          f"exec-pool submit runs over ssh to acer in batch mode, exits as the remote did, the prompt byte for byte on stdin (got {r.returncode}, {seen})")
    line = " ".join(seen["argv"][6:])
    for shell in ("fish", "bash"):
        split = subprocess.run([shell, "-c", "printf '%s\\0' " + line], capture_output=True, text=True, check=True).stdout.split("\0")[:-1]
        check(split == want, f"{shell} splits the remote command back into the arguments, --prompt as --prompt-file - (got {split})")
    r = run("status", "cli-0123456789abcdef")
    check(json.loads(r.stdout)["argv"][6:] == ["/run/current-system/sw/bin/exec-pool", "'status'", "'cli-0123456789abcdef'"]
          and json.loads(r.stdout)["stdin"] == "" and r.returncode == 75,
          "a read passes its id quoted, the caller's stdin not forwarded, and exits as the remote did")
    (fake / "prompt.md").write_text(prompt + "\n")
    r = subprocess.run([pool, *args[:11], "--prompt-file", str(fake / "prompt.md")], env=env, capture_output=True, text=True)
    check(json.loads(r.stdout)["stdin"] == prompt + "\n" and json.loads(r.stdout)["argv"][-2:] == ["'--prompt-file'", "'-'"],
          "--prompt-file PATH is read on this host and sent as stdin, never resolved on the queue's host")
    # every verb the skills pool:* tasks call goes through unchanged: start and send with the prompt on stdin, wait with
    # its timeout, the sessions listing and work:status's one list call
    for verb in (["start", *args[1:11]], ["send", "cli-0123456789abcdef"]):
        r = run(*verb, "--prompt", prompt)
        seen = json.loads(r.stdout)
        check(r.returncode == 75 and seen["stdin"] == prompt
              and seen["argv"][6:] == ["/run/current-system/sw/bin/exec-pool", *(f"'{a}'" for a in verb), "'--prompt-file'", "'-'"],
              f"exec-pool {verb[0]} reaches acer's CLI with its arguments quoted and the prompt on stdin (got {seen})")
    for verb in (["wait", "cli-0123456789abcdef", "--timeout", "60"], ["sessions"], ["sessions", "--gc"], ["list", "--limit", "200"]):
        seen = json.loads(run(*verb).stdout)
        check(seen["argv"][6:] == ["/run/current-system/sw/bin/exec-pool", *(f"'{a}'" for a in verb)] and seen["stdin"] == "",
              f"exec-pool {' '.join(verb)} reaches acer's CLI as given, no stdin forwarded (got {seen})")
    for bad in ("a'b", "a\\b"):
        r = run("status", bad)
        check(r.returncode == 2 and r.stdout == "", f"an argument holding ' or \\ ({bad!r}) is refused before ssh")


def main():
    P = gate_probe.section("coordinator-wiring")
    skills = pathlib.Path(P["skills"])
    role_path = skills / "agents/coordinator/ROLE.md"
    front = json.loads(subprocess.run(["yq", "--front-matter=extract", "-o=json", ".", str(role_path)],
                                      check=True, capture_output=True, text=True).stdout)
    role_skills = front["skills"]

    common = (skills / "task-modules/common.nix").read_text()
    check("mayApprove = lib.mkOption { type = t.bool;" in common and "approvalDecision = lib.mkOption { type = t.nullOr t.str;" in common
          and "panes = lib.mkOption { type = t.str;" in common,
          "the pinned skills input declares coordinator.mayApprove (bool), approvalDecision (nullable string) and panes (comma string) (skills#53, #54), the types the fixed options use")
    changed = (skills / "agents/coordinator/changed.nix").read_text()
    check("options.coordinator.interactiveQuietSeconds = lib.mkOption {" in changed and "type = lib.types.ints.unsigned;" in changed.split("interactiveQuietSeconds", 1)[1][:200],
          "the pinned skills input declares coordinator.interactiveQuietSeconds (unsigned int, skills#66), the type lenovo's flag uses")

    pool_module = (skills / "task-modules/pool.nix").read_text()
    check("options.coordinator.poolCommand = lib.mkOption {" in pool_module and "type = lib.types.nullOr lib.types.str;" in pool_module,
          "the pinned skills input declares coordinator.poolCommand (nullable string, skills#150), the type lenovo's flag uses")
    check(all(f'"{t}" = {{' in pool_module for t in ("pool:start", "pool:send", "pool:wait")),
          "the pinned skills input has the session tasks the wake prompt dispatches with (pool:start, pool:send, pool:wait; skills#162)")
    check("poolCommand} list --limit" in (skills / "agents/coordinator/tasks.nix").read_text(),
          "the pinned skills work:status reads session states with one exec-pool list call, the verb the wrapper test covers")
    pools = set(re.findall(r"--option coordinator\.poolCommand:string (/nix/store/[a-z0-9]+-exec-pool/bin/exec-pool)", P["script"] or ""))
    check(len(pools) == 1, f"lenovo passes one exec-pool wrapper as coordinator.poolCommand (got {pools})")
    pool = pools.pop()
    pool_check(pool)

    # the heavy-build guard: on the deployer alone, named as the hook's argument, between check-loop and the shunt hook
    guard = skills / "hooks/check-heavy-build.py"
    on_lenovo = [c for c in P["bashHooks"]["lenovo"] if "check-heavy-build.py" in c]
    on_acer = [c for c in P["bashHooks"]["acer-swift"] if "check-heavy-build.py" in c]
    if guard.exists():
        names = [c.split(" ")[-2 if "check-heavy-build.py" in c else -1].rsplit("/", 1)[-1] for c in P["bashHooks"]["lenovo"]]
        check(len(on_lenovo) == 1 and on_lenovo[0].endswith(f" {guard} {P['deployer']}") and "/bin/python3 " in on_lenovo[0]
              and not on_acer and P["deployer"] == "lenovo-21CB001PMX",
              f"lenovo alone runs check-heavy-build.py with the deployer's hostname as its argument (lenovo {on_lenovo}, acer {on_acer})")
        check(names.index("check-loop.sh") < names.index("check-heavy-build.py")
              and all(names.index("check-heavy-build.py") < i for i, n in enumerate(names) if n.startswith("shunt-")),
              f"the guard runs after check-loop.sh and before the shunt hook ({names})")
        blocked = subprocess.run(on_lenovo[0], shell=True, capture_output=True, text=True,
                                 input='{"tool_input":{"command":"devenv tasks run nixos:qa"}}',
                                 env=dict(os.environ, CHECK_HEAVY_BUILD_TEST_HOST=P["deployer"]))
        passed = subprocess.run(on_lenovo[0], shell=True, capture_output=True, text=True,
                                input='{"tool_input":{"command":"devenv tasks run nixos:qa"}}',
                                env=dict(os.environ, CHECK_HEAVY_BUILD_TEST_HOST="acer-swift"))
        check(blocked.returncode == 2 and "BLOCKED: heavy build" in blocked.stderr and passed.returncode == 0,
              f"the registered command refuses nixos:qa under lenovo's hostname as the kernel spells it and passes on acer ({blocked.returncode}, {passed.returncode})")
    else:
        check(not on_lenovo and not on_acer, "the pinned skills input lacks check-heavy-build.py: no host registers it")

    lenovo, acer = set(P["files"]["lenovo"]), set(P["files"]["acer-swift"])
    check(COORDINATOR_FILES <= lenovo, "lenovo links the Claude and Codex coordinator adapters")
    # the same options for an interactive session: devenv.local.nix in the checkout, evaluated as Nix so a malformed value
    # fails here, not at the Coordinator's next act; nothing else is written into the checkout
    local_cfg = P["local"]
    check(local_cfg == {"coordinator": {"mayApprove": True, "approvalDecision": "https://github.com/sammasak/skills/issues/28#issuecomment-6629911996",
                                        "panes": "lenovo-21CB001PMX/wM:p1", "poolCommand": pool}},
          f"lenovo's devenv.local.nix carries exactly the delegation, the decision comment and the Coordinator pane the wrappers pass (got {local_cfg})")
    check([f for f in lenovo if f.startswith("claude-code-skills/")] == ["claude-code-skills/devenv.local.nix"]
          and not any(f.startswith("claude-code-skills/") for f in acer),
          "devenv.local.nix is the only file Home Manager writes into the checkout, and only on lenovo")
    check(not COORDINATOR_FILES & acer, "acer, a worker, links no coordinator adapter")
    check(".claude/agents/quality.md" in acer, "acer keeps the other role adapters")
    for name in role_skills:
        check(f".agents/skills/{name}" in lenovo, f"lenovo's Codex has the coordinator skill {name}")
        check(f".agents/skills/{name}" not in acer, f"acer's Codex does not get the coordinator skill {name}")

    for host, files in (("lenovo", lenovo), ("acer-swift", acer)):
        check(not any(f.startswith(".codex/agents/") for f in files),
              f"{host} links nothing into ~/.codex/agents (Codex refuses a symlinked role file at spawn)")

    lenovo_cfg, acer_cfg = tomllib.loads(P["codex"]["lenovo"]), tomllib.loads(P["codex"]["acer-swift"])
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

    lenovo_timers, acer_timers = P["timers"]["lenovo"], P["timers"]["acer-swift"]
    lenovo_services = P["services"]
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
    wakeup, script = P["wakeup"], P["script"]
    check('devenv tasks run coord:changed --input-json \'{"consume":true}\'' in script, "the timer runs coord:changed in its consuming form")
    # the owner's skills config for the host rides on every devenv call as fixed --option flags (sam.herdr.coordinatorWakeup);
    # the exact flags are the contract: the delegation, the decision it cites, the Coordinator's pane
    OPTS = ("--option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string "
            "'https://github.com/sammasak/skills/issues/28#issuecomment-6629911996' --option coordinator.panes:string lenovo-21CB001PMX/wM:p1"
            " --option coordinator.interactiveQuietSeconds:int 600 --option coordinator.poolCommand:string " + pool)
    check('devenv tasks run coord:changed --input-json \'{"consume":true}\' ' + OPTS + " >" in script,
          "the timer's coord:changed carries the host's fixed skills options: delegated approval citing the owner's decision comment, the Coordinator's pane")
    check(commands(script).count("--option coordinator.interactiveQuietSeconds:int 600") == commands(script).count("--option coordinator.mayApprove:bool true"),
          "lenovo's interactiveQuietSeconds (600) rides on every devenv call beside the delegation flags (skills#66: no wake while the interactive Coordinator works)")
    # the report timers ride on the wake-up's enable and gate; their job's week rule is scripts/test-coordinator-report.py
    for name, mode, cal in (("coordinator-report-daily", "daily", "*-*-* 03:00"), ("coordinator-report-fortnight", "fortnight", "Mon 07:00")):
        t = lenovo_timers.get(name, {}).get("Timer", {})
        check(t.get("OnCalendar") == cal and t.get("Persistent") is True and name not in acer_timers,
              f"lenovo alone has the {name} timer, {cal}, Persistent (got {t})")
        svc = lenovo_services.get(name, {}).get("Service", {})
        check(svc.get("Type") == "oneshot" and svc.get("ExecStart") in (want := f"{P['report']}/bin/coordinator-report {mode}", [want])
              and svc.get("MemoryMax") == "2G" and any(e.startswith("PATH=/run/current-system/sw/bin:") for e in svc.get("Environment", [])),
              f"{name} is a memory-bounded oneshot running coordinator-report {mode}, devenv from the profiles (got {svc})")
    check("coordinator-report-daily.service" in lenovo_services["coordinator-report-fortnight"]["Unit"].get("After", []),
          "the fortnight run orders after the daily, so a boot catch-up renders the weekly after Sunday's daily")
    report = P["reportScript"] or ""
    # writeShellApplication puts its shebang and set -o lines before the text
    check(('\nset -- "$@" ' + OPTS + "\n") in report and commands(report).count("--option coordinator.") == OPTS.count("--option coordinator.")
          and 'no skills checkout at $skills' in report,
          f"the report job passes exactly the host's fixed skills options to devenv and skips without a checkout ({report[:160]!r})")
    seeded = "sam.herdr.coordinatorWakeup (the wake-up and the coordinator-report timers) runs only on the coordinator host"
    check(any(m.startswith(seeded) for m in P["failing"]["acerWakeup"]) and not any(m.startswith(seeded) for m in P["failing"]["lenovo"]),
          "coordinatorWakeup on acer, a host without sam.herdr.machines, fails evaluation; lenovo passes")
    check("does not exist" in script and "older than the pinned skills input" in script and "pull --ff-only origin main" in script,
          "a checkout that lacks the options (older than the pin) is named in the journal and toasted, not retried silently")
    quiet = script.index('if [ ! -s "$pending" ]; then')
    check(quiet < script.index("claude -p") and "  exit 0\nfi\n" in script[quiet:script.index("claude -p")],
          "the script exits before any model call when nothing is actionable or pending")
    check("claude -p --agent coordinator --max-budget-usd" in script, "the session is headless, the coordinator agent, spend-capped")
    check(script.index("flock -w 20 9") < script.index("devenv tasks run coord:changed"), "the lock is taken before coord:changed runs, so two runs never race on the snapshot")
    check("--disallowedTools 'Bash(devenv:*)'" in script and "'Bash(herdr:*)'" in script and "'Bash(gh:*)'" in script
          and "'Bash(git:*)'" in script and "'Bash(ssh:*)'" in script and "'Bash(sudo:*)'" in script and "Edit Write" in script,
          "the headless session cannot reach devenv directly, herdr, gh, git, ssh, sudo or file edits")
    # the allow list is the contract the owner approved (skills#28): any change here is a deliberate change to this test
    tools = script.split("--allowedTools")[1].split("> \"$report\"")[0]
    allowed = re.findall(r"'([^']+)'", tools.split("--disallowedTools")[0])
    denied = [q or bare for q, bare in re.findall(r"'([^']+)'|\b(Edit|Write|NotebookEdit)\b", tools.split("--disallowedTools")[1])]
    check(allowed == ["Read(//home/lukas/claude-code-skills/**)", "Read(//home/lukas/.local/state/coordinator/**)",
                      "Bash(cd ~/claude-code-skills:*)", "Bash(cd /home/lukas/claude-code-skills:*)",
                      "Bash(coordinator-read:*)", "Bash(coordinator-act:*)"],
          f"the allow list is exactly the two wrappers, cd into the checkout and the two Read scopes; no Herdr command (got {allowed})")
    check(denied == ["Bash(devenv:*)", "Bash(herdr:*)", "Bash(gh:*)", "Bash(git:*)", "Bash(ssh:*)", "Bash(sudo:*)",
                     "Edit", "Write", "NotebookEdit"],
          f"the deny list is exactly devenv, every herdr command, gh, git, ssh, sudo and the file-editing tools (got {denied})")
    check(not any(t.startswith(("Bash(cat", "Bash(jq", "Bash(tee", "Bash(sed", "Bash(bash", "Bash(sh", "Bash(python")) for t in allowed),
          "no shell read, write or interpreter primitive is allowed")
    check("coordinator-act <task>" in script and "Tasks run only through two wrappers" in script
          and "the label gate stays the authority" in script and "coordinator-prompt" not in script and "This session only reports" not in script,
          "the wake prompt names the two wrappers and the label gate, and no Herdr prompt wrapper")
    check("The owner delegated approval (coordinator.mayApprove, decision https://github.com/sammasak/skills/issues/28#issuecomment-6629911996)" in script
          and "never a PR, never one carrying needs-live, blocked or needs-decision) may get the approved label through coordinator-act gh:label, one issue per call" in script
          and "so approve, then pool:start it." in script,
          "the wake prompt states the owner's delegation (approve issues a worker can finish through coordinator-act gh:label, citing the decision), then a pool session")
    check("Work is dispatched as execution pool sessions, never to Herdr panes" in script
          and "One session per issue: pool:start it (key coord:OWNER/REPO#N)" in script
          and "is pool:send to the same session, never a new session or task" in script
          and "A session in waiting has ended its turn: it is a free slot, not a stuck worker" in script
          and "needs_review is the one state that wants a look" in script
          and "pool:wait only with timeout_seconds 60 or less" in script
          and "On outcome_unknown run the status_command it returns and nothing else" in script,
          "the prompt dispatches as pool sessions: one per issue, follow-ups as sends to it, waiting is a free slot, needs_review wants a look, a short wait, an uncertain answer is only checked")
    check("An open PR head that is unreviewed, no signed grade on that head and no review task for it, gets one review: pool:submit" in script
          and "review OWNER/REPO#N@<head sha>, post a comment Grade: N/10 (head <sha>) on that head, signed -- <host> <agent>), never the implementing session" in script
          and "A head already graded below 9 gets no second review: pool:send its findings to the implementing session" in script
          and "a merged or closed PR is never reviewed" in script and "is reported as ready to merge, and the interactive coordinator session merges it." in script,
          "the prompt reviews an unreviewed head once as a one-shot pool task in the form coord:brief parses, sends findings to the implementing session, never reviews a merged PR, and reports a 9+ head ready to merge for the interactive coordinator (pool slots have no merge route)")
    check("herdr:message" not in script.split("Work is dispatched", 1)[1].split("' \"$ts\"", 1)[0].replace("coord:handoff, herdr:message and coord:capacity are not yours", ""),
          "the prompt sends nothing over Herdr")
    check(': > "$pending"; rm -f "$attempts"' in script and 'if [ "$rc" -eq 0 ]; then' in script
          and script.index("|| rc=$?") < script.index(': > "$pending"; rm -f "$attempts"', script.index('if [ "$rc" -eq 0 ]; then')),
          "pending changes and the attempt counter are cleared only after claude exited 0")
    check('[ -n "$after" ] && [ "$after" != "$before" ]' in script and "-nt" not in script,
          "a latest.json not rewritten by this run is not trusted, judged by its inode (coord:changed renames a new record in), not the clock")
    check('rm -f "$state/quiet.last"' in script and script.index('rm -f "$state/quiet.last"') < script.index("starting one Coordinator session"),
          "a session start forgets the last quiet reason, so the first quiet tick after a session is explained again")
    check('[ "$tries" -ge 2 ]' in script and 'cat "$pending" >> "$parked"' in script and script.index('[ "$tries" -ge 2 ]') < script.index("claude -p"),
          "after two failed sessions the pending lines are parked instead of buying a third")
    check("--permission-mode dontAsk" in script and "'Bash(coordinator-read:*)'" in script and "'Bash(devenv:*)'" in script
          and "'Bash(herdr:*)'" in script and "Bash(devenv tasks run" not in script,
          "the session runs dontAsk; tasks only through coordinator-read, devenv itself and herdr denied")
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
    wrapper = pathlib.Path(wrapper_dirs[0], "coordinator-read").read_text()
    check("coord:brief|coord:changed|gh:work|gh:repos|git:recent|harness:session-summary|work:status|pool:status|pool:result|pool:wait) ;;" in wrapper
          and commands(wrapper).count("--option") == 2 * OPTS.count("--option") and wrapper.count(OPTS) == 2 and '[ "$#" -le 2 ]' in wrapper
          and "input=$(jq -c '. + {consume:false}'" in wrapper and "consume:true" not in wrapper,
          "coordinator-read takes only one of the role's read tasks and an input object, never consumes with coord:changed, and the only --option flags are the host's fixed ones (both devenv calls)")
    check(" 9>&-" in wrapper.split("exec devenv")[1], "coordinator-read closes the lock fd before devenv")
    act_dirs = re.findall(r"/nix/store/[a-z0-9]+-coordinator-act/bin", script)
    check(act_dirs != [] and "coordinator-prompt" not in script, "coordinator-act is on the wake-up script's PATH, coordinator-prompt is gone")
    act = pathlib.Path(act_dirs[0], "coordinator-act").read_text()
    check("pool:start|pool:send|pool:submit|gh:label|gh:comment) ;;" in act and commands(act).count("--option") == OPTS.count("--option") and OPTS in act
          and "coord:spawn" not in act and '[ "$#" -eq 2 ]' in act and " 9>&-" in act.split("exec devenv")[1],
          "coordinator-act takes exactly one of pool:start, pool:send, pool:submit, gh:label, gh:comment plus one input object (never coord:spawn), the only --option flags the host's fixed ones, lock fd closed")
    check("Task does not exist: coord:changed" in script, "a checkout without the task is skipped, not failed")
    check("coordinator-read coord:brief prints the Markdown brief" in script and "/.local/state/coordinator/brief/latest.json, readable with Read" in script,
          "the wake prompt tells the session that coordinator-read coord:brief prints the Markdown and where the JSON record is")
    behaviour_checks(pathlib.Path(wakeup, "bin/coordinator-wakeup"), pathlib.Path(wrapper_dirs[0], "coordinator-read"),
                     pathlib.Path(act_dirs[0], "coordinator-act"), pool)


def behaviour_checks(script_path, read_path, act_path, pool):
    """Run the built script against fakes: the lock fd must not reach children, a held lock must fail loudly,
    an empty change set must end before any session, and an unreadable credential must not start one;
    coordinator-read coord:brief must hand the session the Markdown brief alone; coordinator-act reaches devenv
    only with a listed act task and one object."""
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
            'if [ -n "${FAKE_FAIL:-}" ]; then echo "error: some other evaluation failure" >&2; exit 1; fi\n'
            'case "${FAKE_STALE:-}" in none) exit 0;; touch) touch "$XDG_STATE_HOME/coordinator/changed/latest.json"; exit 0;; esac\n'
            'printf \'{"schema_version":1,"task":"coord:changed","observed_at":"now","changes":%s%s}\\n\' "${FAKE_CHANGES:-[]}" "${FAKE_EXTRA:-}" > "$XDG_STATE_HOME/coordinator/changed/.rec.tmp"\n'
            'mv "$XDG_STATE_HOME/coordinator/changed/.rec.tmp" "$XDG_STATE_HOME/coordinator/changed/latest.json"\n')
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
        check(r.returncode == 0 and "no session" not in r.stdout,
              f"the idle explanation is not repeated while nothing changes (rc {r.returncode}, {r.stdout.strip()!r})")
        for stale in ("none", "touch"):
            r = run(dict(idle, FAKE_STALE=stale))
            check(r.returncode == 1 and "was not rewritten by this run; not trusted" in r.stdout,
                  f"a run that leaves latest.json in place ({stale}: kept, or only its mtime moved) is not trusted (rc {r.returncode}, {r.stdout.strip()!r})")
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
        run({"FAKE_OLD": "1"}); r = run({"FAKE_FAIL": "1"})
        check(r.returncode == 1 and "coord:changed failed" in r.stdout and not (state / "behind-pin.toasted").exists(),
              "any other failure after a stretch behind the pin also forgets the toast marker (it marks the stretch, not the last success)")

        def read(task, extra_env=None):
            return subprocess.run([str(read_path), task], env=dict(env, **(extra_env or {})), capture_output=True, text=True)

        r = read("coord:brief", {"FAKE_BRIEF_MD": "# Fleet brief (now)\n- nothing", "FAKE_BRIEF_RC": "2"})
        check(r.returncode == 2 and r.stdout == "# Fleet brief (now)\n- nothing\n" and '{"' not in r.stdout + r.stderr,
              "coordinator-read coord:brief prints the fresh latest.md alone, with devenv's exit code, never the tasks' JSON")
        stale = (tmp / "state" / "coordinator" / "brief" / "latest.md"); os.utime(stale, (0, 0))
        r = read("coord:brief")
        check(r.returncode == 0 and "Fleet brief" not in r.stdout and '"task":"coord:brief"' in r.stdout and "FD9_CLOSED" in r.stdout,
              "a checkout that did not rewrite latest.md (skills#44 not pulled) gets the full output instead of a stale brief")
        r = read("gh:work")
        check(r.returncode == 0 and '"task":"coord:changed"' not in r.stdout and "Fleet brief" not in r.stdout,
              "other read tasks are unchanged (no latest.md read)")
        r = read("pool:start")
        check(r.returncode == 3 and "coordinator-act pool:start" in r.stderr, "coordinator-read refuses an act task and names coordinator-act")
        before = (tmp / "state" / "devenv.log").read_text()
        check(all(read(t).returncode == 3 for t in ("herdr:inventory", "herdr:await", "coord:capacity"))
              and (tmp / "state" / "devenv.log").read_text() == before,
              "coordinator-read refuses the Herdr worker reads without touching devenv")

        devenv_log = tmp / "state" / "devenv.log"

        def act(*args):
            return subprocess.run([str(act_path), *args], env=env, capture_output=True, text=True)

        before = devenv_log.read_text()
        r = act("pool:start", '{"repo":"https://github.com/o/r","rev":"%s","workdir":".","prompt":"x","authorized_by":{"issue_url":"https://github.com/o/r/issues/1","label":"approved"}}' % ("0" * 40))
        opts_log = ("--option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string "
                    "https://github.com/sammasak/skills/issues/28#issuecomment-6629911996 --option coordinator.panes:string lenovo-21CB001PMX/wM:p1"
                    " --option coordinator.interactiveQuietSeconds:int 600 --option coordinator.poolCommand:string " + pool)
        check(r.returncode == 0 and "FD9_CLOSED" in r.stdout and devenv_log.read_text().endswith(
                  'devenv tasks run pool:start --input-json {"repo":"https://github.com/o/r","rev":"' + "0" * 40 + '","workdir":".","prompt":"x",'
                  '"authorized_by":{"issue_url":"https://github.com/o/r/issues/1","label":"approved"}} --show-output ' + opts_log + "\n"),
              "coordinator-act pool:start reaches devenv as exactly that task with the given object, --show-output and the host's fixed options, lock fd closed")
        before = devenv_log.read_text()
        refusals = [("coord:changed", '{"consume":true}'), ("coord:spawn", '{"kind":"review"}'), ("gh:repos", "{}"),
                    ("pool:send",), ("pool:send", "{}"), ("pool:send", "[1]"), ("pool:send", "not json"),
                    ("herdr:message", '{"handoff_id":"0123456789ab"}'), ("coord:handoff", '{"to":"h/w:p1"}'),
                    ("gh:comment", '{"body":"x"}', "--option", "coordinator.ghCommand:string:rm"),
                    ("pool:start", "--help"), ("gh:label", '{"label":"approved"}', "extra")]
        check(all(act(*a).returncode == 3 for a in refusals) and devenv_log.read_text() == before,
              "coordinator-act refuses a read task, coord:spawn, the Herdr handoff tasks, a missing, empty or non-object input and any third argument, without touching devenv")
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
