"""sam.claude.bulkReader registers the skills input's shunt hooks only when on and only when the pin carries them: off,
the settings carry no shunt hook and no SHUNT_ variable; on, a Read entry and the Bash hook after the existing ones,
which stay in order; on with a pin lacking the files, nothing. A developer environment's guest gets it from a guest
module its host declares, beside its own no-verify-guard. Both skills sources are evaluated, whichever the pin is:
the pinned one (scripts/gate-probe.nix) and a copy of it with the two hooks added, or removed (--override-input)."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import gate_probe

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOKS = ("shunt-check-read.sh", "shunt-check-bash-read.sh", "shunt-spill-output.sh")
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def commands(entries):
    return [h["command"] for e in entries for h in e["hooks"]]


def bash_lists(s):
    return [[h["command"] for h in e["hooks"]] for e in s["hooks"]["PreToolUse"] if e.get("matcher") == "Bash"]


def shunt_env(s):
    return {k: v for k, v in s["env"].items() if k.startswith("SHUNT_")}


def flipped(skills, tmp, has):
    """The pinned skills tree with the shunt hooks added (stubs) when it lacks them, or removed when it has them."""
    fixture = pathlib.Path(tmp, "skills")
    shutil.copytree(skills, fixture, symlinks=True)
    for p in [fixture, *fixture.rglob("*")]:
        if not p.is_symlink():
            p.chmod(p.stat().st_mode | 0o200)
    for h in HOOKS:
        f = fixture / "hooks" / h
        if has:
            f.unlink()
        else:
            f.write_text("#!/bin/sh\nexit 0\n")
            f.chmod(0o755)
    out = subprocess.run(
        ["nix", "eval", "--json", "--impure", "--no-write-lock-file", "--override-input", "skills", f"path:{fixture}",
         f"{ROOT}#nixosConfigurations", "--apply", f"import {ROOT}/scripts/bulk-reader-probe.nix"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nix eval with the flipped skills source failed:\n{out.stderr[-800:]}")
    return json.loads(out.stdout)


def with_hooks(P, src):
    off, on = P["off"], P["on"]
    check(not any("shunt-" in c for c in commands(off["hooks"]["PreToolUse"])) and not shunt_env(off),
          "off: no shunt hook and no SHUNT_ variable")
    pre = on["hooks"]["PreToolUse"]
    reads = [e for e in pre if e.get("matcher") == "Read"]
    check(len(reads) == 1 and len(reads[0]["hooks"]) == 1
          and reads[0]["hooks"][0]["command"].endswith(f"{src}/hooks/shunt-check-read.sh")
          and "/bin:$PATH " in reads[0]["hooks"][0]["command"] and reads[0]["hooks"][0]["timeout"] == 15,
          f"on: one Read entry runs shunt-check-read.sh with its tools on PATH (got {reads})")
    (before,), (after,) = bash_lists(off), bash_lists(on)
    check(after[:len(before)] == before and len(after) == len(before) + 1
          and after[-1].endswith(f"{src}/hooks/shunt-check-bash-read.sh"),
          f"on: the Bash list is the off list, in order, plus shunt-check-bash-read.sh last (got {after})")
    names = [c.rsplit("/", 1)[-1] for c in after]
    check(names.index("validate-bash.sh") < names.index("check-loop.sh") < names.index("shunt-check-bash-read.sh"),
          f"on: shunt-check-bash-read.sh runs after validate-bash.sh and check-loop.sh ({names})")
    strip = lambda s: {**s, "PreToolUse": [e for e in s["PreToolUse"] if e.get("matcher") != "Bash" and e.get("matcher") != "Read"],
                       "PostToolUse": [e for e in s["PostToolUse"] if e.get("matcher") != "Bash"]}
    check(strip(on["hooks"]) == strip(off["hooks"]), "on: every other hook event is unchanged")
    spills = [e for e in on["hooks"]["PostToolUse"] if e.get("matcher") == "Bash"]
    check(len(spills) == 1 and [c.rsplit("/", 1)[-1] for c in commands(spills)] == ["shunt-spill-output.sh"]
          and not any(e.get("matcher") == "Bash" for e in off["hooks"]["PostToolUse"]),
          f"on: one PostToolUse Bash entry runs shunt-spill-output.sh, none when off (got {spills})")
    no = P["noSpill"]
    check(no["hooks"]["PostToolUse"] == off["hooks"]["PostToolUse"] and no["hooks"]["PreToolUse"] == [
              e for e in on["hooks"]["PreToolUse"]],
          "spillOutput = false: PostToolUse is the off one, the read hooks stay")
    check(shunt_env(on) == {"SHUNT_MIN_TOKENS": "9000", "SHUNT_MODEL": "sonnet"}
          and {k: v for k, v in on["env"].items() if not k.startswith("SHUNT_")} == off["env"],
          f"on: minTokens and model reach settings.env as SHUNT_ variables, nothing else changes ({shunt_env(on)})")

    g_on, g_off = P["guestOn"], P["guestOff"]
    check(not any("shunt-" in c for c in commands(g_off["hooks"]["PreToolUse"])) and not shunt_env(g_off),
          "guest without the guest module: no shunt hook (the host's value is not inherited)")
    lists = bash_lists(g_on)
    flat = [c for l in lists for c in l]
    check(any(c.endswith("/no-verify-guard") for c in flat) and any(c.endswith("/validate-bash.sh") for c in flat)
          and any(c.endswith("/check-merge.sh") for c in flat) == any(c.endswith("/check-merge.sh") for c in commands(g_off["hooks"]["PreToolUse"])),
          "guest on: the guest's no-verify-guard and the fleet's Bash hooks are all still there")
    fleet = next(l for l in lists if any(c.endswith("/validate-bash.sh") for c in l))
    off_fleet = next(l for l in bash_lists(g_off) if any(c.endswith("/validate-bash.sh") for c in l))
    check(fleet == off_fleet + [fleet[-1]] and fleet[-1].endswith("/shunt-check-bash-read.sh"),
          f"guest on: shunt-check-bash-read.sh is appended to the fleet's Bash list ({fleet})")
    check(sum(e.get("matcher") == "Read" for e in g_on["hooks"]["PreToolUse"]) == 1 and not shunt_env(g_on),
          "guest on: one Read entry, and no SHUNT_ variable with the defaults")
    print("guest on PreToolUse: " + json.dumps(g_on["hooks"]["PreToolUse"]))


def without_hooks(P):
    for case in ("on", "guestOn"):
        check(P[case]["hooks"] == P["off" if case == "on" else "guestOff"]["hooks"] and not shunt_env(P[case]),
              f"{case} with a pin lacking the hooks: the settings are the off ones")


def main():
    P = gate_probe.section("bulk-reader")
    skills = P["skills"]
    has = all(pathlib.Path(skills, "hooks", h).exists() for h in HOOKS)
    print(f"pinned skills {skills} {'carries' if has else 'lacks'} the shunt hooks")
    with tempfile.TemporaryDirectory() as tmp:
        F = flipped(skills, tmp, has)
        src = next((c.split(" ")[-1].rsplit("/hooks/", 1)[0] for c in commands(F["off"]["hooks"]["PreToolUse"])), "")
    with_hooks(*((P, skills) if has else (F, src)))
    without_hooks(F if has else P)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
