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

main()
