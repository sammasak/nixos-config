#!/usr/bin/env python3
"""The series node_exporter's systemd collector sends with the given command line, from SRC/collector/systemd_linux.go
(the build sandbox has no D-Bus to run it): every BuildFQName name, less those an --collector.systemd.enable-* flag
gates, by the names its help text lists, while that flag is off. Prints `name 0` lines.
Usage: node-exporter-systemd-names.py SRC ARG..."""
import re
import sys

text = open(sys.argv[1] + "/collector/systemd_linux.go").read()
args = sys.argv[2:]
names = re.findall(r'BuildFQName\(namespace, subsystem, "(\w+)"\)', text)
gates = re.findall(r'kingpin\.Flag\("(collector\.systemd\.enable-[\w-]+)", "([^"]*)"\)', text)
if not names or not gates:
    sys.exit("node-exporter-systemd-names: no names or no enable flags read")
off = {n for flag, help in gates if f"--{flag}" not in args for n in names if re.search(rf"\b{n}\b", help)}
for n in names:
    if n not in off:
        print(f"node_systemd_{n} 0")
