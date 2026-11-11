"""#145/#149: Herdr-started Claude Code workers start in bypassPermissions without a prompt, in the nspawn workers only
(docs/nspawn-workers.md; the worker "host" below is the guest of a probe instance added to acer at eval time, the committed
config declaring none);
skills#28: including a pane Herdr's session restore relaunches as a bare `claude --resume <id>` (the launcher supplies
the flag on worker hosts inside Herdr; before, a restored worker came back in auto mode);
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
WORKER, COORDINATOR = "acer-swift/probe", "lenovo"
FLAKE = "(builtins.getFlake (toString ./.))"


def config_of(host):
    """The host's evaluated NixOS config as a Nix expression; WORKER is the guest of an instance declared only here."""
    if host == WORKER:
        return (f"({FLAKE}.nixosConfigurations.acer-swift.extendModules "
                "{ modules = [ ({ lib, ... }: { sam.workers.instances = lib.mkForce { probe = { }; }; }) ]; }).config.containers.probe.config")
    return f"{FLAKE}.nixosConfigurations.{host}.config"


def hm_expr(host, path):
    return f"({config_of(host)}).home-manager.users.lukas.{path}"


def nix(*args):
    return subprocess.run(["nix", *args], check=True, capture_output=True, text=True).stdout.strip()


def hm(host, path):
    return json.loads(nix("eval", "--impure", "--json", "--expr", hm_expr(host, path)))


def realise(host, path):
    """The text of a Home Manager string with store context (a script path, an ExecStart), with its context built."""
    expr = f'{FLAKE}.nixosConfigurations.{COORDINATOR}.pkgs.writeText "worker-permissions-probe" {hm_expr(host, path)}'
    return pathlib.Path(nix("build", "--impure", "--no-link", "--print-out-paths", "--expr", expr)).read_text()


def launched(host, args, herdr=True, home=None):
    """The argv the host's `claude` fish function gives the real claude, captured by a stand-in on PATH; HERDR_ENV
    takes the launcher's native path, as inside a Herdr pane (coord:spawn's `herdr agent start` types into one)."""
    fn = realise(host, "programs.fish.functions.claude")
    launcher = re.search(r"/nix/store/[^ ]+/bin/herdr-agent-launcher", fn).group(0)
    with tempfile.TemporaryDirectory() as d:
        fake = pathlib.Path(d, "claude")
        fake.write_text("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n")
        fake.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
        env.update({"PATH": f"{d}:{os.environ['PATH']}", "HOME": home or d}, **({"HERDR_ENV": "1"} if herdr else {}))
        run = subprocess.run([launcher, "claude", *args], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
        return run.stdout.splitlines()


def claude_wrapped(host):
    """The bun-compiled binary of the Claude Code the host pins, realised so its embedded setting schema can be read."""
    out = nix("build", "--impure", "--no-link", "--print-out-paths", "--expr", hm_expr(host, "programs.claude-code.package"))
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


def startup_screen(host, extra=(), flag=True):
    """What `coord:spawn`'s argv shows at startup under the host's rendered settings.json and its pinned Claude Code,
    in a throwaway HOME prepared like a provisioned host (onboarding done, cwd trusted, a dummy API key approved).

    Claude Code 2.1.300 calls its API base URL before it draws the first screen (offline that call waits about 18 s;
    the non-essential-traffic switches do not skip it). So the check runs Claude Code in its own network namespace
    (`unshare --map-current-user -n`: loopback only, the uid stays the caller's, as bypass mode requires) with
    ANTHROPIC_BASE_URL on a closed loopback port: the call fails at once and the dummy key never leaves the host."""
    files = nix("build", "--impure", "--no-link", "--print-out-paths", "--expr", hm_expr(host, "home-files"))
    claude = nix("build", "--impure", "--no-link", "--print-out-paths", "--expr", hm_expr(host, "programs.claude-code.finalPackage"))
    key = "sk-ant-api03-hermetic-startup-check-00000000"
    with tempfile.TemporaryDirectory() as home:
        work = pathlib.Path(home, "work"); work.mkdir()
        pathlib.Path(home, ".claude").mkdir()
        pathlib.Path(home, ".claude/settings.json").write_text(pathlib.Path(files, ".claude/settings.json").read_text())
        pathlib.Path(home, ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "projects": {str(work): {"hasTrustDialogAccepted": True}},
            "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []}}))
        argv = " ".join([f"{claude}/bin/claude", *extra, *([FLAG] if flag else []), "--model", "claude-opus-5-5"])
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
    module = (pathlib.Path(__file__).parent.parent / "modules/workers/default.nix").read_text()
    check(f"'claude {FLAG}" in module, "the workers module starts every environment's Claude with " + FLAG)

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
    check("skipDangerous" not in launcher, "the launcher never skips the acknowledgment dialog itself (settings do)")
    ws = None
    for args in (["--resume", "2438c230-e5ab-4232-9869-9115883906ec"], [], ["--model", "claude-opus-5-5"]):
        got = launched(WORKER, args)
        ws = got[1] if got[:1] == ["--settings"] else ws
        check(got == ["--settings", ws, FLAG, *args],
              f"{WORKER}: inside a Herdr pane `claude {' '.join(args)}` (a session restore's argv) starts with {FLAG} (got {got})")
    for args in (["--permission-mode", "plan"], ["--permission-mode=default"], ["-p", "hi"], ["--version"]):
        got = launched(WORKER, args)
        check(got == args, f"{WORKER}: `claude {' '.join(args)}` names its own mode or is non-interactive: unchanged (got {got})")
    got = launched(WORKER, ["--resume", "x"], herdr=False)
    check(got == ["--resume", "x"], f"{WORKER}: outside a Herdr pane (SSH, a plain shell) claude is unchanged (got {got})")
    for args in (["--resume", "87ad883f-5df1-4946-94d8-4714fae05c49"], []):
        got = launched(COORDINATOR, args)
        check(got == args, f"{COORDINATOR}: a restored or bare claude in a Herdr pane keeps the owner's mode (got {got})")
    for host in (WORKER, COORDINATOR):
        worker_args, plain_args = launched(host, [FLAG, "--model", "claude-opus-5-5"]), launched(host, ["--model", "claude-opus-5-5"])
        if host == COORDINATOR:
            check(plain_args == ["--model", "claude-opus-5-5"], f"{host}: the launcher passes a non-bypass claude through unchanged ({plain_args})")
        check(worker_args[:1] == ["--settings"] and worker_args[2:] == [FLAG, "--model", "claude-opus-5-5"]
              and json.loads(pathlib.Path(worker_args[1]).read_text()) == {"switchModelsOnFlag": True, "skipDangerousModePermissionPrompt": True},
              f"{host}: a bypass-mode claude (coord:spawn's argv) gets --settings switchModelsOnFlag and the skipped acknowledgment from the launcher")
    # a Herdr restore keeps the mode the session's transcript last recorded, on every host
    sid = "5c783685-567d-4e43-8a42-8a6f1dac2283"
    for mode, want_flag in (("bypassPermissions", True), ("default", False), ("auto", False)):
        with tempfile.TemporaryDirectory() as home:
            proj = pathlib.Path(home, ".claude/projects/-home-lukas-x"); proj.mkdir(parents=True)
            proj.joinpath(f"{sid}.jsonl").write_text("".join(json.dumps(e) + "\n" for e in (
                {"type": "permission-mode", "permissionMode": "bypassPermissions" if mode != "bypassPermissions" else "default", "sessionId": sid},
                {"type": "user", "permissionMode": mode, "sessionId": sid},
                {"type": "permission-mode", "permissionMode": mode, "sessionId": sid})))
            for host in (COORDINATOR, "msi-ms7758"):
                got = launched(host, ["--resume", sid], home=home)
                want = ["--settings", got[1], FLAG, "--resume", sid] if want_flag else ["--resume", sid]
                check(got == want, f"{host}: a restored session last in {mode} comes back {'in' if want_flag else 'without'} bypass (got {got})")
            got = launched(COORDINATOR, ["--resume", sid], herdr=False, home=home)
            check(got == ["--resume", sid], f"{COORDINATOR}: outside a Herdr pane a resume is unchanged (got {got})")

    # #157 only works if the pinned Claude Code still reads switchModelsOnFlag: a version bump that drops or renames it
    # would leave every check above green while workers silently stall at the safeguards dialog again. Grep the binary.
    wrapped = claude_wrapped(WORKER)
    found = subprocess.run(["grep", "-rqa", "switchModelsOnFlag", str(wrapped)]).returncode == 0
    check(found, f"the pinned Claude Code ({wrapped.name}) recognises switchModelsOnFlag; if this fails a Claude Code "
                 "upgrade dropped or renamed the setting and #157 workers will stop at the model-switch dialog again")

    home, got = trusted_after_activation(WORKER)
    want = {home, *(f"/home/lukas/{d}" for d in ("claude-code-skills", "knowledge", "nixos-config", ".cache/wt"))}
    trusted = {d for d, p in got["projects"].items() if p.get("hasTrustDialogAccepted")}
    check(trusted == want, f"{WORKER}: activation trusts $HOME and the declared dirs only (got {sorted(trusted)})")
    check(got.get("hasSeenAutoDefaultNudge") is True, f"{WORKER}: activation dismisses the auto-mode default nudge")
    home, got = trusted_after_activation(COORDINATOR)
    trusted = {d for d, p in got["projects"].items() if p.get("hasTrustDialogAccepted")}
    want = {home, *json.loads(nix("eval", "--json", f".#nixosConfigurations.{COORDINATOR}.config.sam.herdr.trustedDirs"))}
    check(trusted == want and "/home/lukas/.cache/wt" in want, f"{COORDINATOR}: activation trusts $HOME and its declared dirs only (got {sorted(trusted)})")

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
    # skills#28: the bare argv a Herdr restore types, through the worker's launcher, must also land in bypassPermissions
    restored_screen = startup_screen(WORKER, launched(WORKER, []), flag=False)
    print(f"{WORKER} restored-pane screen: {restored_screen[-160:]}")
    check("bypasspermissionson" in restored_screen and "Yes,Iaccept" not in restored_screen and "automodeon" not in restored_screen,
          f"{WORKER}: a bare `claude` in a Herdr pane (a session restore) reaches its prompt in bypassPermissions, no dialog, not auto mode")
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
                            f'let c = (builtins.getFlake (toString ./.)).nixosConfigurations.{COORDINATOR}; '
                            'e = c.extendModules { modules = [ { sam.herdr.worker.enable = true; } ]; }; '
                            'in map (a: a.message) (builtins.filter (a: !a.assertion) e.config.assertions)'))
    check(any("cannot both be enabled" in m for m in failed), "the Coordinator's host cannot also be a worker (assertion)")


if __name__ == "__main__":
    main()
