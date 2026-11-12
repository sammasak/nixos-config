"""lenovo's nix-daemon builds stay bounded (nixos-config#109), and so do the environment hosts' (acer, msi)."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def size(v):
    units = {"K": 2**10, "M": 2**20, "G": 2**30}
    return int(v[:-1]) * units[v[-1]] if v and v[-1] in units else None


P = gate_probe.section("build-bounds")
lenovo = P["daemon"]["lenovo"] or {}
settings = P["settings"] or {}
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
for host in ("acer-swift", "msi-ms7758"):
    daemon = P["daemon"][host] or {}
    high, cap = size(daemon.get("MemoryHigh")), size(daemon.get("MemoryMax"))
    check(high is not None and cap is not None and high < cap <= 6 * 2**30,
          f"{host}, whose environments build in its daemon, bounds it at most 6G ({daemon.get('MemoryHigh')}, {daemon.get('MemoryMax')})")
    check(daemon.get("CPUQuota") == "400%",
          f"{host} caps the daemon's CPU at the 2 jobs x 2 cores a guest's -j and --cores cannot lift ({daemon.get('CPUQuota')})")
sys.exit(1 if failed else 0)
