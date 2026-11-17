#!/usr/bin/env python3
"""The series one of node_exporter's collectors sends with the given command line, from
SRC/collector/<COLLECTOR>.go or <COLLECTOR>_linux.go, for collectors the build sandbox cannot run (systemd needs
D-Bus, timex adjtimex): every BuildFQName name under the file's subsystem, less those an
--collector.<COLLECTOR>.enable-* flag gates, by the names its help text lists, while that flag is off. Prints
`name 0` lines; exits non-zero if it reads no name. Usage: node-exporter-collector-names.py SRC COLLECTOR ARG..."""
import pathlib
import re
import sys

src, collector, args = pathlib.Path(sys.argv[1]) / "collector", sys.argv[2], sys.argv[3:]
path = next((p for p in (src / f"{collector}_linux.go", src / f"{collector}.go") if p.exists()), None)
text = path.read_text() if path else ""
subsystem = re.search(r'\bsubsystem\s*=\s*"(\w+)"', text)
names = re.findall(r'BuildFQName\(namespace, subsystem, "(\w+)"\)', text)
if not subsystem or not names:
    sys.exit(f"node-exporter-collector-names: no {collector} names read from {src}")
gates = re.findall(r'kingpin\.Flag\("(collector\.' + collector + r'\.enable-[\w-]+)", "([^"]*)"\)', text)
off = {n for flag, help in gates if f"--{flag}" not in args for n in names if re.search(rf"\b{n}\b", help)}
for n in names:
    if n not in off:
        print(f"node_{subsystem.group(1)}_{n} 0")
