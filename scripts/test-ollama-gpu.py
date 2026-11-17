#!/usr/bin/env python3
"""A CUDA Ollama build needs hardware.graphics (modules/homelab/ollama-host.nix): asus as deployed fails no
assertion, and asus without it is rejected, since libcuda.so.1 is only found under /run/opengl-driver/lib."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


failing = gate_probe.section("ollama-gpu")["failing"]
check(failing["asus"] == [], f"asus fails no assertion {failing['asus']}")
check(any("hardware.graphics.enable" in m and "CUDA" in m for m in failing["noGraphics"]),
      f"a CUDA Ollama without hardware.graphics is rejected {failing['noGraphics']}")
sys.exit(failed)
