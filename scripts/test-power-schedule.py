"""The work-hours power windows (modules/core/power-schedule.nix) as each host renders them: lenovo, the always-on
waker, sends every host whose fleet entry has a power window its Wake-on-LAN packet at the window's wake, each such host
powers itself off at its off, and no other host gets either unit. The assertions refuse a window on a host that is not
marked sleeps, a waker on a sleeping host, and a window host without its NIC's Wake-on-LAN unit."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


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

sys.exit(1 if failed else 0)
