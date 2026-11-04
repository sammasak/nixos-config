"""lenovo's nix-daemon builds stay bounded (nixos-config#109); acer, the build host, keeps its defaults."""
import json
import subprocess
import sys

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def ev(attr):
    out = subprocess.run(["nix", "eval", "--json", attr], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 else None


def size(v):
    units = {"K": 2**10, "M": 2**20, "G": 2**30}
    return int(v[:-1]) * units[v[-1]] if v and v[-1] in units else None


def cfg(host):
    return f".#nixosConfigurations.{host}.config"


lenovo = ev(cfg("lenovo") + ".systemd.services.nix-daemon.serviceConfig") or {}
settings = ev(cfg("lenovo") + ".nix.settings") or {}
check(settings.get("max-jobs") == 2 and settings.get("cores") == 2,
      f"lenovo builds at most 2 derivations at once, 2 cores each ({settings.get('max-jobs')}, {settings.get('cores')})")
high, cap = size(lenovo.get("MemoryHigh")), size(lenovo.get("MemoryMax"))
check(high is not None and cap is not None and high < cap,
      f"lenovo's nix-daemon is throttled before it is capped (MemoryHigh {lenovo.get('MemoryHigh')} < MemoryMax {lenovo.get('MemoryMax')})")
# measured on acer 2026-11-04: cargo-semver-checks 0.50.0, cores 2, max-jobs 1: memory.peak 6118 MiB, swap 0
measured = 6118 * 2**20
check(cap is not None and measured < cap,
      f"the measured cores-2 build peak (6118 MiB) fits under MemoryMax ({lenovo.get('MemoryMax')})")
ram = 15.3 * 2**30
check(cap is not None and cap <= ram / 2,
      "MemoryMax leaves at least half of lenovo's 15.3 GiB to k3s, the agents and the desktop")
acer = ev(cfg("acer-swift") + ".systemd.services.nix-daemon.serviceConfig") or {}
acer_settings = ev(cfg("acer-swift") + ".nix.settings") or {}
check("MemoryMax" not in acer and acer_settings.get("cores") != 2,
      "acer, where heavy gates belong, keeps its build parallelism and no daemon cap")
sys.exit(1 if failed else 0)
