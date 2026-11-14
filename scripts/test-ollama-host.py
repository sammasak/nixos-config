"""services.ollama on acer (hosts/acer-swift/configuration.nix): acer alone runs it, bound to its fleet address;
the port is opened nowhere, so the LAN is dropped and only the trusted Cilium interfaces let pods in; one model
and one request at a time under a 4G cap with no swap, and the kernel's OOM killer takes it first."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("ollama-host")
fw = P["firewall"]
port = P["port"]

running = sorted(name for name, on in P["units"].items() if on)
check(running == ["acer-swift"], f"acer alone runs ollama {running}")
check(P["host"] == P["address"], f"it binds to acer's fleet address, not 0.0.0.0 ({P['host']} vs {P['address']})")
check(P["openFirewall"] is False, "openFirewall is off")
check(port not in fw["open"], f"port {port} is not in allowedTCPPorts {fw['open']}")
check(all(port not in ports for ports in fw["interfaces"].values()), f"no interface opens port {port} {fw['interfaces']}")
check(str(port) not in fw["extraCommands"] + fw["extraInputRules"], f"no extra firewall rule names port {port}")
trusted = set(fw["trustedInterfaces"])
check({"cilium_host", "lxc+"} <= trusted, f"pods arrive on trusted Cilium interfaces {sorted(trusted)}")
check(not any(i.startswith(("wl", "en", "eth", "tailscale")) for i in trusted),
      f"no LAN or tailnet interface is trusted {sorted(trusted)}")

env = P["environmentVariables"]
check(env.get("OLLAMA_MAX_LOADED_MODELS") == "1" and env.get("OLLAMA_NUM_PARALLEL") == "1",
      "one model and one request at a time, as the memory cap assumes")
check(sorted(P["loadModels"]) == sorted(["llama3.2:3b", "qwen2.5-coder:0.5b", "nomic-embed-text:latest"]),
      f"the pod's three models are declared {P['loadModels']}")
bounds = {k: P[k] for k in ("MemoryMax", "MemorySwapMax", "OOMScoreAdjust", "Restart")}
check(bounds == {"MemoryMax": "4G", "MemorySwapMax": 0, "OOMScoreAdjust": 1000, "Restart": "on-failure"},
      f"capped at 4G without swap, killed first, restarted when the address is late {bounds}")

sys.exit(1 if failed else 0)
