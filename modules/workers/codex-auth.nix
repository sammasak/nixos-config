# The slots' Codex on the host user's own Codex login, sam.workers.codexAuthFile (nixos-config#808): root derives the
# egress proxy's credentials from it, the timer lets Codex refresh it in place as that user, and nothing copies it.
# A ChatGPT refresh token reused is lost for good (docs/records/execution-pool-credentials.md), so a failed refresh
# is never retried.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sam.workers;
  dev = config.services.devEnvironments;
  auth = cfg.codexAuthFile;
  inherit (cfg.codexEgress) tokens;
  ready = "${dirOf tokens}/ready";
  owner = dev.user;
  ownerHome = config.users.users.${owner}.home;
  asOwner = "${pkgs.util-linux}/bin/setpriv --reuid=${owner} --regid=users --init-groups";
  textfile = "/run/node-exporter-textfile/codex-egress.prom";
  stateDir = "codex-egress-refresh";

  # Read as its owner, so a link in the owner's home reaches nothing root alone may read. A file that does not
  # parse (a write in flight) is read again for 10 s, then keeps the last credentials.
  derive = pkgs.writeShellApplication {
    name = "codex-egress-token";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      was=0; [[ -e ${ready} ]] && was=1
      install -d -m 0755 -o root -g root ${tokens}
      json=
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! json=$(${asOwner} cat -- ${auth} 2>/dev/null); then
          json=
          break
        fi
        printf '%s' "$json" | jq -e . >/dev/null 2>&1 && break
        json=partial
        sleep 1
      done
      if [[ $json == partial ]]; then
        echo "codex-egress: ${auth} does not parse (a write in flight?); the last credentials stay" >&2
        exit 0
      fi
      put() {
        local tmp
        tmp=$(mktemp -p ${tokens})
        printf '%s' "$2" > "$tmp"
        chown ${owner} "$tmp"
        chmod 0400 "$tmp"
        mv -f "$tmp" ${tokens}/"$1"
      }
      get() { printf '%s' "$json" | jq -j "$1 // empty | strings"; }
      if [[ -n $json && -n $(get .tokens.access_token) && -n $(get .tokens.account_id) ]]; then
        put access-token "$(get .tokens.access_token)"
        put account-id "$(get .tokens.account_id)"
        rm -f ${tokens}/openai-key
        now=1
      elif [[ -n $json && -n $(get .OPENAI_API_KEY) ]]; then
        put openai-key "$(get .OPENAI_API_KEY)"
        rm -f ${tokens}/access-token ${tokens}/account-id
        now=1
      else
        rm -f ${tokens}/access-token ${tokens}/account-id ${tokens}/openai-key
        echo ${lib.escapeShellArg "codex-egress: no Codex login in ${auth}; codex is not offered. Sign in as ${owner} with: codex login --device-auth"} >&2
        now=0
      fi
      if (( now )); then install -m 0644 /dev/null ${ready}; else rm -f ${ready}; fi
      # the runners advertise codex as of their start (exec-pool-runner.nix): only a change of the login restarts them,
      # and a restarted runner adopts its running attempt
      if (( was != now )); then
        systemctl try-restart 'exec-pool-runner-*.service' || true
      fi
    '';
  };

  # Upstream Codex refreshes through its own auth manager: app-server's account/read with refreshToken forces a refresh
  # (codex-rs app-server account_processor.rs, refresh_token_if_requested), and calls no model. It reports no outcome,
  # so success is auth.json's last_refresh moving. The failure marker is written before the attempt: one that dies
  # midway may have spent the refresh token too, and none is tried again until the refresh token changes.
  refresh = pkgs.writers.writePython3Bin "codex-egress-refresh" { doCheck = false; } ''
    import base64
    import hashlib
    import json
    import os
    import pathlib
    import select
    import subprocess
    import sys
    import time

    AUTH = pathlib.Path(os.environ["CODEX_EGRESS_AUTH"])
    FAILED = pathlib.Path(os.environ["CODEX_EGRESS_FAILED"])
    TEXTFILE = pathlib.Path(os.environ["CODEX_EGRESS_TEXTFILE"])
    CODEX = os.environ["CODEX_EGRESS_CODEX"].split()
    READ = os.environ["CODEX_EGRESS_READ"].split()
    TIMEOUT = int(os.environ.get("CODEX_EGRESS_TIMEOUT", "120"))


    def load():
        """auth.json as its owner reads it: a link in the owner's home reaches nothing root alone may read."""
        try:
            out = subprocess.run(READ + [str(AUTH)], capture_output=True, timeout=30)
            if out.returncode != 0:
                return None, None
            return out.stdout, json.loads(out.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None, None


    def claims(token):
        try:
            part = token.split(".")[1]
            part += "=" * (-len(part) % 4)
            return json.loads(base64.urlsafe_b64decode(part))
        except (IndexError, ValueError, AttributeError):
            return {}


    def last_refresh(a):
        return (a or {}).get("last_refresh")


    def stamp(text):
        try:
            from datetime import datetime
            return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
        except (AttributeError, ValueError):
            return 0


    def metrics(present, failed, a):
        c = claims(((a or {}).get("tokens") or {}).get("access_token"))
        lines = [
            "# HELP codex_egress_login_present A ChatGPT login is in sam.workers.codexAuthFile.",
            "# TYPE codex_egress_login_present gauge",
            f"codex_egress_login_present {int(present)}",
            "# HELP codex_egress_refresh_failed A refresh failed or timed out; none is tried until the login changes.",
            "# TYPE codex_egress_refresh_failed gauge",
            f"codex_egress_refresh_failed {int(failed)}",
            "# HELP codex_egress_access_token_expiry_timestamp_seconds When the access token the proxy sends expires.",
            "# TYPE codex_egress_access_token_expiry_timestamp_seconds gauge",
            f"codex_egress_access_token_expiry_timestamp_seconds {int(c.get('exp', 0))}",
            "# HELP codex_egress_last_refresh_timestamp_seconds The login's last refresh, as auth.json records it.",
            "# TYPE codex_egress_last_refresh_timestamp_seconds gauge",
            f"codex_egress_last_refresh_timestamp_seconds {int(stamp(last_refresh(a)))}",
        ]
        tmp = TEXTFILE.with_name("." + TEXTFILE.name)
        tmp.write_text("\n".join(lines) + "\n")
        tmp.chmod(0o644)
        tmp.replace(TEXTFILE)


    def due(a):
        c = claims(a["tokens"].get("access_token"))
        exp, iat = c.get("exp"), c.get("iat")
        if not isinstance(exp, (int, float)) or not isinstance(iat, (int, float)):
            return True
        return exp - time.time() < (exp - iat) / 2


    def converse():
        """initialize, initialized, account/read {refreshToken: true}; True once account/read answered."""
        proc = subprocess.Popen(CODEX + ["app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + TIMEOUT

        def send(msg):
            proc.stdin.write((json.dumps(msg) + "\n").encode())
            proc.stdin.flush()

        def answer(rid):
            buf = b""
            while time.monotonic() < deadline:
                ready, _, _ = select.select([proc.stdout], [], [], max(0.0, deadline - time.monotonic()))
                if not ready:
                    break
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    return False
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    try:
                        if json.loads(line).get("id") == rid:
                            return True
                    except ValueError:
                        pass
            return False

        try:
            info = {"name": "codex-egress-refresh", "version": "1"}
            send({"id": 1, "method": "initialize", "params": {"clientInfo": info}})
            if not answer(1):
                return False
            send({"method": "initialized"})
            send({"id": 2, "method": "account/read", "params": {"refreshToken": True}})
            return answer(2)
        except OSError:
            return False
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


    def main():
        _, a = load()
        if a is None or not (a.get("tokens") or {}).get("refresh_token"):
            FAILED.unlink(missing_ok=True)
            metrics(False, False, None)
            print("no ChatGPT login to refresh", file=sys.stderr)
            return 0
        # the refresh token alone: a rewrite that keeps it (a format migration, an edit) must not clear the failure
        digest = hashlib.sha256(str(a["tokens"]["refresh_token"]).encode()).hexdigest()
        if FAILED.exists():
            if FAILED.read_text().strip() == digest:
                metrics(True, True, a)
                print("an earlier refresh of this login failed: not retried until a new login", file=sys.stderr)
                return 0
            FAILED.unlink()
        if not due(a):
            metrics(True, False, a)
            return 0
        before = last_refresh(a)
        FAILED.write_text(digest + "\n")
        answered = converse()
        _, after = load()
        if after is not None and last_refresh(after) != before:
            FAILED.unlink(missing_ok=True)
            metrics(True, False, after)
            print("refreshed", file=sys.stderr)
            return 0
        metrics(True, True, after or a)
        why = "it did not record a new refresh" if answered else "app-server did not answer in time"
        print(f"refresh failed: {why}; not retried until a new login", file=sys.stderr)
        return 0


    sys.exit(main())
  '';
in
{
  options.sam.workers.codexEgress = {
    serveFleet = lib.mkEnableOption "the Codex route, signed with sam.workers.codexAuthFile, for the slots of sam.fleet.listeners.codex-egress's from hosts, served on its port";
    tokens = lib.mkOption {
      type = lib.types.str;
      default = "/run/codex-egress/tokens";
      readOnly = true;
      internal = true;
      description = "access-token and account-id, or openai-key, derived from sam.workers.codexAuthFile, readable by the egress proxy alone.";
    };
  };

  config = lib.mkIf (auth != null) {
    environment.systemPackages = [ pkgs.codex ];

    systemd.services.codex-egress-token = {
      description = "Derive the egress proxy's Codex credentials from sam.workers.codexAuthFile";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe derive;
        RuntimeDirectory = baseNameOf (dirOf tokens);
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateNetwork = true;
      };
    };
    systemd.paths.codex-egress-token = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = auth;
    };

    systemd.services.codex-egress-refresh = {
      description = "Let upstream Codex refresh sam.workers.codexAuthFile when half its access token's life is gone";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # also catches a change the path unit missed, every run
      onSuccess = [ "codex-egress-token.service" ];
      environment = {
        CODEX_EGRESS_AUTH = auth;
        CODEX_EGRESS_FAILED = "/var/lib/${stateDir}/failed";
        CODEX_EGRESS_TEXTFILE = textfile;
        CODEX_EGRESS_READ = "${asOwner} ${pkgs.coreutils}/bin/cat --";
        # the login's own user, home and file store, so Codex stays the one writer; root keeps the marker and the textfile
        CODEX_EGRESS_CODEX = "${asOwner} ${pkgs.coreutils}/bin/env -i HOME=${ownerHome} CODEX_HOME=${dirOf auth} SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ${lib.getExe pkgs.codex} -c cli_auth_credentials_store=\"file\"";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${refresh}/bin/codex-egress-refresh";
        # the helper's own bound is 120 s; this one catches a hang outside it, and counts as no retry too
        TimeoutStartSec = 300;
        StateDirectory = stateDir;
        StateDirectoryMode = "0700";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [
          (dirOf auth)
          "/run/node-exporter-textfile"
        ];
        PrivateTmp = true;
      };
    };
    systemd.timers.codex-egress-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    homelab.execPool.agentMarkers.codex = ready;
  };
}
