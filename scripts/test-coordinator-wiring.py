import json
import pathlib
import subprocess
import sys
import tomllib

COORDINATOR_FILES = {
    ".claude/agents/coordinator.md",
    ".codex/agents/coordinator.toml",
}


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
    role = role_path.read_text()
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

    attr = '.#nixosConfigurations.lenovo.config.home-manager.users.lukas.home.file.".codex/agents/coordinator.toml".source'
    agent = tomllib.loads(pathlib.Path(nix("build", "--no-link", "--print-out-paths", attr)).read_text())
    check(agent["name"] == "coordinator", "the Codex agent is named coordinator")
    check(agent["developer_instructions"] == role, "the Codex instructions are the pinned ROLE.md, byte for byte")
    check(agent["description"] == front["mission"], "the Codex description is the role's mission")


main()
