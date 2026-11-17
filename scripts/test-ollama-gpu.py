#!/usr/bin/env python3
"""A CUDA Ollama build needs hardware.graphics (modules/homelab/ollama-host.nix): asus as deployed fails no
assertion, and asus without it is rejected, since libcuda.so.1 is only found under /run/opengl-driver/lib. asus's
gpu check builds, and fails on asus with graphics but no NVIDIA library in the drivers env. The GPU power cap is a
oneshot wanted by Ollama and ordered before it, never required, with a start timeout, after nvidia-persistenced, and a
cap outside the card's range fails evaluation."""
import subprocess
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
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


def realise(drv):
    if not drv:
        return None, "no asus-ollama-gpu-check in system.checks"
    out = subprocess.run(["nix-store", "--realise", drv], capture_output=True, text=True)
    return out.returncode, out.stdout + out.stderr


rc, log = realise(P["check"]["asus"])
check(rc == 0, f"asus-ollama-gpu-check builds: RUNPATH has /run/opengl-driver/lib, the drivers env has libcuda.so.1 (rc {rc}: {log.strip()[-300:]})")
rc, log = realise(P["check"]["noNvidiaLibs"])
check(rc not in (0, None) and "no lib/libcuda.so.1" in log,
      f"seeded: graphics without the NVIDIA library fails the gpu check (rc {rc}: {log.strip()[-300:]})")
sys.exit(failed)
