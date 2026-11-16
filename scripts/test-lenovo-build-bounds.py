"""lenovo's nix-daemon builds stay bounded (nixos-config#109), and so do the environment hosts' (acer, msi); lenovo's user slice has a ceiling (#353)."""
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
      "MemoryMax leaves at least half of lenovo's 15.3 GiB to its services, the agents and the desktop")
# nixos-config#353: a client-side evaluation runs in the user slice, which the daemon cap does not hold
user = P["userSlice"] or {}
ucap, uswap = size(user.get("MemoryMax")), size(user.get("MemorySwapMax"))
# measured on lenovo while it still ran k3s, peaks since boot in GiB: k3s server 3.1, pods 1.7, system.slice
# without a build 0.9, kernel 0.6, the zram store 0.44; k3s is gone, so this is now an upper bound
control = (3.1 + 1.7 + 0.9 + 0.6 + 0.44) * 2**30
check(ucap is not None and ucap + control <= ram,
      f"the user ceiling ({user.get('MemoryMax')}) plus the measured control plane (6.7 GiB at its peaks) fits in lenovo's 15.3 GiB")
# measured: the idle sessions hold at most 4.6 GiB that cannot be dropped (anon plus shmem; the rest is file
# cache), and the largest user transient unit in a day of 829 peaked at 3.0 GiB
idle, unit = 4.6 * 2**30, 3.0 * 2**30
check(ucap is not None and idle + unit < ucap,
      "the idle sessions (4.6 GiB not reclaimable) plus the largest measured unit (3.0 GiB) fit under the ceiling")
check(ucap is not None and uswap is not None and uswap * 4 <= ucap,
      "the slice's swap is at most a quarter of its ceiling, as in the worker pools: zram is charged to no cgroup")
check("MemoryHigh" not in user,
      "the user slice has no MemoryHigh: a runaway reaches the limit and is killed instead of stalling every session")
for host in ("acer-swift", "msi-ms7758"):
    daemon = P["daemon"][host] or {}
    high, cap = size(daemon.get("MemoryHigh")), size(daemon.get("MemoryMax"))
    check(high is not None and cap is not None and high < cap <= 6 * 2**30,
          f"{host}, whose environments build in its daemon, bounds it at most 6G ({daemon.get('MemoryHigh')}, {daemon.get('MemoryMax')})")
    check(daemon.get("CPUQuota") == "400%",
          f"{host} caps the daemon's CPU at the 2 jobs x 2 cores a guest's -j and --cores cannot lift ({daemon.get('CPUQuota')})")
sys.exit(1 if failed else 0)
