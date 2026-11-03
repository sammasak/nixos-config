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

    lenovo, acer = home_files("lenovo"), home_files("acer-swift")
    check(COORDINATOR_FILES <= lenovo, "lenovo links the Claude and Codex coordinator adapters")
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
    check('[ -s "$pending" ] || exit 0' in script and script.index('[ -s "$pending" ] || exit 0') < script.index("claude -p"),
          "the script exits before any model call when nothing is actionable or pending")
    check("claude -p --agent coordinator --max-budget-usd" in script, "the session is headless, the coordinator agent, spend-capped")
    check(script.index("flock -w 20 9") < script.index("devenv tasks run coord:changed"), "the lock is taken before coord:changed runs, so two runs never race on the snapshot")
    check("--disallowedTools 'Bash(devenv:*)'" in script and "'Bash(herdr agent prompt:*)'" in script and "'Bash(gh:*)'" in script
          and "'Bash(git push:*)'" in script and "Edit Write" in script,
          "the headless session cannot reach devenv directly, raw herdr prompts, gh, pushes or file edits")
    check(': > "$pending"; rm -f "$attempts"' in script and 'if [ "$rc" -eq 0 ]; then' in script
          and script.index("|| rc=$?") < script.index(': > "$pending"; rm -f "$attempts"', script.index('if [ "$rc" -eq 0 ]; then')),
          "pending changes and the attempt counter are cleared only after claude exited 0")
    check('[ "$rec" -nt "$state/.started" ]' in script, "a latest.json not rewritten by this run is not trusted")
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
    check("coord:brief|coord:changed|work:status|herdr:inventory|herdr:inspect|gh:work|git:recent|harness:session-summary) ;;" in wrapper
          and "--option" not in wrapper and "input=$(jq -c '. + {consume:false}'" in wrapper and "consume:true" not in wrapper,
          "coordinator-read takes only a read task and an input object, never consumes with coord:changed, passes no --option")
    check(" 9>&-" in wrapper.split("exec devenv")[1], "coordinator-read closes the lock fd before devenv")
    check("Task does not exist: coord:changed" in script, "a checkout without the task is skipped, not failed")
    behaviour_checks(pathlib.Path(wakeup, "bin/coordinator-wakeup"))


def behaviour_checks(script_path):
    """Run the built script against fakes: the lock fd must not reach children, a held lock must fail loudly,
    an empty change set must end before any session, and an unreadable credential must not start one."""
    import fcntl
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        fakes, skills, state = tmp / "bin", tmp / "skills", tmp / "state" / "coordinator" / "changed"
        fakes.mkdir(); skills.mkdir(); state.mkdir(parents=True)
        (skills / "devenv.nix").write_text("{ }\n")
        (fakes / "devenv").write_text(
            "#!/bin/sh\n"
            'if [ -e /proc/$$/fd/9 ]; then echo FD9_LEAKED; else echo FD9_CLOSED; fi\n'
            'printf \'{"schema_version":1,"task":"coord:changed","observed_at":"now","changes":%s}\\n\' "${FAKE_CHANGES:-[]}" > "$XDG_STATE_HOME/coordinator/changed/latest.json"\n')
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
