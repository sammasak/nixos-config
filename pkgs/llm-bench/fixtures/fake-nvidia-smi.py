"""nvidia-smi --query-gpu=... --format=csv in nvidia-smi's CSV form (units in the header, the throttle bitmask in hex)
for one RTX 3070, for the exporter check. Written from the driver's documented output, not captured from it, except
that asus's driver (595) heads the clocks_throttle_reasons.* fields clocks_event_reasons.*, which names the metrics."""
import sys

VALUES = {
    "name": "NVIDIA GeForce RTX 3070", "uuid": "GPU-00000000-0000-0000-0000-000000000000", "driver_version": "595.104.02",
    "driver_model.current": "[N/A]", "driver_model.pending": "[N/A]", "vbios_version": "94.04.00.00.00",
    "pci.bus_id": "00000000:01:00.0", "serial": "[N/A]", "compute_cap": "8.6", "pci.sub_device_id": "0x00000000",
    "index": "0", "memory.total": ("MiB", "8192 MiB"), "memory.used": ("MiB", "6656 MiB"),
    "memory.free": ("MiB", "1536 MiB"), "utilization.gpu": ("%", "42 %"), "temperature.gpu": "65",
    "power.draw": ("W", "150.00 W"), "power.limit": ("W", "220.00 W"), "fan.speed": ("%", "45 %"),
    "enforced.power.limit": ("W", "130.00 W"),
    "clocks_throttle_reasons.sw_thermal_slowdown": "Active",
}
args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
fields = args["--query-gpu"].split(",")
head, row = [], []
for f in fields:
    v = VALUES.get(f, "Not Active" if f.startswith("clocks_throttle_reasons.") else None)
    if f == "clocks_throttle_reasons.active":
        # Match the active software thermal reason above (bit 0x20).
        v = "0x0000000000000020"
    if v is None:
        sys.exit(f"fake nvidia-smi: Field \"{f}\" is not a valid field to query.")
    unit, val = v if isinstance(v, tuple) else (None, v)
    name = f.replace("clocks_throttle_reasons.", "clocks_event_reasons.", 1)
    head.append(f"{name} [{unit}]" if unit else name)
    row.append(val)
print(", ".join(head))
print(", ".join(row))
