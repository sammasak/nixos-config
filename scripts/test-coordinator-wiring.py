import json
import os
import pathlib
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
    check("devenv tasks run coord:changed" in script, "the script runs coord:changed")
    check('[ -s "$pending" ] || exit 0' in script and script.index('[ -s "$pending" ] || exit 0') < script.index("claude -p"),
          "the script exits before any model call when nothing is actionable or pending")
    check("claude -p --agent coordinator --max-budget-usd" in script, "the session is headless, the coordinator agent, spend-capped")
    check(script.index("flock -n 9") < script.index("devenv tasks run coord:changed"), "the lock is taken before coord:changed runs, so two runs never race on the snapshot")
    check("--disallowedTools 'Bash(devenv tasks run herdr:message:*)'" in script and "'Bash(gh:*)'" in script and "Edit Write" in script,
          "the headless session cannot reach the act tasks, gh, pushes or file edits")
    check('if [ "$rc" -eq 0 ]; then : > "$pending"; : > "$attempts"' in script
          and script.index("|| rc=$?") < script.index('if [ "$rc" -eq 0 ]; then : > "$pending"'),
          "pending changes and the attempt counter are cleared only after claude exited 0")
    check('[ "$rec" -nt "$state/.started" ]' in script, "a latest.json not rewritten by this run is not trusted")
    check('[ "$tries" -ge 2 ]' in script and 'cat "$pending" >> "$parked"' in script and script.index('[ "$tries" -ge 2 ]') < script.index("claude -p"),
          "after two failed sessions the pending lines are parked instead of buying a third")
    check("--permission-mode dontAsk" in script and "--allowedTools Read 'Bash(cd ~/claude-code-skills:*)'" in script
          and "'Bash(herdr --machine:*)'" in script and "'Bash(devenv tasks run herdr:message:*)'" in script,
          "the session runs dontAsk with an allow list of read tasks and Herdr read commands; --machine and act tasks denied")
    check("Task does not exist: coord:changed" in script, "a checkout without the task is skipped, not failed")

main()
