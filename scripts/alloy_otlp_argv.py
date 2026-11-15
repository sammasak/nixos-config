"""acer's alloy-otlp unit as evaluated (scripts/gate-probe.nix, section alloy-otlp) for the alloy-otlp tests: its
ExecStart split as systemd splits it, less the token wrapper (a test exports its own token), with the arguments a test
must point elsewhere replaced. Each replacement must hit exactly one argument, so arguments run together fail here.
As a command: `config` prints the deployed config's path, `loki` the Loki binary, and LISTEN STORAGE CONFIG prints
the overridden argv NUL-separated, for the shell test."""
import shlex
import sys

import gate_probe


def unit():
    probe = gate_probe.section("alloy-otlp")
    argv = shlex.split(probe["execStart"] or "")
    if not (len(argv) > 3 and argv[0].endswith("-alloy-otlp-token") and argv[1].endswith("/bin/alloy")
            and argv[2] == "run" and argv[-1].endswith("-alloy-otlp.alloy")):
        sys.exit(f"alloy-otlp ExecStart is not token wrapper, alloy run ..., config: {argv}")
    return argv[1:], probe["loki"]


def config_path():
    return unit()[0][-1]


def overridden(listen, storage, config):
    argv, _ = unit()
    out = list(argv)
    for match, new in ((lambda a: a.startswith("--server.http.listen-addr="), f"--server.http.listen-addr={listen}"),
                       (lambda a: a.startswith("--storage.path="), f"--storage.path={storage}"),
                       (lambda a: a == argv[-1], config)):
        hits = [i for i, a in enumerate(out) if match(a)]
        if len(hits) != 1:
            sys.exit(f"alloy-otlp ExecStart: {len(hits)} arguments to replace with {new}, not one: {argv}")
        out[hits[0]] = new
    return out


if __name__ == "__main__":
    if sys.argv[1:] == ["config"]:
        print(config_path())
    elif sys.argv[1:] == ["loki"]:
        print(unit()[1])
    else:
        sys.stdout.write("".join(a + "\0" for a in overridden(*sys.argv[1:4])))
