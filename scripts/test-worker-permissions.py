"""#145/#149: Herdr-started Claude Code workers start in bypassPermissions without a prompt, on worker hosts only;
plain `claude` and the unattended Coordinator (dontAsk) keep their permissions.
#157: a worker switches models when safeguards flag a message instead of stopping at the choice dialog: worker
hosts' settings carry switchModelsOnFlag, and the launcher hands it to any bypass-mode claude, on every host,
without touching settings.json (lenovo's Coordinator keeps the owner's choice). The pinned Claude Code must
still recognise the setting name, or a version bump would silently bring the stall back."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

FLAG = "--dangerously-skip-permissions"
WORKER, COORDINATOR = "acer-swift", "lenovo"


def nix(*args):
    return subprocess.run(["nix", *args], check=True, capture_output=True, text=True).stdout.strip()


def hm(host, path):
    return json.loads(nix("eval", "--json", f".#nixosConfigurations.{host}.config.home-manager.users.lukas.{path}"))


def realise(host, path):
    """The text of a Home Manager string with store context (a script path, an ExecStart), with its context built."""
    expr = (f'let c = (builtins.getFlake (toString ./.)).nixosConfigurations.{host}; '
            f'in c.pkgs.writeText "worker-permissions-probe" c.config.home-manager.users.lukas.{path}')
    return pathlib.Path(nix("build", "--impure", "--no-link", "--print-out-paths", "--expr", expr)).read_text()


def launched(host, args):
    """The argv the host's `claude` fish function gives the real claude, captured by a stand-in on PATH; HERDR_ENV
    takes the launcher's native path, as inside a Herdr pane (coord:spawn's `herdr agent start` types into one)."""
    fn = realise(host, "programs.fish.functions.claude")
    launcher = re.search(r"/nix/store/[^ ]+/bin/herdr-agent-launcher", fn).group(0)
    with tempfile.TemporaryDirectory() as d:
        fake = pathlib.Path(d, "claude")
        fake.write_text("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n")
        fake.chmod(0o755)
        run = subprocess.run([launcher, "claude", *args], env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "HERDR_ENV": "1"},
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
        return run.stdout.splitlines()


def claude_wrapped(host):
    """The bun-compiled binary of the Claude Code the host pins, realised so its embedded setting schema can be read."""
    out = nix("build", "--no-link", "--print-out-paths",
              f".#nixosConfigurations.{host}.config.home-manager.users.lukas.programs.claude-code.package")
    return pathlib.Path(out.splitlines()[-1])


def check(condition, message):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)
    print(f"PASS: {message}")


def trusted_after_activation(host):
    data = realise(host, "home.activation.acceptClaudeStartupDialogs.data")
    script = re.search(r"/nix/store/[^ ]+-accept-claude-startup-dialogs", data).group(0)
    with tempfile.TemporaryDirectory() as home:
        state = pathlib.Path(home, ".claude.json")
        state.write_text(json.dumps({"projects": {"/elsewhere": {"hasTrustDialogAccepted": False}}}))
        subprocess.run([script], check=True, env={**os.environ, "HOME": home})
        got = json.loads(state.read_text())
        return home, got


STARTUP_SECONDS = 30
API_LOOPBACK = "http://127.0.0.1:9"


def startup_screen(host, extra=()):
    """What `coord:spawn`'s argv shows at startup under the host's rendered settings.json and its pinned Claude Code,
    in a throwaway HOME prepared like a provisioned host (onboarding done, cwd trusted, a dummy API key approved).

    Claude Code 2.1.300 calls its API base URL before it draws the first screen (offline that call waits about 18 s;
    the non-essential-traffic switches do not skip it). So the check runs Claude Code in its own network namespace
    (`unshare --map-current-user -n`: loopback only, the uid stays the caller's, as bypass mode requires) with
    ANTHROPIC_BASE_URL on a closed loopback port: the call fails at once and the dummy key never leaves the host."""
    files = nix("build", "--no-link", "--print-out-paths", f".#nixosConfigurations.{host}.config.home-manager.users.lukas.home-files")
    claude = nix("build", "--no-link", "--print-out-paths", f".#nixosConfigurations.{host}.config.home-manager.users.lukas.programs.claude-code.finalPackage")
    key = "sk-ant-api03-hermetic-startup-check-00000000"
    with tempfile.TemporaryDirectory() as home:
        work = pathlib.Path(home, "work"); work.mkdir()
        pathlib.Path(home, ".claude").mkdir()
        pathlib.Path(home, ".claude/settings.json").write_text(pathlib.Path(files, ".claude/settings.json").read_text())
        pathlib.Path(home, ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "projects": {str(work): {"hasTrustDialogAccepted": True}},
            "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []}}))
        argv = " ".join([f"{claude}/bin/claude", *extra, FLAG, "--model", "claude-opus-5-5"])
        env = {"HOME": home, "PATH": os.environ["PATH"], "TERM": "xterm-256color", "ANTHROPIC_API_KEY": key,
               "ANTHROPIC_BASE_URL": API_LOOPBACK}
        run = subprocess.run(["unshare", "--map-current-user", "-n", "timeout", str(STARTUP_SECONDS), "script", "-qfec", argv, "/dev/null"],
                             cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace")
        out = run.stdout
        netns_ok = not run.stderr.startswith("unshare:")
        check(netns_ok, f"{host}: the startup check runs in its own network namespace (no network)"
              + ("" if netns_ok else f": {run.stderr.strip()[:160]}; unprivileged user namespaces are required"))
    # the TUI places words with cursor moves, so the comparison is on the text with every space removed
    return re.sub(r"\s+", "", re.sub(r"\x1b\][^\x07]*\x07|\x1b\[[0-9;?>]*[A-Za-z]", "", out))


def main():
    skills = pathlib.Path(nix("eval", "--raw", "--impure", "--expr",
                              "(builtins.getFlake (toString ./.)).inputs.skills.outPath"))
    spawn = (skills / "agents/coordinator/spawn.nix").read_text()
    check(re.search(r"agent start \"\$name\" --kind claude [^\n]*-- " + FLAG + " --model", spawn) is not None,
          "coord:spawn (pinned skills) starts every Coordinator-created Claude worker with " + FLAG)

    for host, worker in ((WORKER, True), (COORDINATOR, False)):
        settings = hm(host, "programs.claude-code.settings")
        if worker:
            check(settings.get("skipDangerousModePermissionPrompt") is True, f"{host}: settings skip the bypass acknowledgment dialog")
            check(settings.get("switchModelsOnFlag") is True, f"{host}: settings switch models when safeguards flag a message (#157)")
        else:
            check("skipDangerousModePermissionPrompt" not in settings, f"{host}: settings keep the bypass acknowledgment dialog")
            check("switchModelsOnFlag" not in settings, f"{host}: settings leave the safeguards model-switch choice to the owner")
        fish = hm(host, "programs.fish.functions")
        check(FLAG not in fish["claude"], f"{host}: plain claude (interactive) gets no bypass flag")
        if worker:
            check(re.search(r"herdr-agent-launcher claude " + FLAG + r" \$argv", fish.get("claude-worker", "")) is not None,
                  f"{host}: claude-worker starts through the same Herdr launcher with {FLAG}")
        else:
            check("claude-worker" not in fish, f"{host}: no claude-worker function")

    launcher = pathlib.Path("modules/programs/cli/herdr/agent-launcher.sh").read_text()
    check("skipDangerous" not in launcher and not re.search(r"set -- [^\n]*" + FLAG, launcher),
          "the launcher never adds the bypass flag (it is the caller's)")
    for host in (WORKER, COORDINATOR):
        worker_args, plain_args = launched(host, [FLAG, "--model", "claude-opus-5-5"]), launched(host, ["--model", "claude-opus-5-5"])
        check(plain_args == ["--model", "claude-opus-5-5"], f"{host}: the launcher passes a non-bypass claude through unchanged ({plain_args})")
        check(worker_args[:1] == ["--settings"] and worker_args[2:] == [FLAG, "--model", "claude-opus-5-5"]
              and json.loads(pathlib.Path(worker_args[1]).read_text()) == {"switchModelsOnFlag": True},
              f"{host}: a bypass-mode claude (coord:spawn's argv) gets --settings switchModelsOnFlag=true from the launcher (#157)")

    # #157 only works if the pinned Claude Code still reads switchModelsOnFlag: a version bump that drops or renames it
    # would leave every check above green while workers silently stall at the safeguards dialog again. Grep the binary.
    wrapped = claude_wrapped(WORKER)
    found = subprocess.run(["grep", "-rqa", "switchModelsOnFlag", str(wrapped)]).returncode == 0
    check(found, f"the pinned Claude Code ({wrapped.name}) recognises switchModelsOnFlag; if this fails a Claude Code "
                 "upgrade dropped or renamed the setting and #157 workers will stop at the model-switch dialog again")

    home, got = trusted_after_activation(WORKER)
    want = {home, "/home/lukas/claude-code-skills", "/home/lukas/nixos-config"}
    trusted = {d for d, p in got["projects"].items() if p.get("hasTrustDialogAccepted")}
    check(trusted == want, f"{WORKER}: activation trusts $HOME and the declared worker dirs only (got {sorted(trusted)})")
    home, got = trusted_after_activation(COORDINATOR)
    trusted = {d for d, p in got["projects"].items() if p.get("hasTrustDialogAccepted")}
    check(trusted == {home}, f"{COORDINATOR}: activation trusts $HOME only (got {sorted(trusted)})")

    exec_start = hm(COORDINATOR, "systemd.user.services.coordinator-wakeup.Service.ExecStart")
    wakeup = pathlib.Path(realise(COORDINATOR, "systemd.user.services.coordinator-wakeup.Service.ExecStart")).read_text()
    calls = re.findall(r"\| claude -p [^\n]*", wakeup)
    check(len(calls) == 1 and "--permission-mode dontAsk" in calls[0], f"{COORDINATOR}: the unattended Coordinator runs claude -p in dontAsk ({exec_start})")
    check(FLAG not in wakeup and "bypassPermissions" not in wakeup, f"{COORDINATOR}: the Coordinator wake-up never asks for bypassPermissions")
    services = hm(WORKER, "systemd.user.services")
    check("coordinator-wakeup" not in services, f"{WORKER}: no unattended Coordinator on the worker host")

    # #149: the coord:spawn argv against each host's rendered settings, the setting itself under test
    # the worker runs the argv the launcher hands the real claude, --settings included (#157): it must still start
    worker_extra = launched(WORKER, [FLAG])[:2]
    worker_screen, coordinator_screen = startup_screen(WORKER, worker_extra), startup_screen(COORDINATOR)
    for host, screen in ((WORKER, worker_screen), (COORDINATOR, coordinator_screen)):
        check("bypasspermissionson" in screen or "Yes,Iaccept" in screen,
              f"{host}: Claude Code drew its first screen within {STARTUP_SECONDS} s with no network (if not: its startup now waits "
              f"on something other than the API base URL {API_LOOPBACK}, i.e. a network call this offline check cannot answer)")
    print(f"{WORKER} screen: {worker_screen[-160:]}")
    print(f"{COORDINATOR} screen: {coordinator_screen[-240:]}")
    check("BypassPermissionsmode" not in worker_screen and "Yes,Iaccept" not in worker_screen
          and "bypasspermissionson" in worker_screen,
          f"{WORKER}: `claude {FLAG}` (coord:spawn's argv) reaches its prompt in bypassPermissions, no acceptance dialog")
    check("BypassPermissionsmode" in coordinator_screen and "Yes,Iaccept" in coordinator_screen,
          f"{COORDINATOR}: the same argv still stops at the acceptance dialog (the setting is what skips it, worker hosts only)")

    failed = json.loads(nix("eval", "--impure", "--json", "--expr",
                            f'let c = (builtins.getFlake (toString ./.)).nixosConfigurations.{WORKER}; '
                            'e = c.extendModules { modules = [ { sam.herdr.coordinatorWakeup.enable = true; } ]; }; '
                            'in map (a: a.message) (builtins.filter (a: !a.assertion) e.config.assertions)'))
    check(any("cannot both be enabled" in m for m in failed), "a worker host cannot also run the unattended Coordinator (assertion)")


if __name__ == "__main__":
    main()
