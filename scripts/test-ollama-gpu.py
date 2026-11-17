#!/usr/bin/env python3
"""A CUDA Ollama build needs hardware.graphics (modules/homelab/ollama-host.nix): asus as deployed fails no
assertion, and asus without it is rejected, since libcuda.so.1 is only found under /run/opengl-driver/lib. asus's
gpu check builds, and fails on asus with graphics but no NVIDIA library in the drivers env. A server context above
qwen2.5-coder's trained 32768 fails evaluation."""
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

check(any("OLLAMA_CONTEXT_LENGTH is 65536" in m for m in failing["ctx64k"]),
      f"seeded: a server context above qwen's trained 32768 fails evaluation {failing['ctx64k']}")


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
