#!/usr/bin/env python3
"""A CUDA Ollama build needs hardware.graphics (modules/homelab/ollama-host.nix): asus as deployed fails no
assertion, and asus without it is rejected, since libcuda.so.1 is only found under /run/opengl-driver/lib. asus's
gpu check builds, and fails on asus with graphics but no NVIDIA library in the drivers env. The GPU power cap is a
oneshot wanted by Ollama and ordered before it, never required, with a start timeout, after nvidia-persistenced, and a
cap outside the card's range fails evaluation. A server context outside 4096 to 32768 (pi's own prompt; qwen2.5-coder's
trained context) fails evaluation.

The two gpu-check builds compile asus's CUDA closure. They follow nixos-flake-check's rule for checks (#502):
- **Built** where nothing would compile against CUDA, and on asus itself.
- **Deferred** elsewhere: printed, recorded with seconds=0, and listed in the gate's deferred summary, instead of
  compiling CUDA on msi, acer or lenovo."""
import json
import os
import subprocess
import sys

import gate_defer
import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): ") + what)
    failed += not ok


P = gate_probe.section("ollama-gpu")
failing = P["failing"]
check(failing["asus"] == [], f"asus fails no assertion {failing['asus']}")
check(any("hardware.graphics.enable" in m and "CUDA" in m for m in failing["noGraphics"]),
      f"a CUDA Ollama without hardware.graphics is rejected {failing['noGraphics']}")

u = P["powerUnit"]
check(u["Type"] == "oneshot" and u["ExecStart"].endswith("/bin/nvidia-smi -pl 130") and not u["remain"],
      f"nvidia-power-limit runs nvidia-smi -pl 130 as a oneshot, again on each start ({u})")
check("ollama.service" in u["wantedBy"] and "multi-user.target" in u["wantedBy"] and "ollama.service" in u["before"],
      f"the cap is wanted by Ollama and multi-user.target, ordered before Ollama ({u['wantedBy']}, {u['before']})")
check(not u["requiredBy"] and "nvidia-power-limit.service" not in u["ollamaRequires"] + u["ollamaBindsTo"],
      f"a failed cap does not stop Ollama: nothing requires or binds to it ({u['requiredBy']}, {u['ollamaRequires']}, {u['ollamaBindsTo']})")
check(u["timeout"] == "30s",
      f"a hung nvidia-smi fails after 30 s instead of holding Ollama's start and a switch (TimeoutStartSec {u['timeout']})")
check(u["persistenced"] and "nvidia-persistenced.service" in u["after"],
      f"persistence keeps the cap between model loads, and the cap is set after nvidia-persistenced ({u['after']})")
for seed, watts in (("powerHigh", 271), ("powerLow", 99)):
    check(any(f"gpuPowerLimit is {watts} W" in m for m in failing[seed]),
          f"seeded: a {watts} W cap fails evaluation {failing[seed]}")
check(any("OLLAMA_CONTEXT_LENGTH is 65536" in m for m in failing["ctx64k"]),
      f"seeded: a server context above qwen's trained 32768 fails evaluation {failing['ctx64k']}")
check(any("OLLAMA_CONTEXT_LENGTH is 2048" in m for m in failing["ctx2k"]),
      f"seeded: a server context under 4096, too small for pi's own prompt, fails evaluation {failing['ctx2k']}")


# nixos-flake-check's rule (scripts/gate_defer.py, the pattern from devenv.nix's gateHeavy): a build whose to-build
# inputs compile against CUDA runs on its node only, and anything a substituter has is no compile at all
OWNER = "asus-b460m"


def realise(drv, name):
    """name is the check's id in records and the deferred list (ollama-gpu-test/<name>), without spaces."""
    if not drv:
        return None, "no asus-ollama-gpu-check in system.checks"
    defer = gate_defer.deferred(drv, name, OWNER, "ollama-gpu-test")
    if defer:
        n, heavy = defer
        print(f"ollama-gpu-test: deferred {name} to {OWNER} (compiles {n}) {drv}: it would compile against {' '.join(heavy)}")
        gate_defer.record_deferral("ollama-gpu-test", f"ollama-gpu-test/{name}", OWNER, drv)
        return "deferred", ""
    out = subprocess.run(["nix-store", "--realise", drv], capture_output=True, text=True, check=False)
    return out.returncode, out.stdout + out.stderr


def instantiated(drvs):
    """The probe keeps only the .drv paths (no string context), and the gate's GC (GC_FREE_SPACE_DIVISOR) may have
    collected those unrooted .drv files by now: then re-evaluate this section, which writes them again."""
    paths = [d for d in drvs.values() if d]
    valid = subprocess.run(["nix-store", "--check-validity", *paths], capture_output=True, text=True, check=False)
    if valid.returncode == 0:
        return drvs
    out = subprocess.run(["nix", "eval", "--json", "--impure", "--expr",
                          '(import ./scripts/gate-probe.nix { only = [ "ollama-gpu" ]; }).sections."ollama-gpu".check'],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.exit(f"ollama-gpu-test: re-instantiating the gpu checks failed: {out.stderr.strip()[-300:]}")
    return json.loads(out.stdout)


def owned(name, drv, ok, result="built"):
    """On the owning host, a check that did what this test expects is recorded for the head: the deferral's other half
    (expected-fail for the seeded one, whose build must fail)."""
    if ok and os.uname().nodename.startswith(OWNER):
        gate_defer.record_owned("ollama-gpu-test", f"ollama-gpu-test/{name}", OWNER, drv, result)


checks = instantiated(P["check"])
rc, log = realise(checks["asus"], "asus-ollama-gpu-check")
check(rc in (0, "deferred"),
      f"asus-ollama-gpu-check builds: RUNPATH has /run/opengl-driver/lib, the drivers env has libcuda.so.1, or it is deferred to {OWNER} (rc {rc}: {log.strip()[-300:]})")
owned("asus-ollama-gpu-check", checks["asus"], rc == 0)
rc, log = realise(checks["noNvidiaLibs"], "asus-ollama-gpu-check-no-nvidia-libs")
check(rc == "deferred" or (rc not in (0, None) and "no lib/libcuda.so.1" in log),
      f"seeded: graphics without the NVIDIA library fails the gpu check, or it is deferred to {OWNER} (rc {rc}: {log.strip()[-300:]})")
owned("asus-ollama-gpu-check-no-nvidia-libs", checks["noNvidiaLibs"], rc not in (0, None, "deferred") and "no lib/libcuda.so.1" in log,
      "expected-fail")
sys.exit(failed)
