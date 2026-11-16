# lenovo's ssh -L forward to acer can keep listening after its far end is gone,
# before keepalives give up, so Restart= never fires. This runs the forward,
# probes it, and exits when nothing answers so the unit restarts it.
# Any HTTP status is alive: only a failed connection means the forward is dead.
{
  writeShellApplication,
  curl,
  coreutils,
}:
writeShellApplication {
  name = "ollama-portforward";
  runtimeInputs = [
    curl
    coreutils
  ];
  text = ''
    url=''${1:?usage: ollama-portforward <probe-url> <command...>}
    shift
    interval=''${PROBE_INTERVAL:-10}
    limit=''${PROBE_FAILURES:-3}
    "$@" &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true' EXIT
    fails=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep "$interval"
      code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$url" || true)
      if [ "$code" = 000 ]; then fails=$((fails + 1)); else fails=0; fi
      if [ "$fails" -ge "$limit" ]; then
        echo "ollama-portforward: $url gave no response $fails times in a row; exiting to restart" >&2
        exit 1
      fi
    done
    rc=0
    wait "$pid" || rc=$?
    echo "ollama-portforward: forward exited ($rc)" >&2
    exit $((rc == 0 ? 1 : rc))
  '';
}
