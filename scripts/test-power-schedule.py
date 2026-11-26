"""The work-hours power windows (modules/core/power-schedule.nix) as each host renders them: lenovo, the always-on
waker, sends every host whose fleet entry has a power window its Wake-on-LAN packet at the window's wake, each such host
powers itself off at its off and arms Wake-on-LAN on its fleet interface, and no other host gets any of these units.
asus alone unbinds its xHCI controller on poweroff, or it boots again.
Both edges come from the fleet's one night (sam.fleet.night): the windows' off and wake on their days, and the quiet
hosts' night-quiet units every night (scripts/test-night-quiet.py tests their decision). The assertions refuse a window
on a host that is not marked sleeps, a waker on a sleeping host, a window host whose NIC's Wake-on-LAN is turned off,
a host both windowed and quiet, a quiet Pi, and a quiet host that disables intel_pstate."""

import os
import re
import subprocess

import gate_probe
from gate_probe import check, finish



P = gate_probe.section("power-schedule")
units, fleet, F = P["units"], P["fleet"], P["failing"]
windowed = {n: h["power"] for n, h in fleet.items() if h["power"]}
check(set(windowed) == {"msi-ms7758", "asus-b460m"}, f"msi-ms7758 and asus-b460m have a power window ({sorted(windowed)})")


def prefix(name):
    return name.split("-")[0]


# the waker: lenovo alone, one wake per window host, at its wake and with its MAC, no catch-up of a missed tick
lenovo = units["lenovo"]
for name, w in windowed.items():
    service, timer = lenovo.get(f"{prefix(name)}-wake.service", ""), lenovo.get(f"{prefix(name)}-wake.timer", "")
    check(f"wakeonlan {w['mac']}" in service and "Type=oneshot" in service,
          f"lenovo's {prefix(name)}-wake sends {name}'s Wake-on-LAN packet to {w['mac']}")
    check(f"OnCalendar={w['wake']}" in timer and "Persistent=false" in timer and "WantedBy=timers.target" in timer,
          f"lenovo's {prefix(name)}-wake.timer fires at {w['wake']} and does not catch up")
wakes = sorted(u for h, us in units.items() for u in us if "-wake." in u and h != "lenovo")
check(wakes == [], f"no host but lenovo sends a wake ({wakes})")

# the poweroff: each window host its own, at its off; nothing on any other host
for host, us in units.items():
    mine = sorted(u for u in us if "-scheduled-shutdown." in u)
    if host in windowed:
        timer = us.get(f"{prefix(host)}-scheduled-shutdown.timer", "")
        check(mine == [f"{prefix(host)}-scheduled-shutdown.service", f"{prefix(host)}-scheduled-shutdown.timer"]
              and f"OnCalendar={windowed[host]['off']}" in timer and "Persistent=false" in timer
              and "systemctl poweroff" in us[f"{prefix(host)}-scheduled-shutdown.service"],
              f"{host} powers itself off at {windowed[host]['off']} ({mine})")
    else:
        check(mine == [], f"{host} has no scheduled poweroff ({mine})")

def next_occurrences(calendar):
    result = subprocess.run(
        ["systemd-analyze", "calendar", "--base-time=2026-11-21 10:00:00 UTC",
         "--iterations=2", calendar],
        capture_output=True, text=True, check=True, timeout=10,
        env={**os.environ, "TZ": "UTC0", "LC_ALL": "C"},
    )
    return re.findall(
        r"(?:Next elapse|Iteration #\d+): \w{3} (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) UTC",
        result.stdout,
    )


night_start = P["night"]["start"] + ":00"
weekend = [("2026-11-21", night_start), ("2026-11-22", night_start)]
weekdays = [("2026-11-23", night_start), ("2026-11-24", night_start)]
check(next_occurrences(windowed["asus-b460m"]["off"]) == weekend,
      "a manual ASUS weekend wake still shuts down Saturday and Sunday nights")
check(next_occurrences("Mon-Fri " + P["night"]["start"]) == weekdays,
      "seeded: weekday-only shutdown misses both weekend nights")
check(next_occurrences(windowed["msi-ms7758"]["off"]) == weekdays,
      "MSI retains its weekday-only shutdown policy")
for name, window in windowed.items():
    wake_time = P["night"]["end"] + ":00"
    check(next_occurrences(window["wake"]) == [("2026-11-23", wake_time), ("2026-11-24", wake_time)],
          f"{name} still has no automatic weekend wake")


# Wake-on-LAN armed by each window host on its fleet interface, by the module; no other host has a wol unit
for host, us in units.items():
    mine = sorted(u for u in us if u.startswith("wol-"))
    if host in windowed:
        nic = windowed[host]["interface"]
        service = us.get(f"wol-{nic}.service", "")
        check(mine == [f"wol-{nic}.service"] and f"ethtool -s {nic} wol g" in service and "Type=oneshot" in service
              and "RemainAfterExit=true" in service and "WantedBy=multi-user.target" in service,
              f"{host} arms Wake-on-LAN on {nic} at boot ({mine})")
    else:
        check(mine == [], f"{host} has no Wake-on-LAN unit ({mine})")

# asus's xHCI unbind (hosts/asus-b460m/configuration.nix): on poweroff only, and on no other host
for host, hooks in P["shutdownHooks"].items():
    if host == "asus-b460m":
        text = open(hooks["asus-xhci-unbind"]).read() if "asus-xhci-unbind" in hooks else ""
        check('[ "$1" = poweroff ] || exit 0' in text
              and "echo 0000:00:14.0 > /sys/bus/pci/drivers/xhci_hcd/unbind" in text,
              f"asus-b460m unbinds xhci_hcd from 0000:00:14.0 on poweroff only ({sorted(hooks)})")
    else:
        check("asus-xhci-unbind" not in hooks, f"{host} has no xHCI unbind hook ({sorted(hooks)})")

# assertions: clean on the real hosts, each seeded break fails with its message
awake = "modules/core/fleet.nix: asus-b460m has a power window, so it is off by plan: set sleeps = true on its entry."
sleeper = ("sam.powerSchedule.waker runs only on an always-on host; msi-ms7758 sleeps (modules/core/fleet.nix), "
           "so it would miss the wakes.")
nowol = ("asus-b460m has a power window on eno1 (modules/core/fleet.nix), so it needs "
         "networking.interfaces.eno1.wakeOnLan.enable and its wol-eno1 unit, or no wake reaches it.")
power = [m for h in ("lenovo", "msi", "asus") for m in F[h] if "power" in m or "powerSchedule" in m]
check(power == [], f"lenovo, msi and asus fail no power-window assertion ({power})")
check(awake in F["awake"], f"seeded: a power window on a host not marked sleeps fails ({F['awake']})")
check(sleeper in F["sleepingWaker"], f"seeded: the waker on msi, a sleeping host, fails ({F['sleepingWaker']})")
check(nowol in F["noWol"], f"seeded: asus without eno1's Wake-on-LAN fails ({F['noWol']})")

# the night: one fact, two behaviours
night = P["night"]
check(all(w["off"].endswith(" " + night["start"]) and w["wake"].endswith(" " + night["end"]) for w in windowed.values()),
      f"every power window switches at the fleet's night ({night['start']}-{night['end']}): {windowed}")
quiet = {n: h["quiet"] for n, h in fleet.items() if h["quiet"]}
check(set(quiet) == {"lenovo-21CB001PMX", "acer-swift"} and all(q["driver"] == "intel_pstate" for q in quiet.values()),
      f"lenovo and acer-swift are quiet at night, by intel_pstate ({quiet})")
config_of = {"lenovo-21CB001PMX": "lenovo"}
for host, us in units.items():
    mine = sorted(u for u in us if u.startswith("night-quiet"))
    name = next((n for n, c in config_of.items() if c == host), host)
    if name in quiet:
        pct = quiet[name]["maxPerfPct"]
        args = f"night-quiet.sh {night['start']} {night['end']} {pct}"
        boot, edge, timer = us.get("night-quiet.service", ""), us.get("night-quiet-edge.service", ""), us.get("night-quiet-edge.timer", "")
        check(mine == ["night-quiet-edge.service", "night-quiet-edge.timer", "night-quiet.service"]
              and args in boot and "RemainAfterExit=true" in boot and "WantedBy=multi-user.target" in boot
              and args in edge and "RemainAfterExit" not in edge
              and f"OnCalendar=*-*-* {night['start']}:00" in timer and f"OnCalendar=*-*-* {night['end']}:00" in timer
              and "Persistent=false" in timer,
              f"{host} sets its CPU from the clock at boot and at both edges of the night, to {pct} % ({mine})")
    else:
        check(mine == [], f"{host} has no night-quiet unit ({mine})")
both = "modules/core/fleet.nix: msi-ms7758 has both a power window and a quiet night; a host is either off or throttled through the night."
pi = ("modules/core/fleet.nix: black-pi is an ARM board, fanless, with no Wake-on-LAN NIC or intel_pstate: it declares "
      "neither a power window nor a quiet night.")
pstate = "acer-swift is quiet through the night with driver intel_pstate (modules/core/fleet.nix), so it must be an x86_64 Intel host"
quietfails = [m for h in ("lenovo", "msi", "asus") for m in F[h] if "quiet" in m]
check(quietfails == [], f"lenovo, msi and asus fail no quiet-night assertion ({quietfails})")
check(both in F["quietWithWindow"], f"seeded: msi both windowed and quiet fails ({F['quietWithWindow']})")
check(pi in F["quietPi"], f"seeded: a quiet black-pi fails ({F['quietPi']})")
check(any(m.startswith(pstate) for m in F["quietNoPstate"]), f"seeded: acer with intel_pstate=disable fails ({F['quietNoPstate']})")

# a sleeping store cache's upload (modules/core/store-upload.nix): a build burst refills the queue after every send, so
# the path unit restarts the service within seconds; a start limit on it fails store-upload.path and degrades the host
uploaders = sorted(h for h, us in units.items() if "store-upload.path" in us)
check(set(windowed) <= set(uploaders), f"msi-ms7758 and asus-b460m queue their builds for upload ({uploaders})")
for host in uploaders:
    service = units[host].get("store-upload.service", "")
    path = units[host]["store-upload.path"]
    check("PathExists=/var/lib/store-upload/queue" in path, f"{host}'s store-upload.path starts the send while the queue exists")
    check("StartLimitIntervalSec=0" in service.split("[Service]")[0],
          f"{host}'s store-upload.service has no start limit, so a burst of queue writes cannot fail store-upload.path")
    check(re.search(r"^ExecStopPost=\S+/bin/sleep [1-9]", service, re.M) is not None,
          f"{host}'s store-upload.service waits after each run, so a send that keeps failing cannot restart in a hot loop")

finish()
